import Data
import Domain
import Foundation

public actor GmailAccountSync: AccountSync {
    public nonisolated let status: AsyncStream<SyncStatus>
    private let continuation: AsyncStream<SyncStatus>.Continuation
    private let accountId: String
    private let client: GmailClient
    private let repository: SQLiteMailRepository
    private var polling: Task<Void, Never>?
    private var outboxWatcher: Task<Void, Never>?
    private var active: Task<Void, Error>?
    private var mailboxIds: Set<String> = []
    private var stopped = false

    public init(accountId: String, client: GmailClient, repository: SQLiteMailRepository) {
        self.accountId = accountId
        self.client = client
        self.repository = repository
        (status, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(.idle)
    }

    public func start() {
        guard polling == nil, !stopped else { return }
        polling = Task {
            while !Task.isCancelled {
                try? await synchronize()
                do { try await Task.sleep(for: .seconds(60)) } catch { break }
            }
        }
        outboxWatcher = Task {
            do {
                for try await head in repository.observeOutboxHead(accountId: accountId) where head != nil {
                    do { try await flush() }
                    catch is CancellationError { break }
                    catch {}
                }
            } catch {}
        }
    }

    public func stop() async {
        stopped = true
        polling?.cancel()
        outboxWatcher?.cancel()
        active?.cancel()
        await polling?.value
        await outboxWatcher?.value
        _ = try? await active?.value
        polling = nil
        outboxWatcher = nil
        active = nil
        continuation.finish()
    }

    public func synchronize() async throws {
        guard !stopped else { throw CancellationError() }
        while let inFlight = active {
            _ = try? await inFlight.value
            if active == inFlight { active = nil }
        }
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let task = Task { try await self.performSync() }
        active = task
        continuation.yield(.syncing(nil))
        defer { if active == task { active = nil } }
        do {
            try await task.value
            continuation.yield(.idle)
        } catch is CancellationError {
            continuation.yield(.idle)
            throw CancellationError()
        } catch {
            continuation.yield(.error(error.localizedDescription))
            throw error
        }
    }

    public func replayOutbox() async throws {
        while let entry = try await repository.nextOutboxAction(accountId: accountId) {
            do {
                try await replay(entry.action)
                try await repository.dequeueOutboxAction(id: entry.id, accountId: accountId)
            } catch GmailClientError.messageNotFound {
                try await repository.dequeueOutboxAction(id: entry.id, accountId: accountId)
            } catch let error as GmailHTTPError where error.status == 400 {
                try await repository.dequeueOutboxAction(id: entry.id, accountId: accountId)
            }
        }
    }

    private func flush() async throws {
        guard !stopped else { throw CancellationError() }
        while let inFlight = active {
            _ = try? await inFlight.value
            if active == inFlight { active = nil }
        }
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let task = Task { try await self.replayOutbox() }
        active = task
        defer { if active == task { active = nil } }
        try await task.value
    }

    private func replay(_ action: OutboxAction) async throws {
        switch action {
        case .changeFlags(let id, let flags, let enabled):
            if flags.contains(.read) { try await client.modify(id: id, add: enabled ? [] : ["UNREAD"], remove: enabled ? ["UNREAD"] : []) }
            if flags.contains(.starred) { try await client.modify(id: id, add: enabled ? ["STARRED"] : [], remove: enabled ? [] : ["STARRED"]) }
        case .addMailbox(let id, let mailbox):
            if mailbox == "TRASH" { try await client.trash(id: id) }
            else { try await client.modify(id: id, add: [mailbox], remove: []) }
        case .removeMailbox(let id, let mailbox):
            if mailbox == "TRASH" { try await client.untrash(id: id) }
            else { try await client.modify(id: id, add: [], remove: [mailbox]) }
        case .move(let id, let from, let to):
            if to == "TRASH" {
                try await client.trash(id: id)
                if from != "INBOX" { try await client.modify(id: id, add: [], remove: [from]) }
            } else if from == "TRASH" {
                try await client.untrash(id: id)
                try await client.modify(id: id, add: [to], remove: [])
            } else { try await client.modify(id: id, add: [to], remove: [from]) }
        case .send, .saveDraft, .deleteDraft: throw GmailClientError.unsupportedAction
        }
    }

    private func performSync() async throws {
        try await replayOutbox()
        let labels = try await client.labels()
        mailboxIds = []
        for mailbox in GmailMapping.mailboxes(labels, accountId: accountId) {
            try Task.checkCancellation()
            try await repository.upsert(mailbox)
            mailboxIds.insert(mailbox.id)
        }
        try await repository.reconcileMailboxes(accountId: accountId, keeping: mailboxIds)
        if let cursor = try await repository.syncCursor(accountId: accountId) {
            do { try await incrementalSync(cursor: cursor) }
            catch GmailClientError.historyExpired { try await fullSync() }
        } else { try await fullSync() }
    }

    private func fullSync() async throws {
        // Capture the cursor before listing so changes during the scan are replayed next time.
        let cursor = try await client.profile().historyId
        var pageToken: String?
        var seenTokens: Set<String> = []
        var ids: Set<String> = []
        repeat {
            let page = try await client.messages(pageToken: pageToken)
            ids.formUnion((page.messages ?? []).map(\.id))
            pageToken = page.nextPageToken
            if let pageToken, !seenTokens.insert(pageToken).inserted { throw URLError(.cannotParseResponse) }
        } while pageToken != nil
        let knownIds = try await repository.messageIds(accountId: accountId)
        let keeping = try await download(ids: ids, knownIds: knownIds, reportingProgress: true)
        try Task.checkCancellation()
        try await repository.reconcileMessages(accountId: accountId, keeping: keeping)
        try await repository.setSyncCursor(cursor, accountId: accountId)
    }

    private func incrementalSync(cursor: String) async throws {
        var pageToken: String?
        var seenTokens: Set<String> = []
        var changed: Set<String> = []
        var latest = cursor
        repeat {
            let page = try await client.history(start: cursor, pageToken: pageToken)
            for history in page.history ?? [] { changed.formUnion(history.changedIds) }
            latest = page.historyId
            pageToken = page.nextPageToken
            if let pageToken, !seenTokens.insert(pageToken).inserted { throw URLError(.cannotParseResponse) }
        } while pageToken != nil
        _ = try await download(ids: changed)
        try Task.checkCancellation()
        try await repository.setSyncCursor(latest, accountId: accountId)
    }

    private enum DownloadedMessage: Sendable {
        case full(GmailMessage)
        case state(GmailMessageState)
    }

    private func download(ids: Set<String>, knownIds: Set<String> = [], reportingProgress: Bool = false) async throws -> Set<String> {
        let sorted = ids.sorted()
        var kept: Set<String> = []
        if reportingProgress { continuation.yield(.syncing(SyncProgress(completed: 0, total: sorted.count))) }
        for start in stride(from: 0, to: sorted.count, by: 10) {
            try Task.checkCancellation()
            let batch = Array(sorted[start..<min(start + 10, sorted.count)])
            let values = try await withThrowingTaskGroup(of: DownloadedMessage?.self) { group in
                for id in batch {
                    group.addTask { [client] in
                        do {
                            if knownIds.contains(id) { return .state(try await client.messageState(id: id)) }
                            return .full(try await client.message(id: id))
                        } catch GmailClientError.messageNotFound { return nil }
                    }
                }
                var values: [DownloadedMessage] = []
                for try await value in group { if let value { values.append(value) } }
                return values
            }
            var retained: Set<String> = []
            for value in values {
                try Task.checkCancellation()
                switch value {
                case .full(let message):
                    let mapped = try GmailMapping.message(message, accountId: accountId)
                    guard mapped.message.date >= Date().addingTimeInterval(-90 * 86_400) else { continue }
                    try await ensureMailboxes(mapped.message.mailboxIds)
                    try await repository.upsert(mapped.message, body: mapped.body, attachments: mapped.attachments)
                    retained.insert(message.id)
                case .state(let state):
                    let labels = Set(state.labelIds ?? [])
                    let memberships = labels.subtracting(["UNREAD"])
                    try await ensureMailboxes(memberships)
                    try await repository.updateMessageState(accountId: accountId, id: state.id,
                                                             flags: GmailMapping.flags(labelIds: labels), mailboxIds: memberships)
                    retained.insert(state.id)
                }
            }
            try Task.checkCancellation()
            try await repository.deleteMessages(accountId: accountId, ids: Set(batch).subtracting(retained))
            kept.formUnion(retained)
            if reportingProgress {
                continuation.yield(.syncing(SyncProgress(completed: start + batch.count, total: sorted.count)))
            }
        }
        return kept
    }

    private func ensureMailboxes(_ ids: Set<String>) async throws {
        for id in ids.subtracting(mailboxIds) {
            try Task.checkCancellation()
            if let mailbox = GmailMapping.mailbox(GmailLabel(id: id, name: id, type: nil), accountId: accountId) {
                try await repository.upsert(mailbox)
                mailboxIds.insert(id)
            }
        }
    }
}
