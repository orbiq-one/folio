import Data
import Domain
import Foundation
import OSLog

public actor JMAPAccountSync: AccountSync {
    private static let log = Logger(subsystem: "re.leob.Folio", category: "jmap")
    public nonisolated let status: AsyncStream<SyncStatus>
    private let continuation: AsyncStream<SyncStatus>.Continuation
    private let accountId: String
    private let client: JMAPClient
    private let repository: SQLiteMailRepository
    private var polling: Task<Void, Never>?
    private var outboxWatcher: Task<Void, Never>?
    private var active: Task<Void, Error>?
    private var stopped = false

    public init(accountId: String, client: JMAPClient, repository: SQLiteMailRepository) {
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
                    do { try await run(outboxOnly: true) }
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

    public func synchronize() async throws { try await run(outboxOnly: false) }

    private func run(outboxOnly: Bool) async throws {
        guard !stopped else { throw CancellationError() }
        while let inFlight = active {
            _ = try? await inFlight.value
            if active == inFlight { active = nil }
        }
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        let task = Task {
            if outboxOnly { try await self.replayOutbox() }
            else { try await self.performSync() }
        }
        active = task
        continuation.yield(.syncing(nil))
        defer { if active == task { active = nil } }
        do { try await task.value; continuation.yield(.idle) }
        catch is CancellationError { continuation.yield(.idle); throw CancellationError() }
        catch { continuation.yield(.error(error.localizedDescription)); throw error }
    }

    public func replayOutbox() async throws {
        var firstRejection: JMAPError?
        while let entry = try await repository.nextOutboxAction(accountId: accountId) {
            try Task.checkCancellation()
            switch entry.action {
            case .saveDraft(let message, let body, let attachments):
                var revision = message
                revision.internetMessageId = "<draft-\(entry.id)-\(message.id.replacingOccurrences(of: ":", with: "-"))@projectmail.local>"
                let remote = try await client.createDraft(message: revision, body: body, attachments: attachments)
                let scope = "compose-draft:\(message.id)"
                if let previous = try await repository.syncCursor(accountId: accountId, scope: scope), !previous.isEmpty, previous != remote {
                    try await client.destroyDraft(id: previous)
                }
                try await repository.setSyncCursor(remote, accountId: accountId, scope: scope)
            case .send(let message, let body, let attachments):
                let scope = "compose-send:\(entry.id)"
                let phase = try await repository.syncCursor(accountId: accountId, scope: scope)
                if phase == "submitting" { throw SMTPError.deliveryUncertain }
                if phase != "sent" {
                    let remote = try await client.createDraft(message: message, body: body, attachments: attachments)
                    try await repository.setSyncCursor("submitting", accountId: accountId, scope: scope)
                    do { try await client.submit(emailId: remote, sender: message.sender) }
                    catch let error as JMAPError {
                        if case .method = error { try await repository.setSyncCursor("ready", accountId: accountId, scope: scope) }
                        throw error
                    }
                    try await repository.setSyncCursor("sent", accountId: accountId, scope: scope)
                }
                try await deleteDraft(message.id)
            case .deleteDraft(let id): try await deleteDraft(id)
            default:
                do { try await client.replay(entry.action) }
                catch let error as JMAPError where error.isPermanent {
                    let messageID = switch entry.action {
                    case .changeFlags(let id, _, _), .addMailbox(let id, _), .removeMailbox(let id, _), .move(let id, _, _): id
                    default: throw error
                    }
                    let result = try await client.emails(ids: [messageID])
                    if result.notFound?.contains(messageID) == true {
                        try await repository.reconcileFailedOutboxAction(id: entry.id, accountId: accountId, message: nil, body: nil)
                    } else if let value = result.list.first(where: { $0.id == messageID }) {
                        let mapped = try JMAPMapping.message(value, accountId: accountId)
                        try await refreshMailboxes()
                        try await repository.reconcileFailedOutboxAction(id: entry.id, accountId: accountId,
                                                                          message: mapped.message, body: mapped.body, attachments: mapped.attachments)
                    } else {
                        throw JMAPError.invalidResponse
                    }
                    firstRejection = firstRejection ?? error
                    continue
                }
            }
            try await repository.dequeueOutboxAction(id: entry.id, accountId: accountId)
        }
        if let firstRejection { throw firstRejection }
    }

    private func deleteDraft(_ id: String) async throws {
        let scope = "compose-draft:\(id)"
        let remote = try await repository.syncCursor(accountId: accountId, scope: scope)
        if let remote, !remote.isEmpty { try await client.destroyDraft(id: remote) }
        else if !id.hasPrefix("local-draft:") { try await client.destroyDraft(id: id) }
        try await repository.setSyncCursor("", accountId: accountId, scope: scope)
        try await repository.setSyncCursor("", accountId: accountId, scope: "compose-rich:\(id)")
        try await repository.deleteMessages(accountId: accountId, ids: [id])
    }

    private func performSync() async throws {
        try await replayOutbox()
        // A missing identity name must not block mail sync.
        do { try await backfillSenderName() }
        catch is CancellationError { throw CancellationError() }
        catch { Self.log.error("identity backfill failed: \(error.localizedDescription, privacy: .public)") }
        if let cursor = try await repository.syncCursor(accountId: accountId, scope: "mailbox") {
            do {
                let changes = try await allChanges(kind: "Mailbox", cursor: cursor)
                if !changes.changed.isEmpty || !changes.destroyed.isEmpty { try await refreshMailboxes() }
                else { try await repository.setSyncCursor(changes.state, accountId: accountId, scope: "mailbox") }
            } catch JMAPError.method("cannotCalculateChanges") { try await refreshMailboxes() }
        } else { try await refreshMailboxes() }
        if let cursor = try await repository.syncCursor(accountId: accountId, scope: "email") {
            do {
                let changes = try await allChanges(kind: "Email", cursor: cursor)
                _ = try await download(ids: changes.changed.subtracting(changes.destroyed))
                try await repository.deleteMessages(accountId: accountId, ids: changes.destroyed)
                try Task.checkCancellation()
                try await repository.setSyncCursor(changes.state, accountId: accountId, scope: "email")
            } catch JMAPError.method("cannotCalculateChanges") { try await fullSync() }
        } else { try await fullSync() }
    }

    private func backfillSenderName() async throws {
        guard try await repository.senderNameNeedsBackfill(accountId: accountId),
              let account = try await repository.accounts().first(where: { $0.id == accountId }) else { return }
        let identity = try await client.identities().first { $0.email.caseInsensitiveCompare(account.email.address) == .orderedSame }
        guard let name = identity?.name, !name.isEmpty else { return }
        try await repository.setSenderName(name, accountId: accountId, onlyIfMissing: true)
    }

    private func refreshMailboxes() async throws {
        let result = try await client.mailboxes()
        for value in result.list {
            try Task.checkCancellation()
            try await repository.upsert(JMAPMapping.mailbox(value, accountId: accountId))
        }
        try await repository.reconcileMailboxes(accountId: accountId, keeping: Set(result.list.map(\.id)).union(["local-drafts"]))
        try await repository.setSyncCursor(result.state, accountId: accountId, scope: "mailbox")
    }

    private func allChanges(kind: String, cursor: String) async throws -> (state: String, changed: Set<String>, destroyed: Set<String>) {
        var state = cursor
        var seen: Set<String> = [cursor]
        var changed: Set<String> = []
        var destroyed: Set<String> = []
        while true {
            try Task.checkCancellation()
            let page = try await client.changes(kind: kind, since: state)
            let live = Set(page.created + page.updated)
            destroyed.subtract(live)
            changed.formUnion(live)
            changed.subtract(page.destroyed)
            destroyed.formUnion(page.destroyed)
            state = page.newState
            if !page.hasMoreChanges { return (state, changed, destroyed) }
            guard seen.insert(state).inserted else { throw JMAPError.invalidResponse }
        }
    }

    private func fullSync() async throws {
        // Capture state before scanning so concurrent changes are replayed on the next poll.
        let state = try await client.emails(ids: []).state
        let cutoff = Date().addingTimeInterval(-90 * 86_400)
        var position = 0
        var ids: Set<String> = []
        while true {
            try Task.checkCancellation()
            let page = try await client.query(after: cutoff, position: position)
            if page.ids.isEmpty { break }
            let previousCount = ids.count
            ids.formUnion(page.ids)
            guard ids.count > previousCount else { throw JMAPError.invalidResponse }
            position += page.ids.count
            if let total = page.total, position >= total { break }
        }
        var keeping = try await download(ids: ids, reportingProgress: true)
        keeping.formUnion(try await repository.messageIds(accountId: accountId).filter { $0.hasPrefix("local-draft:") })
        try Task.checkCancellation()
        try await repository.reconcileMessages(accountId: accountId, keeping: keeping)
        try await repository.setSyncCursor(state, accountId: accountId, scope: "email")
    }

    private func download(ids: Set<String>, reportingProgress: Bool = false) async throws -> Set<String> {
        let sorted = ids.sorted()
        var keeping: Set<String> = []
        var knownMailboxes = Set(try await repository.mailboxes(accountId: accountId).map(\.id))
        var mirroredDrafts: Set<String> = []
        for id in try await repository.messageIds(accountId: accountId) where id.hasPrefix("local-draft:") {
            if let remote = try await repository.syncCursor(accountId: accountId, scope: "compose-draft:\(id)"), !remote.isEmpty { mirroredDrafts.insert(remote) }
        }
        if reportingProgress { continuation.yield(.syncing(SyncProgress(completed: 0, total: sorted.count))) }
        for start in stride(from: 0, to: sorted.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(sorted[start..<min(start + 100, sorted.count)])
            let result = try await client.emails(ids: batch)
            let returned = Set(result.list.map(\.id))
            let missing = Set(result.notFound ?? [])
            guard returned.isDisjoint(with: missing), returned.union(missing) == Set(batch) else {
                throw JMAPError.invalidResponse
            }
            var retained: Set<String> = []
            for email in result.list {
                try Task.checkCancellation()
                if mirroredDrafts.contains(email.id) { continue }
                let mapped = try JMAPMapping.message(email, accountId: accountId)
                guard mapped.message.date >= Date().addingTimeInterval(-90 * 86_400) else { continue }
                for id in mapped.message.mailboxIds.subtracting(knownMailboxes) {
                    try await repository.upsert(Mailbox(id: id, accountId: accountId, kind: .folder, name: id))
                    knownMailboxes.insert(id)
                }
                try await repository.upsert(mapped.message, body: mapped.body, attachments: mapped.attachments)
                retained.insert(email.id)
            }
            try await repository.deleteMessages(accountId: accountId, ids: Set(batch).subtracting(retained))
            keeping.formUnion(retained)
            if reportingProgress { continuation.yield(.syncing(SyncProgress(completed: start + batch.count, total: sorted.count))) }
        }
        return keeping
    }
}
