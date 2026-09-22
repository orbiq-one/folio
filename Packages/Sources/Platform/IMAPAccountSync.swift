import Data
import Domain
import Foundation

public actor IMAPAccountSync: AccountSync {
    public nonisolated let status: AsyncStream<SyncStatus>
    private let continuation: AsyncStream<SyncStatus>.Continuation
    private let accountId: String
    private let client: any IMAPSession
    private let repository: SQLiteMailRepository
    private var polling: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var active: Task<Void, Error>?
    private var stopped = false

    public init(accountId: String, client: IMAPClient, repository: SQLiteMailRepository) {
        self.init(accountId: accountId, session: client, repository: repository)
    }

    init(accountId: String, session: any IMAPSession, repository: SQLiteMailRepository) {
        self.accountId = accountId; self.client = session; self.repository = repository
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
        watcher = Task {
            do {
                for try await head in repository.observeOutboxHead(accountId: accountId) where head != nil {
                    try Task.checkCancellation()
                    try? await synchronize()
                }
            } catch {}
        }
    }

    public func stop() async {
        stopped = true
        polling?.cancel(); watcher?.cancel(); active?.cancel()
        await client.close()
        await polling?.value; await watcher?.value
        _ = try? await active?.value
        polling = nil; watcher = nil; active = nil
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
        do { try await task.value; continuation.yield(.idle) }
        catch is CancellationError { continuation.yield(.idle); throw CancellationError() }
        catch { continuation.yield(.error(error.localizedDescription)); throw error }
    }

    private func performSync() async throws {
        try await client.connect()
        let folders = try await client.folders()
        for mailbox in IMAPMapping.mailboxes(folders, accountId: accountId) { try await repository.upsert(mailbox) }
        try await replayOutbox(folders: folders.filter(\.isSelectable))
        let known = try await repository.messageIds(accountId: accountId)
        var keeping = Set(known.filter { $0.hasPrefix("local-draft:") })
        var mirroredDrafts: [DraftLocation] = []
        for id in keeping {
            if let cursor = try await repository.syncCursor(accountId: accountId, scope: "compose-draft:\(id)"),
               let location = try? JSONDecoder().decode(DraftLocation.self, from: Foundation.Data(cursor.utf8)) { mirroredDrafts.append(location) }
        }
        for folder in folders where folder.isSelectable {
            try Task.checkCancellation()
            let state = try await client.select(folder.path, readOnly: true)
            let previous = try await repository.syncCursor(accountId: accountId, scope: folder.path)
                .flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(IMAPFolderState.self, from: $0) }
            let sameValidity = previous?.uidValidity == state.uidValidity
            let ids = try await client.search(since: Date().addingTimeInterval(-90 * 86_400))
            let changed: [UInt32: MessageFlags]?
            if sameValidity, let modSequence = previous?.highestModSequence, state.highestModSequence != nil {
                changed = try await client.changedFlags(since: modSequence)
            } else { changed = nil }
            for (index, uid) in ids.enumerated() {
                try Task.checkCancellation()
                let id = "\(folder.path)/\(uid)"
                if mirroredDrafts.contains(where: { $0.folder == folder.path && $0.uid == uid && $0.validity == state.uidValidity }) { continue }
                if sameValidity && known.contains(id) {
                    if let changed {
                        if let flags = changed[uid] {
                            try await repository.updateMessageState(accountId: accountId, id: id, flags: flags, mailboxIds: [folder.path])
                        }
                    } else {
                        guard let value = try await client.fetch(uid, full: false) else { continue }
                        try await repository.updateMessageState(accountId: accountId, id: id, flags: value.flags, mailboxIds: [folder.path])
                    }
                } else {
                    guard let value = try await client.fetch(uid, full: true) else { continue }
                    let mapped = IMAPMapping.message(value, folder: folder.path, accountId: accountId)
                    try await repository.upsert(mapped.message, body: mapped.body, attachments: mapped.attachments)
                }
                keeping.insert(id)
                continuation.yield(.syncing(SyncProgress(completed: index + 1, total: ids.count)))
            }
            let stale = known.filter { (try? IMAPMapping.location($0).folder) == folder.path }.subtracting(keeping)
            try await repository.deleteMessages(accountId: accountId, ids: stale)
            try await repository.setSyncCursor(String(decoding: JSONEncoder().encode(state), as: UTF8.self), accountId: accountId, scope: folder.path)
        }
        try Task.checkCancellation()
        try await repository.reconcileMessages(accountId: accountId, keeping: keeping)
        try await repository.reconcileMailboxes(accountId: accountId, keeping: Set(folders.map(\.path)).union(["local-drafts"]))
    }

    private struct DraftLocation: Codable { let folder: String; let uid: UInt32; let validity: UInt32 }

    private func deleteDraft(_ id: String) async throws {
        let scope = "compose-draft:\(id)"
        if let cursor = try await repository.syncCursor(accountId: accountId, scope: scope), !cursor.isEmpty,
           let location = try? JSONDecoder().decode(DraftLocation.self, from: Foundation.Data(cursor.utf8)) {
            let state = try await client.select(location.folder, readOnly: false)
            if state.uidValidity == location.validity { try await client.delete(uid: location.uid) }
        } else if !id.hasPrefix("local-draft:") {
            let location = try IMAPMapping.location(id)
            _ = try await client.select(location.folder, readOnly: false)
            try await client.delete(uid: location.uid)
        }
        try await repository.setSyncCursor("", accountId: accountId, scope: scope)
        try await repository.setSyncCursor("", accountId: accountId, scope: "compose-rich:\(id)")
        try await repository.deleteMessages(accountId: accountId, ids: [id])
    }

    private func replayComposition(_ entry: OutboxEntry, folders: [IMAPFolder]) async throws {
        let message: Message; let body: MessageBody; let attachments: [Attachment]; let sending: Bool
        switch entry.action {
        case .send(let value, let content, let files): message = value; body = content; attachments = files; sending = true
        case .saveDraft(let value, let content, let files): message = value; body = content; attachments = files; sending = false
        case .deleteDraft(let id): try await deleteDraft(id); return
        default: return
        }
        guard let folder = folders.first(where: { IMAPMapping.kind(path: $0.path, attributes: $0.attributes) == (sending ? .sent : .drafts) }) else { throw IMAPError.unsupportedAction }
        var revision = message
        if !sending { revision.internetMessageId = "<draft-\(entry.id)-\(message.id.replacingOccurrences(of: ":", with: "-"))@projectmail.local>" }
        guard let messageID = revision.internetMessageId else { throw IMAPError.invalidResponse }
        let data = try MIMEWriter.write(message: revision, body: body, attachments: attachments)
        if sending {
            let scope = "compose-send:\(entry.id)"
            let phase = try await repository.syncCursor(accountId: accountId, scope: scope)
            if phase == "submitting" { throw SMTPError.deliveryUncertain }
            if phase != "sent" {
                try await repository.setSyncCursor("submitting", accountId: accountId, scope: scope)
                do { try await client.sendSMTP(message: message, data: data) }
                catch SMTPError.deliveryUncertain { throw SMTPError.deliveryUncertain }
                catch { try await repository.setSyncCursor("ready", accountId: accountId, scope: scope); throw error }
                try await repository.setSyncCursor("sent", accountId: accountId, scope: scope)
            }
        }
        let state = try await client.select(folder.path, readOnly: false)
        var matches = try await client.uids(messageID: messageID)
        if matches.isEmpty {
            try await client.append(data, folder: folder.path, draft: !sending)
            matches = try await client.uids(messageID: messageID)
        }
        guard let uid = matches.max() else { throw IMAPError.invalidResponse }
        if sending { try await deleteDraft(message.id) }
        else {
            let scope = "compose-draft:\(message.id)"
            if let previous = try await repository.syncCursor(accountId: accountId, scope: scope),
               let location = try? JSONDecoder().decode(DraftLocation.self, from: Foundation.Data(previous.utf8)),
               location.uid != uid || location.folder != folder.path {
                let previousState = try await client.select(location.folder, readOnly: false)
                if previousState.uidValidity == location.validity { try await client.delete(uid: location.uid) }
            }
            let location = DraftLocation(folder: folder.path, uid: uid, validity: state.uidValidity)
            try await repository.setSyncCursor(String(decoding: JSONEncoder().encode(location), as: UTF8.self), accountId: accountId, scope: scope)
        }
    }

    private func replayOutbox(folders: [IMAPFolder]) async throws {
        while let entry = try await repository.nextOutboxAction(accountId: accountId) {
            try Task.checkCancellation()
            let id: String
            let destination: String?
            switch entry.action {
            case .changeFlags(let message, _, _): id = message; destination = nil
            case .move(let message, _, let to), .addMailbox(let message, let to): id = message; destination = to
            case .removeMailbox(let message, let from):
                id = message
                let fallback: MailboxKind = IMAPMapping.kind(path: from, attributes: []) == .trash ? .inbox : .archive
                guard let folder = folders.first(where: { IMAPMapping.kind(path: $0.path, attributes: $0.attributes) == fallback && $0.path != from }) else { throw IMAPError.unsupportedAction }
                destination = folder.path
            case .send, .saveDraft, .deleteDraft:
                try await replayComposition(entry, folders: folders)
                try await repository.dequeueOutboxAction(id: entry.id, accountId: accountId)
                continue
            }
            let location = try IMAPMapping.location(id)
            let state = try await client.select(location.folder, readOnly: false)
            if let cursor = try await repository.syncCursor(accountId: accountId, scope: location.folder),
               let data = cursor.data(using: .utf8), let previous = try? JSONDecoder().decode(IMAPFolderState.self, from: data),
               previous.uidValidity != state.uidValidity {
                // A reused UID must never target an unrelated message after a mailbox reset.
                try await repository.dequeueOutboxAction(id: entry.id, accountId: accountId)
                continue
            }
            if case .changeFlags(_, let flags, let enabled) = entry.action {
                try await client.store(uid: location.uid, flags: flags, enabled: enabled)
            } else if let destination, destination != location.folder {
                try await client.move(uid: location.uid, to: destination)
                try await repository.deleteMessages(accountId: accountId, ids: [id])
            }
            try await repository.dequeueOutboxAction(id: entry.id, accountId: accountId)
        }
    }
}
