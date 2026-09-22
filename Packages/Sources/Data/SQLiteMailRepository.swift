import Domain
import Foundation
import GRDB

public struct AccountMailboxes: Equatable, Sendable {
    public let account: Account
    public let mailboxes: [Mailbox]
}

public enum MailboxSelection: Hashable, Sendable {
    case mailbox(accountId: String, mailboxId: String)
    case unified(MailboxKind)
    case view(ConversationView)
}

public struct OutboxEntry: Equatable, Sendable {
    public let id: Int64
    public let accountId: String
    public let action: OutboxAction
    public let notBefore: Date
}

public enum MailRepositoryError: Error {
    case invalidMessageReferences
    case accountMismatch
}

public struct SQLiteMailRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public func upsert(_ account: Account) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO account (id, provider, displayName, email, capabilities) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET provider = excluded.provider,
                    displayName = excluded.displayName, email = excluded.email, capabilities = excluded.capabilities
                """, arguments: [account.id, account.provider.rawValue, account.displayName,
                                  try Self.encode(account.email), account.capabilities.rawValue])
        }
    }

    /// With onlyIfMissing, keeps a name the user already set; used by provider backfill.
    public func setSenderName(_ name: String?, accountId: String, onlyIfMissing: Bool = false) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT email, senderNameInitialized FROM account WHERE id = ?", arguments: [accountId]) else { return }
            var email: EmailAddress = try Self.decode(row["email"])
            let initialized: Bool = row["senderNameInitialized"]
            if onlyIfMissing, initialized { return }
            if onlyIfMissing, !(email.name ?? "").isEmpty {
                try db.execute(sql: "UPDATE account SET senderNameInitialized = 1 WHERE id = ?", arguments: [accountId])
                return
            }
            email.name = trimmed.isEmpty ? nil : trimmed
            try db.execute(sql: "UPDATE account SET email = ?, senderNameInitialized = ? WHERE id = ?",
                           arguments: [try Self.encode(email), !trimmed.isEmpty || !onlyIfMissing, accountId])
        }
    }

    public func senderNameNeedsBackfill(accountId: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT NOT senderNameInitialized FROM account WHERE id = ?", arguments: [accountId]) ?? false
        }
    }

    public func accounts() async throws -> [Account] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM account ORDER BY id").map { row in
                Account(id: row["id"], provider: try Self.decodeEnum(ProviderKind.self, row["provider"]),
                        displayName: row["displayName"], email: try Self.decode(row["email"]),
                        capabilities: ProviderCapabilities(rawValue: row["capabilities"]))
            }
        }
    }

    public func upsert(_ mailbox: Mailbox) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO mailbox (accountId, id, kind, name, parentId, isHidden, isSystem) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(accountId, id) DO UPDATE SET kind = excluded.kind,
                    name = excluded.name, parentId = excluded.parentId, isHidden = excluded.isHidden, isSystem = excluded.isSystem
                """, arguments: [mailbox.accountId, mailbox.id, mailbox.kind.rawValue, mailbox.name, mailbox.parentId, mailbox.isHidden, mailbox.isSystem])
        }
    }

    public func mailboxes(accountId: String) async throws -> [Mailbox] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mailbox WHERE accountId = ? ORDER BY id", arguments: [accountId])
                .map { row in
                    Mailbox(id: row["id"], accountId: row["accountId"],
                            kind: try Self.decodeEnum(MailboxKind.self, row["kind"]), name: row["name"], parentId: row["parentId"],
                            isHidden: row["isHidden"], isSystem: row["isSystem"])
                }
        }
    }

    public func upsert(_ message: Message, body: MessageBody? = nil, attachments: [Attachment] = []) async throws {
        try await writer.write { db in try Self.upsert(message, body: body, attachments: attachments, db: db) }
    }

    /// Upserts all messages in one transaction, so observers see a single change.
    public func upsert(_ messages: [(message: Message, body: MessageBody?, attachments: [Attachment])]) async throws {
        try await writer.write { db in
            for item in messages { try Self.upsert(item.message, body: item.body, attachments: item.attachments, db: db) }
        }
    }

    private static func upsert(_ message: Message, body: MessageBody?, attachments: [Attachment], db: Database) throws {
        guard body == nil || body?.id == message.bodyId,
              attachments.map(\.id) == message.attachmentIds,
              Set(message.attachmentIds).count == message.attachmentIds.count else {
            throw MailRepositoryError.invalidMessageReferences
        }
        try db.execute(sql: """
            DELETE FROM message_body WHERE accountId = ? AND id = (
                SELECT bodyId FROM message WHERE accountId = ? AND id = ?)
                AND id IS NOT ?
            """, arguments: [message.accountId, message.accountId, message.id, message.bodyId])
        let kind = try Self.classify(message, db: db)
        try db.execute(sql: """
            INSERT INTO message (accountId, id, threadId, subject, sender, recipients, cc, bcc, replyTo,
                date, internetMessageId, inReplyTo, referenceIds, flags, bodyId, trafficKind, automationHeaders)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accountId, id) DO UPDATE SET threadId = excluded.threadId, subject = excluded.subject,
                sender = excluded.sender, recipients = excluded.recipients, cc = excluded.cc, bcc = excluded.bcc,
                replyTo = excluded.replyTo, date = excluded.date, internetMessageId = excluded.internetMessageId,
                inReplyTo = excluded.inReplyTo, referenceIds = excluded.referenceIds, flags = excluded.flags,
                bodyId = excluded.bodyId, trafficKind = excluded.trafficKind, automationHeaders = excluded.automationHeaders
            """, arguments: [message.accountId, message.id, message.threadId, message.subject,
                              try Self.encode(message.sender), try Self.encode(message.to), try Self.encode(message.cc),
                              try Self.encode(message.bcc), try Self.encode(message.replyTo), message.date.timeIntervalSince1970,
                              message.internetMessageId, message.inReplyTo, try Self.encode(message.references),
                              message.flags.rawValue, message.bodyId, kind.rawValue, try Self.encode(message.automationHeaders)])
        try db.execute(sql: "DELETE FROM message_mailbox WHERE accountId = ? AND messageId = ?",
                       arguments: [message.accountId, message.id])
        for mailboxId in message.mailboxIds {
            try db.execute(sql: "INSERT INTO message_mailbox (accountId, messageId, mailboxId) VALUES (?, ?, ?)",
                           arguments: [message.accountId, message.id, mailboxId])
        }
        if let body {
            let displayText = BodyCleaner.clean(plainText: body.plainText, html: body.html).displayText
            try db.execute(sql: """
                INSERT INTO message_body (accountId, id, plainText, html, displayText) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(accountId, id) DO UPDATE SET plainText = excluded.plainText, html = excluded.html,
                    displayText = excluded.displayText
                """, arguments: [message.accountId, body.id, body.plainText, body.html, displayText])
        }
        try Self.updateActivityCategory(message, kind: kind, db: db)
        try db.execute(sql: "DELETE FROM attachment WHERE accountId = ? AND messageId = ?",
                       arguments: [message.accountId, message.id])
        for (position, attachment) in attachments.enumerated() {
            try db.execute(sql: """
                INSERT INTO attachment (accountId, id, messageId, position, filename, mimeType, size, contentHash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [message.accountId, attachment.id, message.id, position, attachment.filename,
                                  attachment.mimeType, attachment.size, attachment.contentHash])
        }
    }

    public func observeUnreadCounts() -> AsyncValueObservation<[MailboxSelection: Int]> {
        ValueObservation.tracking { db in
            var counts: [MailboxSelection: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT mm.accountId, mm.mailboxId, COUNT(*) AS unread
                FROM message_mailbox mm JOIN message m ON m.accountId = mm.accountId AND m.id = mm.messageId
                WHERE (m.flags & ?) = 0 GROUP BY mm.accountId, mm.mailboxId
                """, arguments: [MessageFlags.read.rawValue]) {
                counts[.mailbox(accountId: row["accountId"], mailboxId: row["mailboxId"])] = row["unread"]
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT mb.kind, COUNT(DISTINCT m.rowid) AS unread FROM message m
                JOIN message_mailbox mm ON mm.accountId = m.accountId AND mm.messageId = m.id
                JOIN mailbox mb ON mb.accountId = mm.accountId AND mb.id = mm.mailboxId
                WHERE (m.flags & ?) = 0 GROUP BY mb.kind
                """, arguments: [MessageFlags.read.rawValue]) {
                if let kind = MailboxKind(rawValue: row["kind"]) { counts[.unified(kind)] = row["unread"] }
            }
            for conversation in try Self.inferAll(db, now: .now) {
                for view in ConversationView.allCases where StateInference.matches(conversation.state, kind: conversation.kind, view: view) {
                    if view != .activity { counts[.view(view), default: 0] += 1 }
                }
            }
            counts[.view(.activity)] = try Self.fetchActivityMessages(db).filter { !$0.message.flags.contains(.read) }.count
            return counts
        }.removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    public func observeAccounts() -> AsyncValueObservation<[AccountMailboxes]> {
        ValueObservation.tracking { db in
            let mailboxes = try Row.fetchAll(db, sql: "SELECT * FROM mailbox ORDER BY name, id").map { row in
                Mailbox(id: row["id"], accountId: row["accountId"], kind: try Self.decodeEnum(MailboxKind.self, row["kind"]),
                        name: row["name"], parentId: row["parentId"], isHidden: row["isHidden"], isSystem: row["isSystem"])
            }
            return try Row.fetchAll(db, sql: "SELECT * FROM account ORDER BY displayName, id").map { row in
                let account = Account(id: row["id"], provider: try Self.decodeEnum(ProviderKind.self, row["provider"]),
                                      displayName: row["displayName"], email: try Self.decode(row["email"]),
                                      capabilities: ProviderCapabilities(rawValue: row["capabilities"]))
                return AccountMailboxes(account: account, mailboxes: mailboxes.filter { $0.accountId == account.id })
            }
        }.removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    public func removeAccount(id: String) async throws {
        try await writer.write { try $0.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [id]) }
    }

    public func messageIds(accountId: String) async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM message WHERE accountId = ?", arguments: [accountId]))
        }
    }

    public func updateMessageState(accountId: String, id: String, flags: MessageFlags, mailboxIds: Set<String>) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE message SET flags = ? WHERE accountId = ? AND id = ?", arguments: [flags.rawValue, accountId, id])
            guard db.changesCount > 0 else { throw MailRepositoryError.invalidMessageReferences }
            try db.execute(sql: "DELETE FROM message_mailbox WHERE accountId = ? AND messageId = ?", arguments: [accountId, id])
            for mailboxId in mailboxIds {
                try db.execute(sql: "INSERT INTO message_mailbox (accountId, messageId, mailboxId) VALUES (?, ?, ?)",
                               arguments: [accountId, id, mailboxId])
            }
        }
    }

    public func deleteMessages(accountId: String, ids: Set<String>) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND id IN (SELECT value FROM json_each(?))",
                           arguments: [accountId, try Self.encode(ids)])
        }
    }

    public func reconcileMessages(accountId: String, keeping ids: Set<String>) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND id NOT IN (SELECT value FROM json_each(?))",
                           arguments: [accountId, try Self.encode(ids)])
        }
    }

    public func reconcileMailboxes(accountId: String, keeping ids: Set<String>) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM mailbox WHERE accountId = ? AND id NOT IN (SELECT value FROM json_each(?))",
                           arguments: [accountId, try Self.encode(ids)])
        }
    }

    public func threads(in selection: MailboxSelection) async throws -> [MailThread] {
        try await writer.read { try Self.fetchThreads($0, selection: selection) }
    }

    public func thread(accountId: String, threadId: String) async throws -> MailThread? {
        try await writer.read { try Self.fetchThread($0, accountId: accountId, threadId: threadId) }
    }

    public func observeThreads(in selection: MailboxSelection) -> AsyncValueObservation<[MailThread]> {
        ValueObservation.tracking { try Self.fetchThreads($0, selection: selection) }
            .removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    public func observeThread(accountId: String, threadId: String) -> AsyncValueObservation<MailThread?> {
        ValueObservation.tracking { try Self.fetchThread($0, accountId: accountId, threadId: threadId) }
            .removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    @discardableResult
    public func enqueue(_ action: OutboxAction, accountId: String, notBefore: Date = .distantPast) async throws -> Int64 {
        try Self.validate(action, accountId: accountId)
        return try await writer.write { try Self.insert(action, accountId: accountId, notBefore: notBefore, db: $0) }
    }

    @discardableResult
    public func perform(_ action: OutboxAction, accountId: String, notBefore: Date = .distantPast) async throws -> Int64 {
        try Self.validate(action, accountId: accountId)
        return try await writer.write { db in
            try Self.applyOptimistic(action, accountId: accountId, db: db)
            return try Self.insert(action, accountId: accountId, notBefore: notBefore, db: db)
        }
    }

    public func observeOutboxHead(accountId: String) -> AsyncValueObservation<Int64?> {
        ValueObservation.tracking { db in
            try Row.fetchOne(db, sql: "SELECT MAX(id) AS id FROM outbox WHERE accountId = ?", arguments: [accountId])?["id"]
        }.removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    public func nextOutboxAction(accountId: String, now: Date = .now) async throws -> OutboxEntry? {
        try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM outbox WHERE accountId = ? AND notBefore <= ? ORDER BY id LIMIT 1
                """, arguments: [accountId, now.timeIntervalSince1970]) else { return nil }
            let notBefore = Date(timeIntervalSince1970: row["notBefore"])
            return OutboxEntry(id: row["id"], accountId: row["accountId"], action: try Self.decode(row["action"]), notBefore: notBefore)
        }
    }

    // Keep the row until provider success so a crash cannot lose an action.
    public func dequeueOutboxAction(id: Int64, accountId: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ? AND accountId = ?", arguments: [id, accountId])
        }
    }

    /// Replaces optimistic state with the provider state and removes a rejected action atomically.
    public func reconcileFailedOutboxAction(id: Int64, accountId: String, message: Message?, body: MessageBody?, attachments: [Attachment] = []) async throws {
        try await writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT action FROM outbox WHERE id = ? AND accountId = ?", arguments: [id, accountId]) else {
                throw MailRepositoryError.invalidMessageReferences
            }
            let failed: OutboxAction = try Self.decode(row["action"])
            let messageID = Self.messageID(for: failed)
            if let message {
                guard message.accountId == accountId, message.id == messageID else { throw MailRepositoryError.accountMismatch }
                try Self.upsert(message, body: body, attachments: attachments, db: db)
                let rows = try Row.fetchAll(db, sql: "SELECT action FROM outbox WHERE accountId = ? AND id > ? AND notBefore <= ? ORDER BY id",
                                            arguments: [accountId, id, Date().timeIntervalSince1970])
                for row in rows {
                    let action: OutboxAction = try Self.decode(row["action"])
                    guard Self.messageID(for: action) == message.id else { continue }
                    try Self.applyOptimistic(action, accountId: accountId, db: db)
                }
            } else {
                try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND id = ?", arguments: [accountId, messageID])
            }
            try db.execute(sql: "DELETE FROM outbox WHERE id = ? AND accountId = ?", arguments: [id, accountId])
        }
    }

    private static func messageID(for action: OutboxAction) -> String {
        switch action {
        case .changeFlags(let id, _, _), .addMailbox(let id, _), .removeMailbox(let id, _), .move(let id, _, _): return id
        case .send(let message, _, _), .saveDraft(let message, _, _): return message.id
        case .deleteDraft(let id): return id
        }
    }

    private static func applyOptimistic(_ action: OutboxAction, accountId: String, db: Database) throws {
        switch action {
        case .changeFlags(let id, let flags, let enabled):
            try db.execute(sql: enabled ? "UPDATE message SET flags = flags | ? WHERE accountId = ? AND id = ?" : "UPDATE message SET flags = flags & ~? WHERE accountId = ? AND id = ?",
                           arguments: [flags.rawValue, accountId, id])
        case .addMailbox(let id, let mailbox): try addMailbox(messageId: id, mailboxId: mailbox, accountId: accountId, db: db)
        case .removeMailbox(let id, let mailbox):
            try db.execute(sql: "DELETE FROM message_mailbox WHERE accountId = ? AND messageId = ? AND mailboxId = ?", arguments: [accountId, id, mailbox])
        case .move(let id, let from, let to):
            try db.execute(sql: "DELETE FROM message_mailbox WHERE accountId = ? AND messageId = ? AND mailboxId = ?", arguments: [accountId, id, from])
            try addMailbox(messageId: id, mailboxId: to, accountId: accountId, db: db)
        case .send, .saveDraft, .deleteDraft: break
        }
    }

    public func cancelScheduledOutboxAction(id: Int64, accountId: String) async throws -> Bool {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id = ? AND accountId = ? AND notBefore > ?",
                           arguments: [id, accountId, Date().timeIntervalSince1970])
            return db.changesCount == 1
        }
    }

    /// Removes not-yet-due outbox rows that would re-add the given messages to a mailbox (a `later` return).
    public func cancelScheduledMailboxAdditions(accountId: String, messageIds: Set<String>) async throws {
        try await writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, action FROM outbox WHERE accountId = ? AND notBefore > ?",
                                        arguments: [accountId, Date().timeIntervalSince1970])
            for row in rows {
                guard case .addMailbox(let messageId, _) = try Self.decode(row["action"]) as OutboxAction,
                      messageIds.contains(messageId) else { continue }
                try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [row["id"] as Int64])
            }
        }
    }

    public func setSyncCursor(_ cursor: String, accountId: String, scope: String = "") async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (accountId, scope, cursor) VALUES (?, ?, ?)
                ON CONFLICT(accountId, scope) DO UPDATE SET cursor = excluded.cursor
                """, arguments: [accountId, scope, cursor])
        }
    }

    public func syncCursor(accountId: String, scope: String = "") async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT cursor FROM sync_state WHERE accountId = ? AND scope = ?",
                                arguments: [accountId, scope])
        }
    }

    public func search(_ text: String, accountId: String? = nil) async throws -> [Message] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: text) else { return [] }
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.* FROM message m JOIN message_fts f ON f.rowid = m.rowid
                WHERE message_fts MATCH ? AND (? IS NULL OR m.accountId = ?)
                ORDER BY m.date DESC, m.accountId, m.id
                """, arguments: [pattern.rawPattern, accountId, accountId])
            return try Self.messages(rows, db: db)
        }
    }

    /// Best matches for any of `terms`, ranked by FTS relevance, with the start of the matched plain text.
    public func rankedSearch(anyOf terms: [String], limit: Int, textLength: Int = 2_000) async throws -> [(message: Message, text: String)] {
        guard let pattern = FTS5Pattern(matchingAnyTokenIn: terms.joined(separator: " ")) else { return [] }
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.*, substr(f.plainText, 1, ?) AS matchedText FROM message m JOIN message_fts f ON f.rowid = m.rowid
                WHERE message_fts MATCH ? AND (m.flags & ?) = 0
                ORDER BY f.rank, m.date DESC LIMIT ?
                """, arguments: [textLength, pattern.rawPattern, MessageFlags.draft.rawValue, limit])
            let messages = try Self.messages(rows, db: db)
            return zip(messages, rows).map { ($0, ($1["matchedText"] as String?) ?? "") }
        }
    }

    public func activityMessages() async throws -> [ActivityItem] {
        try await writer.read { try Self.fetchActivityMessages($0) }
    }

    public func observeActivityMessages() -> AsyncValueObservation<[ActivityItem]> {
        ValueObservation.tracking { try Self.fetchActivityMessages($0) }
            .removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    private static func fetchActivityMessages(_ db: Database) throws -> [ActivityItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.*, COALESCE(b.displayText, '') AS activityDisplayText
            FROM message m LEFT JOIN message_body b ON b.accountId = m.accountId AND b.id = m.bodyId
            WHERE m.trafficKind = 'activity' AND (m.flags & ?) = 0
                AND NOT EXISTS (
                    SELECT 1 FROM message_mailbox mm
                    JOIN mailbox mb ON mb.accountId = mm.accountId AND mb.id = mm.mailboxId
                    WHERE mm.accountId = m.accountId AND mm.messageId = m.id AND mb.kind IN ('trash', 'spam'))
            ORDER BY m.date DESC, m.accountId, m.id
            """, arguments: [MessageFlags.draft.rawValue])
        return try zip(rows, messages(rows, db: db)).map { row, message in
            ActivityItem(message: message, displayText: row["activityDisplayText"])
        }
    }

    // MARK: Conversations

    public func conversations(in view: ConversationView, now: Date = .now) async throws -> [Conversation] {
        try await writer.read { try Self.fetchConversations($0, view: view, now: now) }
    }

    public func observeConversations(in view: ConversationView) -> AsyncValueObservation<[Conversation]> {
        ValueObservation.tracking { try Self.fetchConversations($0, view: view, now: .now) }
            .removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    public func observeConversationCounts() -> AsyncValueObservation<[ConversationView: Int]> {
        ValueObservation.tracking { db in
            var counts: [ConversationView: Int] = [:]
            for conversation in try Self.inferAll(db, now: .now) {
                for view in ConversationView.allCases where StateInference.matches(conversation.state, kind: conversation.kind, view: view) {
                    counts[view, default: 0] += 1
                }
            }
            return counts
        }.removeDuplicates().values(in: writer, bufferingPolicy: .bufferingNewest(1))
    }

    public func setOverride(_ override: ConversationOverride) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO conversation_override (accountId, threadId, state, until, setAt) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(accountId, threadId) DO UPDATE SET state = excluded.state, until = excluded.until, setAt = excluded.setAt
                WHERE excluded.setAt >= conversation_override.setAt
                """, arguments: [override.accountId, override.threadId, override.state.rawValue,
                                  override.until?.timeIntervalSince1970, override.setAt.timeIntervalSince1970])
        }
    }

    public func clearOverride(accountId: String, threadId: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM conversation_override WHERE accountId = ? AND threadId = ?", arguments: [accountId, threadId])
        }
    }

    public func overrides(accountId: String? = nil) async throws -> [ConversationOverride] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM conversation_override WHERE (? IS NULL OR accountId = ?) ORDER BY setAt DESC",
                             arguments: [accountId, accountId]).map(Self.override)
        }
    }

    public func setSenderRule(_ rule: SenderRule) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                INSERT INTO sender_rule (accountId, address, kind, setAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(accountId, address) DO UPDATE SET kind = excluded.kind, setAt = excluded.setAt
                WHERE excluded.setAt >= sender_rule.setAt
                """, arguments: [rule.accountId, rule.address, rule.kind.rawValue, rule.setAt.timeIntervalSince1970])
            try Self.reclassify(db, accountId: rule.accountId, sender: rule.address)
        }
    }

    public func clearSenderRule(accountId: String, address: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM sender_rule WHERE accountId = ? AND address = ?", arguments: [accountId, address.lowercased()])
            try Self.reclassify(db, accountId: accountId, sender: address.lowercased())
        }
    }

    public func senderRules(accountId: String) async throws -> [SenderRule] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sender_rule WHERE accountId = ? ORDER BY address", arguments: [accountId]).map { row in
                SenderRule(accountId: row["accountId"], address: row["address"], kind: try Self.decodeEnum(TrafficKind.self, row["kind"]),
                           setAt: Date(timeIntervalSince1970: row["setAt"]))
            }
        }
    }

    /// Recomputes every derived column from the raw store. Rules can improve without a schema migration.
    public func rebuildDerivedData() async throws {
        try await writer.write { try Self.rebuildDerivedData($0) }
    }

    static func rebuildDerivedData(_ db: Database, activityCategories: Bool = true) throws {
        let bodies = try Row.fetchAll(db, sql: "SELECT accountId, id, plainText, html FROM message_body")
        for row in bodies {
            let displayText = BodyCleaner.clean(plainText: row["plainText"], html: row["html"]).displayText
            try db.execute(sql: "UPDATE message_body SET displayText = ? WHERE accountId = ? AND id = ?",
                           arguments: [displayText, row["accountId"] as String, row["id"] as String])
        }
        for accountId in try String.fetchAll(db, sql: "SELECT id FROM account") {
            try reclassify(db, accountId: accountId, sender: nil, activityCategories: activityCategories)
        }
    }

    private static func classify(_ message: Message, db: Database) throws -> TrafficKind {
        let sender = message.sender.address.lowercased()
        let accountEmail = try String.fetchOne(db, sql: "SELECT json_extract(email, '$.address') FROM account WHERE id = ?",
                                               arguments: [message.accountId]) ?? ""
        let rule = try String.fetchOne(db, sql: "SELECT kind FROM sender_rule WHERE accountId = ? AND address = ?",
                                       arguments: [message.accountId, sender]).flatMap(TrafficKind.init(rawValue:))
        let pattern = "%\"address\":\"\(sender)\"%"
        let known = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM message WHERE accountId = ? AND lower(json_extract(sender, '$.address')) = lower(?)
                AND (recipients LIKE ? OR cc LIKE ?))
            """, arguments: [message.accountId, accountEmail, pattern, pattern]) ?? false
        return TrafficClassifier.classify(message, accountEmail: accountEmail, isKnownContact: known, rule: rule)
    }

    private static func updateActivityCategory(_ message: Message, kind: TrafficKind, db: Database) throws {
        let row = try Row.fetchOne(db, sql: "SELECT * FROM message_body WHERE accountId = ? AND id = ?",
                                  arguments: [message.accountId, message.bodyId])
        let body = row.map { MessageBody(id: $0["id"], plainText: $0["plainText"], html: $0["html"]) }
        let category = kind == .activity ? ActivityCategory.classify(message: message, body: body) : nil
        try db.execute(sql: "UPDATE message SET activityCategory = ? WHERE accountId = ? AND id = ? AND activityCategory IS NOT ?",
                       arguments: [category?.rawValue, message.accountId, message.id, category?.rawValue])
    }

    private static func reclassify(_ db: Database, accountId: String, sender: String?, activityCategories: Bool = true) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM message WHERE accountId = ? AND (? IS NULL OR lower(json_extract(sender, '$.address')) = ?)
            """, arguments: [accountId, sender, sender])
        for message in try messages(rows, db: db) {
            let kind = try classify(message, db: db)
            try db.execute(sql: "UPDATE message SET trafficKind = ? WHERE accountId = ? AND id = ? AND trafficKind != ?",
                           arguments: [kind.rawValue, accountId, message.id, kind.rawValue])
            if activityCategories { try updateActivityCategory(message, kind: kind, db: db) }
        }
    }

    private static func override(_ row: Row) throws -> ConversationOverride {
        ConversationOverride(accountId: row["accountId"], threadId: row["threadId"],
                             state: try decodeEnum(ConversationState.self, row["state"]),
                             until: (row["until"] as Double?).map(Date.init(timeIntervalSince1970:)),
                             setAt: Date(timeIntervalSince1970: row["setAt"]))
    }

    private static func conversationFacts(_ db: Database, accountId: String? = nil) throws -> [String: ConversationFacts] {
        var facts: [String: ConversationFacts] = [:]
        let accounts = try Row.fetchAll(db, sql: "SELECT id, json_extract(email, '$.address') AS email FROM account WHERE ? IS NULL OR id = ?",
                                        arguments: [accountId, accountId])
        for row in accounts {
            let accountId: String = row["id"]
            let mailboxes = try Row.fetchAll(db, sql: "SELECT id, kind FROM mailbox WHERE accountId = ?", arguments: [accountId])
            facts[accountId] = ConversationFacts(
                accountEmail: row["email"] ?? "",
                inboxMailboxIds: Set(mailboxes.filter { $0["kind"] == MailboxKind.inbox.rawValue }.map { $0["id"] as String }),
                hiddenMailboxIds: Set(mailboxes.filter { [MailboxKind.trash.rawValue, MailboxKind.spam.rawValue].contains($0["kind"] as String) }
                    .map { $0["id"] as String }))
        }
        return facts
    }

    private static func inferAll(_ db: Database, now: Date) throws -> [Conversation] {
        let facts = try conversationFacts(db)
        var overrides: [Conversation.ID: ConversationOverride] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM conversation_override") {
            let value = try override(row)
            overrides[Conversation.ID(accountId: value.accountId, threadId: value.threadId)] = value
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.*, (SELECT substr(COALESCE(displayText, plainText), 1, 200) FROM message_body
                WHERE accountId = m.accountId AND id = m.bodyId) AS snippet
            FROM message m WHERE (m.flags & ?) = 0 ORDER BY m.date DESC, m.accountId, m.id
            """, arguments: [MessageFlags.draft.rawValue])
        var threads: [MailThread] = []
        var kinds: [Conversation.ID: [String: TrafficKind]] = [:]
        var indices: [Conversation.ID: Int] = [:]
        for (row, message) in zip(rows, try messages(rows, db: db)) {
            let key = Conversation.ID(accountId: message.accountId, threadId: message.threadId)
            kinds[key, default: [:]][message.id] = TrafficKind(rawValue: row["trafficKind"]) ?? .human
            if let index = indices[key] {
                threads[index].messages.append(message)
            } else {
                indices[key] = threads.count
                let snippet: String? = row["snippet"]
                threads.append(MailThread(id: message.threadId, accountId: message.accountId, messages: [message],
                                          snippet: snippet?.components(separatedBy: .newlines).first ?? ""))
            }
        }
        return threads.compactMap { thread in
            let key = Conversation.ID(accountId: thread.accountId, threadId: thread.id)
            guard let facts = facts[thread.accountId] else { return nil }
            let result = StateInference.infer(messages: thread.messages, kinds: kinds[key] ?? [:], facts: facts,
                                              override: overrides[key], now: now)
            return Conversation(thread: thread, kind: result.kind, state: result.state)
        }
    }

    private static func fetchConversations(_ db: Database, view: ConversationView, now: Date) throws -> [Conversation] {
        try inferAll(db, now: now).filter { StateInference.matches($0.state, kind: $0.kind, view: view) }
    }

    private static func fetchThreads(_ db: Database, selection: MailboxSelection) throws -> [MailThread] {
        let predicate: String
        let arguments: StatementArguments
        switch selection {
        case .mailbox(let accountId, let mailboxId):
            predicate = "mb.accountId = ? AND mb.id = ?"
            arguments = [accountId, mailboxId]
        case .unified(let kind):
            predicate = "mb.kind = ?"
            arguments = [kind.rawValue]
        case .view(let view):
            return try fetchConversations(db, view: view, now: .now).map { conversation in
                var thread = conversation.thread
                thread.state = conversation.state
                return thread
            }
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.*, (SELECT substr(COALESCE(displayText, plainText), 1, 200) FROM message_body
                WHERE accountId = m.accountId AND id = m.bodyId) AS snippet
            FROM message m WHERE EXISTS (
                SELECT 1 FROM message member
                JOIN message_mailbox mm ON mm.accountId = member.accountId AND mm.messageId = member.id
                JOIN mailbox mb ON mb.accountId = mm.accountId AND mb.id = mm.mailboxId
                WHERE member.accountId = m.accountId AND member.threadId = m.threadId AND \(predicate))
            ORDER BY m.date DESC, m.accountId, m.id
            """, arguments: arguments)
        var threads: [MailThread] = []
        var indices: [ThreadKey: Int] = [:]
        for (row, message) in zip(rows, try messages(rows, db: db)) {
            let key = ThreadKey(accountId: message.accountId, threadId: message.threadId)
            if let index = indices[key] {
                threads[index].messages.append(message)
            } else {
                indices[key] = threads.count
                let snippet: String? = row["snippet"]
                threads.append(MailThread(id: message.threadId, accountId: message.accountId, messages: [message],
                                          snippet: snippet?.components(separatedBy: .newlines).first ?? ""))
            }
        }
        return threads
    }

    private static func fetchThread(_ db: Database, accountId: String, threadId: String) throws -> MailThread? {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM message WHERE accountId = ? AND threadId = ? ORDER BY date, id",
                                    arguments: [accountId, threadId])
        guard !rows.isEmpty else { return nil }
        let messages = try messages(rows, db: db)
        let bodyRows = try Row.fetchAll(db, sql: """
            SELECT b.* FROM message_body b JOIN message m ON m.accountId = b.accountId AND m.bodyId = b.id
            WHERE m.accountId = ? AND m.threadId = ?
            """, arguments: [accountId, threadId])
        let attachmentRows = try Row.fetchAll(db, sql: """
            SELECT a.* FROM attachment a JOIN message m ON m.accountId = a.accountId AND m.id = a.messageId
            WHERE m.accountId = ? AND m.threadId = ?
            """, arguments: [accountId, threadId])
        let bodies = bodyRows.map { MessageBody(id: $0["id"], plainText: $0["plainText"], html: $0["html"]) }
        let attachments = attachmentRows.map {
            Attachment(id: $0["id"], filename: $0["filename"], mimeType: $0["mimeType"], size: $0["size"], contentHash: $0["contentHash"])
        }
        var thread = MailThread(id: threadId, accountId: accountId, messages: messages,
                                bodies: Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0) }),
                                attachments: Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) }))
        if let facts = try conversationFacts(db, accountId: accountId)[accountId] {
            let kinds = Dictionary(zip(rows, messages).map { ($1.id, TrafficKind(rawValue: $0["trafficKind"]) ?? .human) },
                                   uniquingKeysWith: { first, _ in first })
            let override = try Row.fetchOne(db, sql: "SELECT * FROM conversation_override WHERE accountId = ? AND threadId = ?",
                                            arguments: [accountId, threadId]).map(override)
            thread.state = StateInference.infer(messages: messages, kinds: kinds, facts: facts, override: override).state
        }
        return thread
    }

    private static func messages(_ rows: [Row], db: Database) throws -> [Message] {
        guard !rows.isEmpty else { return [] }
        // One JSON parameter avoids SQLite's bind-variable limit on large result sets.
        let rowIds = try encode(rows.map { $0["rowid"] as Int64 })
        let memberships = try Row.fetchAll(db, sql: """
            SELECT m.rowid, mm.mailboxId FROM message m
            JOIN message_mailbox mm ON mm.accountId = m.accountId AND mm.messageId = m.id
            WHERE m.rowid IN (SELECT value FROM json_each(?))
            """, arguments: [rowIds])
        let attachments = try Row.fetchAll(db, sql: """
            SELECT m.rowid, a.id FROM message m
            JOIN attachment a ON a.accountId = m.accountId AND a.messageId = m.id
            WHERE m.rowid IN (SELECT value FROM json_each(?))
            ORDER BY m.rowid, a.position
            """, arguments: [rowIds])
        var mailboxIds: [Int64: Set<String>] = [:]
        var attachmentIds: [Int64: [String]] = [:]
        for row in memberships { mailboxIds[row["rowid"], default: []].insert(row["mailboxId"]) }
        for row in attachments { attachmentIds[row["rowid"], default: []].append(row["id"]) }
        return try rows.map { row in
            let rowId: Int64 = row["rowid"]
            return Message(id: row["id"], accountId: row["accountId"], threadId: row["threadId"], subject: row["subject"],
                           sender: try decode(row["sender"]), to: try decode(row["recipients"]), cc: try decode(row["cc"]),
                           bcc: try decode(row["bcc"]), replyTo: try decode(row["replyTo"]), date: Date(timeIntervalSince1970: row["date"]),
                           internetMessageId: row["internetMessageId"], inReplyTo: row["inReplyTo"], references: try decode(row["referenceIds"]),
                           flags: MessageFlags(rawValue: row["flags"]), mailboxIds: mailboxIds[rowId, default: []],
                           bodyId: row["bodyId"], attachmentIds: attachmentIds[rowId, default: []],
                           automationHeaders: try decode(row["automationHeaders"] ?? "{}"),
                           activityCategory: row.hasColumn("activityCategory")
                               ? (row["activityCategory"] as String?).flatMap(ActivityCategory.init(rawValue:)) : nil)
        }
    }

    private static func validate(_ action: OutboxAction, accountId: String) throws {
        switch action {
        case .send(let message, let body, let attachments), .saveDraft(let message, let body, let attachments):
            guard message.accountId == accountId else { throw MailRepositoryError.accountMismatch }
            guard message.bodyId == body.id, message.attachmentIds == attachments.map(\.id),
                  Set(message.attachmentIds).count == message.attachmentIds.count,
                  attachments.allSatisfy({ $0.size >= 0 }) else { throw MailRepositoryError.invalidMessageReferences }
        default: break
        }
    }

    private static func insert(_ action: OutboxAction, accountId: String, notBefore: Date, db: Database) throws -> Int64 {
        try db.execute(sql: "INSERT INTO outbox (accountId, action, notBefore) VALUES (?, ?, ?)",
                       arguments: [accountId, try encode(action), notBefore.timeIntervalSince1970])
        return db.lastInsertedRowID
    }

    private static func addMailbox(messageId: String, mailboxId: String, accountId: String, db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO message_mailbox (accountId, messageId, mailboxId)
            SELECT ?, ?, id FROM mailbox WHERE accountId = ? AND id = ?
            """, arguments: [accountId, messageId, accountId, mailboxId])
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ value: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Foundation.Data(value.utf8))
    }

    private static func decodeEnum<T: RawRepresentable>(_ type: T.Type, _ value: String) throws -> T where T.RawValue == String {
        guard let result = T(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown \(type): \(value)"))
        }
        return result
    }

    private struct ThreadKey: Hashable {
        let accountId: String
        let threadId: String
    }
}
