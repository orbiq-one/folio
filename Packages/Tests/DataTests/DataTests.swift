import Data
import Domain
import Foundation
import GRDB
import Synchronization
import Testing

private func account(_ id: String) -> Account {
    Account(id: id, provider: .gmail, displayName: "Account \(id)",
            email: EmailAddress(address: "\(id)@example.com", name: "Name"), capabilities: [.labels, .drafts])
}

private func message(_ id: String = "m", accountId: String = "a", threadId: String = "t", date: Double = 100,
                     mailboxIds: Set<String> = ["inbox"]) -> Message {
    Message(id: id, accountId: accountId, threadId: threadId, subject: "Subject \(id)",
            sender: EmailAddress(address: "sender@example.com", name: "Sender"),
            date: Date(timeIntervalSince1970: date), mailboxIds: mailboxIds)
}

private func repository(accounts: [String] = ["a"]) async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    for id in accounts {
        try await repository.upsert(account(id))
        try await repository.upsert(Mailbox(id: "inbox", accountId: id, kind: .inbox, name: "Inbox"))
    }
    return repository
}

@Test func migrationCreatesSchemaAndReopensWithoutDataLoss() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "mail.sqlite").path
    let database = try AppDatabase(path: path)
    #expect(database.writer is DatabasePool)
    #expect(try AppDatabase().writer is DatabaseQueue)
    #expect(try AppDatabase(path: ":memory:").writer is DatabaseQueue)
    let journalMode = try await database.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
    #expect(journalMode == "wal")
    let repository = SQLiteMailRepository(writer: database.writer)
    try await repository.upsert(account("a"))
    let tables = try await database.writer.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(Set(["account", "mailbox", "message", "message_body", "message_mailbox", "attachment", "outbox", "sync_state", "message_fts"]).isSubset(of: Set(tables)))
    let reopened = try AppDatabase(path: path)
    #expect(try await SQLiteMailRepository(writer: reopened.writer).accounts() == [account("a")])
    let migrations = try await reopened.writer.read { db in
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
    }
    #expect(migrations == ["v1", "v2", "v3", "v4", "v5"])
    let violations = try await reopened.writer.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count }
    #expect(violations == 0)
}

@Test func mailboxVisibilityMigrationPreservesExistingRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "mail.sqlite").path
    let database = try AppDatabase(path: path)
    let repository = SQLiteMailRepository(writer: database.writer)
    try await repository.upsert(account("a"))
    let mailbox = Mailbox(id: "inbox", accountId: "a", kind: .inbox, name: "Inbox")
    try await repository.upsert(mailbox)
    try await database.writer.write { db in
        try db.execute(sql: """
            ALTER TABLE mailbox DROP COLUMN isHidden;
            ALTER TABLE mailbox DROP COLUMN isSystem;
            DELETE FROM grdb_migrations WHERE identifier = 'v2';
            """)
    }
    let upgraded = SQLiteMailRepository(writer: try AppDatabase(path: path).writer)
    #expect(try await upgraded.mailboxes(accountId: "a") == [mailbox])
    var hidden = mailbox
    hidden.isHidden = true
    hidden.isSystem = true
    try await upgraded.upsert(hidden)
    #expect(try await upgraded.mailboxes(accountId: "a") == [hidden])
}

@Test func messageStateUpdatePreservesContentAndIsAccountScopedAndAtomic() async throws {
    let repository = try await repository(accounts: ["a", "b"])
    var value = message()
    value.bodyId = "body"
    value.attachmentIds = ["file"]
    let body = MessageBody(id: "body", plainText: "Preserved", html: "<p>Preserved</p>")
    let attachment = Attachment(id: "file", filename: "keep.txt", mimeType: "text/plain", size: 9, contentHash: "hash")
    try await repository.upsert(value, body: body, attachments: [attachment])
    try await repository.upsert(message("other", accountId: "b"))
    #expect(try await repository.messageIds(accountId: "a") == ["m"])
    #expect(try await repository.messageIds(accountId: "b") == ["other"])
    try await repository.updateMessageState(accountId: "a", id: "m", flags: [.read, .starred], mailboxIds: [])
    value.flags = [.read, .starred]
    value.mailboxIds = []
    let thread = try #require(try await repository.thread(accountId: "a", threadId: "t"))
    #expect(thread.messages == [value])
    #expect(thread.bodies == ["body": body])
    #expect(thread.attachments == ["file": attachment])
    await #expect(throws: (any Error).self) {
        try await repository.updateMessageState(accountId: "a", id: "m", flags: [], mailboxIds: ["missing"])
    }
    #expect(try await repository.thread(accountId: "a", threadId: "t") == thread)
    #expect(try await repository.thread(accountId: "b", threadId: "t")?.messages.first?.flags.isEmpty == true)
}

@Test func accountMailboxMessageBodyAttachmentAndCursorRoundTrip() async throws {
    let repository = try await repository()
    var updatedAccount = account("a")
    updatedAccount.displayName = "Renamed"
    try await repository.upsert(updatedAccount)
    #expect(try await repository.accounts() == [updatedAccount])
    let folder = Mailbox(id: "parent", accountId: "a", kind: .folder, name: "Parent")
    var label = Mailbox(id: "label", accountId: "a", kind: .label, name: "Label", parentId: folder.id)
    try await repository.upsert(folder)
    try await repository.upsert(label)
    label.name = "Updated"
    try await repository.upsert(label)
    #expect(try await repository.mailboxes(accountId: "a").contains(label))

    var value = message(mailboxIds: ["inbox", "label"])
    value.to = [EmailAddress(address: "to@example.com", name: "To")]
    value.cc = [EmailAddress(address: "cc@example.com")]
    value.bcc = [EmailAddress(address: "bcc@example.com")]
    value.replyTo = [EmailAddress(address: "reply@example.com")]
    value.internetMessageId = "<message@example.com>"
    value.inReplyTo = "<previous@example.com>"
    value.references = ["<root@example.com>", "<previous@example.com>"]
    value.flags = [.read, .starred, .answered]
    value.bodyId = "body"
    value.attachmentIds = ["z", "a"]
    let body = MessageBody(id: "body", plainText: "Body", html: "<p>Body</p>")
    let attachments = [Attachment(id: "z", filename: "résumé.pdf", mimeType: "application/pdf", size: 123, contentHash: "abc"),
                       Attachment(id: "a", filename: "pending.txt", mimeType: "text/plain", size: 0)]
    try await repository.upsert(value, body: body, attachments: attachments)
    let thread = try #require(try await repository.thread(accountId: "a", threadId: "t"))
    #expect(thread.messages == [value])
    #expect(thread.bodies == ["body": body])
    #expect(thread.attachments == Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) }))
    let list = try await repository.threads(in: .unified(.inbox))
    #expect(list.first?.messages == [value])
    #expect(list.first?.bodies.isEmpty == true)
    #expect(list.first?.attachments.isEmpty == true)

    try await repository.setSyncCursor("history-1", accountId: "a")
    try await repository.setSyncCursor("history-2", accountId: "a")
    try await repository.setSyncCursor("uid-state", accountId: "a", scope: "inbox")
    #expect(try await repository.syncCursor(accountId: "a") == "history-2")
    #expect(try await repository.syncCursor(accountId: "a", scope: "inbox") == "uid-state")
    #expect(try await repository.syncCursor(accountId: "missing") == nil)
    #expect(try await repository.thread(accountId: "missing", threadId: "t") == nil)
}

@Test func unifiedInboxScopesProviderIdsAndDeduplicatesLabels() async throws {
    let repository = try await repository(accounts: ["a", "b"])
    try await repository.upsert(Mailbox(id: "second", accountId: "a", kind: .inbox, name: "Second Inbox Label"))
    try await repository.upsert(Mailbox(id: "label", accountId: "a", kind: .label, name: "Label"))
    let first = message(date: 100, mailboxIds: ["inbox", "second", "label"])
    let second = message(accountId: "b", date: 200)
    try await repository.upsert(first)
    try await repository.upsert(second)
    try await repository.upsert(first)
    let unified = try await repository.threads(in: .unified(.inbox))
    #expect(unified.map(\.accountId) == ["b", "a"])
    #expect(unified.map(\.id) == ["t", "t"])
    #expect(unified.flatMap(\.messages) == [second, first])
    for mailboxId in ["inbox", "second", "label"] {
        #expect(try await repository.threads(in: .mailbox(accountId: "a", mailboxId: mailboxId)).flatMap(\.messages) == [first])
    }
    try await repository.upsert(message("reply", date: 300, mailboxIds: []))
    let conversation = try #require(try await repository.thread(accountId: "a", threadId: "t"))
    #expect(conversation.messages.map(\.id) == ["m", "reply"])
    #expect(try await repository.threads(in: .unified(.inbox)).first?.messages.map(\.id) == ["reply", "m"])
}

@Test func messageReplacementIsAtomicAndRemovesStaleReferences() async throws {
    let repository = try await repository()
    var value = message()
    value.bodyId = "old"
    value.attachmentIds = ["file"]
    try await repository.upsert(value, body: MessageBody(id: "old", plainText: "obsolete"),
                                attachments: [Attachment(id: "file", filename: "a", mimeType: "text/plain", size: 1)])
    var invalid = value
    invalid.subject = "Must roll back"
    invalid.mailboxIds = ["nonexistent"]
    invalid.bodyId = "new"
    await #expect(throws: (any Error).self) {
        try await repository.upsert(invalid, body: MessageBody(id: "new"),
                                    attachments: [Attachment(id: "file", filename: "a", mimeType: "text/plain", size: 1)])
    }
    #expect(try await repository.thread(accountId: "a", threadId: "t")?.messages == [value])
    #expect(try await repository.search("obsolete").map(\.id) == ["m"])
    value.bodyId = "new"
    value.attachmentIds = []
    value.mailboxIds = []
    value.flags = .read
    try await repository.upsert(value, body: MessageBody(id: "new", plainText: "replacement"))
    let thread = try #require(try await repository.thread(accountId: "a", threadId: "t"))
    #expect(thread.messages == [value])
    #expect(thread.bodies.keys.sorted() == ["new"])
    #expect(thread.attachments.isEmpty)
    #expect(try await repository.threads(in: .unified(.inbox)).isEmpty)
    #expect(try await repository.search("obsolete").isEmpty)
}

@Test func outboxRoundTripsEveryActionAndRemainsFIFOAcrossReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "mail.sqlite").path
    let repository = SQLiteMailRepository(writer: try AppDatabase(path: path).writer)
    try await repository.upsert(account("a"))
    try await repository.upsert(account("b"))
    var draft = message(mailboxIds: [])
    draft.bodyId = "body"
    let body = MessageBody(id: "body", plainText: "Draft")
    let actions: [OutboxAction] = [
        .changeFlags(messageId: "m", flags: [.read, .starred], enabled: true),
        .addMailbox(messageId: "m", mailboxId: "label"),
        .removeMailbox(messageId: "m", mailboxId: "label"),
        .move(messageId: "m", fromMailboxId: "inbox", toMailboxId: "trash"),
        .send(message: draft, body: body, attachments: []),
        .saveDraft(message: draft, body: body, attachments: []),
        .deleteDraft(messageId: "m"),
    ]
    var ids: [Int64] = []
    for action in actions {
        ids.append(try await repository.enqueue(action, accountId: "a"))
    }
    let otherId = try await repository.enqueue(.deleteDraft(messageId: "other"), accountId: "b")
    let reopened = SQLiteMailRepository(writer: try AppDatabase(path: path).writer)
    for (id, action) in zip(ids, actions) {
        let entry = try #require(try await reopened.nextOutboxAction(accountId: "a"))
        #expect(entry.id == id)
        #expect(entry.action == action)
        #expect(entry.accountId == "a")
        #expect(try await reopened.nextOutboxAction(accountId: "a") == entry)
        try await reopened.dequeueOutboxAction(id: id, accountId: "b")
        #expect(try await reopened.nextOutboxAction(accountId: "a") == entry)
        try await reopened.dequeueOutboxAction(id: id, accountId: "a")
    }
    #expect(try await reopened.nextOutboxAction(accountId: "a") == nil)
    #expect(try await reopened.nextOutboxAction(accountId: "b")?.id == otherId)
    await #expect(throws: MailRepositoryError.accountMismatch) {
        try await reopened.enqueue(.send(message: draft, body: body, attachments: []), accountId: "b")
    }
}

@Test func delayedOutboxHeadDoesNotBlockReadyActions() async throws {
    let repository = try await repository(accounts: ["a", "b"])
    let due = Date(timeIntervalSince1970: 1_000)
    let before = due.addingTimeInterval(-1)
    var draft = message(mailboxIds: [])
    draft.bodyId = "body"
    let first = try await repository.enqueue(.send(message: draft, body: MessageBody(id: "body"), attachments: []),
                                             accountId: "a", notBefore: due)
    let second = try await repository.enqueue(.changeFlags(messageId: "m", flags: .read, enabled: true), accountId: "a")
    let third = try await repository.enqueue(.removeMailbox(messageId: "m", mailboxId: "inbox"), accountId: "a")
    let other = try await repository.enqueue(.deleteDraft(messageId: "other"), accountId: "b")
    #expect(try await repository.nextOutboxAction(accountId: "a", now: before)?.id == second)
    #expect(try await repository.nextOutboxAction(accountId: "b", now: before)?.id == other)
    try await repository.dequeueOutboxAction(id: second, accountId: "a")
    #expect(try await repository.nextOutboxAction(accountId: "a", now: before)?.id == third)
    #expect(try await repository.nextOutboxAction(accountId: "a", now: due)?.id == first)
    try await repository.dequeueOutboxAction(id: third, accountId: "a")
    #expect(try await repository.nextOutboxAction(accountId: "a", now: before) == nil)
    #expect(try await repository.nextOutboxAction(accountId: "a", now: due)?.id == first)
}

@Test func performAppliesOptimisticChangesAndEnqueuesAtomically() async throws {
    let repository = try await repository()
    try await repository.upsert(Mailbox(id: "trash", accountId: "a", kind: .trash, name: "Trash"))
    try await repository.upsert(message())
    try await repository.perform(.changeFlags(messageId: "m", flags: [.read, .starred], enabled: true), accountId: "a")
    #expect(try await repository.thread(accountId: "a", threadId: "t")?.messages.first?.flags == [.read, .starred])
    let first = try #require(try await repository.nextOutboxAction(accountId: "a"))
    #expect(first.action == .changeFlags(messageId: "m", flags: [.read, .starred], enabled: true))
    try await repository.dequeueOutboxAction(id: first.id, accountId: "a")
    try await repository.perform(.move(messageId: "m", fromMailboxId: "inbox", toMailboxId: "trash"), accountId: "a")
    #expect(try await repository.thread(accountId: "a", threadId: "t")?.messages.first?.mailboxIds == ["trash"])
    #expect(try await repository.nextOutboxAction(accountId: "a")?.action == .move(messageId: "m", fromMailboxId: "inbox", toMailboxId: "trash"))
}

@Test func performIgnoresMissingMailboxMembershipButStillEnqueues() async throws {
    let repository = try await repository()
    try await repository.upsert(message())
    try await repository.perform(.addMailbox(messageId: "m", mailboxId: "missing"), accountId: "a")
    #expect(try await repository.thread(accountId: "a", threadId: "t")?.messages.first?.mailboxIds == ["inbox"])
    #expect(try await repository.nextOutboxAction(accountId: "a")?.action == .addMailbox(messageId: "m", mailboxId: "missing"))
}

@Test func searchTracksSubjectSenderBodyUpdatesAndDeletion() async throws {
    let database = try AppDatabase()
    let repository = SQLiteMailRepository(writer: database.writer)
    for id in ["a", "b"] { try await repository.upsert(account(id)) }
    var value = message(mailboxIds: [])
    value.subject = "Orchard plans"
    value.sender = EmailAddress(address: "gardener@example.com", name: "Alex")
    value.bodyId = "body"
    try await repository.upsert(value, body: MessageBody(id: "body", plainText: "Clementine harvest", html: "<p>HTMLonly</p>"))
    var other = value
    other.accountId = "b"
    other.date = Date(timeIntervalSince1970: 200)
    try await repository.upsert(other, body: MessageBody(id: "body", plainText: "Clementine"))
    #expect(try await repository.search("Orchard").map(\.accountId) == ["b", "a"])
    #expect(try await repository.search("Clementine", accountId: "a") == [value])
    #expect(try await repository.search("gardener", accountId: "a") == [value])
    #expect(try await repository.search("Alex", accountId: "a") == [value])
    #expect(try await repository.search("HTMLonly").isEmpty)
    #expect(try await repository.search("address").isEmpty)
    #expect(try await repository.search("   ").isEmpty)
    #expect(try await repository.search("\" OR * (").isEmpty)
    value.subject = "Updated subject"
    value.sender = EmailAddress(address: "new@example.com")
    try await repository.upsert(value, body: MessageBody(id: "body", plainText: "Tangerine"))
    #expect(try await repository.search("Orchard", accountId: "a").isEmpty)
    #expect(try await repository.search("Alex", accountId: "a").isEmpty)
    #expect(try await repository.search("Clementine", accountId: "a").isEmpty)
    #expect(try await repository.search("Tangerine", accountId: "a") == [value])
    try await repository.upsert(value)
    #expect(try await repository.search("Tangerine", accountId: "a") == [value])
    try await database.writer.write { db in
        try db.execute(sql: "DELETE FROM message_body WHERE accountId = 'a'")
    }
    #expect(try await repository.search("Tangerine", accountId: "a").isEmpty)
    try await database.writer.write { db in try db.execute(sql: "DELETE FROM account WHERE id = 'b'") }
    #expect(try await repository.search("Orchard").isEmpty)
}

@Test(.timeLimit(.minutes(1))) func observationsEmitInitialInsertAndBodyUpdate() async throws {
    let repository = try await repository()
    var list = repository.observeThreads(in: .unified(.inbox)).makeAsyncIterator()
    var detail = repository.observeThread(accountId: "a", threadId: "t").makeAsyncIterator()
    #expect(try await list.next() == [])
    let initialDetail = try await detail.next()
    #expect(initialDetail != nil)
    #expect(initialDetail! == nil)
    var value = message()
    value.bodyId = "body"
    try await repository.upsert(value, body: MessageBody(id: "body", plainText: "Initial"))
    #expect(try await list.next()?.first?.messages == [value])
    #expect(try await detail.next()??.bodies["body"]?.plainText == "Initial")
    try await repository.upsert(value, body: MessageBody(id: "body", plainText: "Updated"))
    #expect(try await detail.next()??.bodies["body"]?.plainText == "Updated")
}

@Test func searchSurvivesVacuumWithStableMessageRowIds() async throws {
    let database = try AppDatabase()
    let repository = SQLiteMailRepository(writer: database.writer)
    try await repository.upsert(account("a"))
    var survivor = message("survivor", mailboxIds: [])
    survivor.bodyId = "body"
    try await repository.upsert(message("deleted", mailboxIds: []))
    try await repository.upsert(survivor, body: MessageBody(id: "body", plainText: "Vacuumproof"))
    try await database.writer.write { db in
        try db.execute(sql: "DELETE FROM message WHERE id = 'deleted'")
    }
    let before = try await database.writer.read { try Int64.fetchOne($0, sql: "SELECT rowid FROM message") }
    let explicitPrimaryKey = try await database.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(message)").contains {
            ($0["name"] as String) == "rowid" && ($0["type"] as String) == "INTEGER" && ($0["pk"] as Int) == 1
        }
    }
    #expect(explicitPrimaryKey)
    try await database.writer.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
    let after = try await database.writer.read { try Int64.fetchOne($0, sql: "SELECT rowid FROM message") }
    #expect(after == before)
    #expect(try await repository.search("survivor") == [survivor])
    #expect(try await repository.search("Vacuumproof") == [survivor])
    #expect(try await repository.search("deleted").isEmpty)
}

@Test func messageReferencesAreBatchedAcrossAccounts() async throws {
    let database = try AppDatabase()
    let repository = SQLiteMailRepository(writer: database.writer)
    var expected: [Message] = []
    for accountId in ["a", "b"] {
        try await repository.upsert(account(accountId))
        try await repository.upsert(Mailbox(id: "inbox", accountId: accountId, kind: .inbox, name: "Inbox"))
        try await repository.upsert(Mailbox(id: "label-\(accountId)", accountId: accountId, kind: .label, name: "Label"))
        for index in 0..<12 {
            var value = message("m\(index)", accountId: accountId, date: Double(index), mailboxIds: ["inbox", "label-\(accountId)"])
            let attachments = ["z", "a"].map {
                Attachment(id: "\(index)-\($0)-\(accountId)", filename: $0, mimeType: "text/plain", size: 1)
            }
            value.attachmentIds = attachments.map(\.id)
            try await repository.upsert(value, attachments: attachments)
            expected.append(value)
        }
    }
    let statements = Mutex<[String]>([])
    try await database.writer.writeWithoutTransaction { db in
        db.trace { event in
            let sql = String(describing: event).lowercased()
            if sql.hasPrefix("select") { statements.withLock { $0.append(sql) } }
        }
    }
    let threads = try await repository.threads(in: .unified(.inbox))
    let queries = statements.withLock { $0 }
    #expect(queries.filter { $0.contains("message_mailbox") }.count == 2)
    #expect(queries.filter { $0.contains("attachment") }.count == 1)
    #expect(threads.flatMap(\.messages).count == expected.count)
    for value in expected { #expect(threads.flatMap(\.messages).contains(value)) }
    statements.withLock { $0.removeAll() }
    let detail = try await repository.thread(accountId: "a", threadId: "t")
    let detailQueries = statements.withLock { $0 }
    #expect(detailQueries.filter { $0.contains("message_mailbox") }.count == 1)
    #expect(detailQueries.filter { $0.contains("attachment") }.count == 2)
    #expect(detail?.messages == expected.filter { $0.accountId == "a" })
    statements.withLock { $0.removeAll() }
    let results = try await repository.search("Subject")
    let searchQueries = statements.withLock { $0 }
    #expect(searchQueries.filter { $0.contains("message_mailbox") }.count == 1)
    #expect(searchQueries.filter { $0.contains("attachment") }.count == 1)
    #expect(results.count == expected.count)
    for value in expected { #expect(results.contains(value)) }
    try await database.writer.writeWithoutTransaction { $0.trace(options: []) }
}

@Test func invalidReferencesAndCrossAccountMembershipAreRejected() async throws {
    let repository = try await repository(accounts: ["a", "b"])
    try await repository.upsert(Mailbox(id: "private", accountId: "b", kind: .label, name: "Private"))
    await #expect(throws: (any Error).self) {
        try await repository.upsert(message(mailboxIds: ["private"]))
    }
    await #expect(throws: MailRepositoryError.invalidMessageReferences) {
        try await repository.upsert(message(), body: MessageBody(id: "unreferenced"))
    }
    var value = message()
    value.attachmentIds = ["file"]
    await #expect(throws: MailRepositoryError.invalidMessageReferences) { try await repository.upsert(value) }
    await #expect(throws: (any Error).self) {
        try await repository.upsert(value, attachments: [Attachment(id: "file", filename: "f", mimeType: "text/plain", size: -1)])
    }
    #expect(try await repository.threads(in: .unified(.inbox)).isEmpty)
}

@Test func rejectedActionReconciliationIsAtomicAndPreservesPendingEdits() async throws {
    let repository = try await repository(accounts: ["a", "b"])
    try await repository.upsert(Mailbox(id: "archive", accountId: "a", kind: .archive, name: "Archive"))
    let remote = message(mailboxIds: ["archive"])
    try await repository.upsert(remote)
    let rejected = try await repository.perform(.removeMailbox(messageId: "m", mailboxId: "archive"), accountId: "a")
    let pending = try await repository.perform(.changeFlags(messageId: "m", flags: .starred, enabled: true), accountId: "a")
    let scheduled = try await repository.enqueue(.addMailbox(messageId: "m", mailboxId: "inbox"), accountId: "a",
                                                  notBefore: .now.addingTimeInterval(3_600))
    await #expect(throws: MailRepositoryError.accountMismatch) {
        try await repository.reconcileFailedOutboxAction(id: rejected, accountId: "a", message: message(accountId: "b"), body: nil)
    }
    await #expect(throws: MailRepositoryError.accountMismatch) {
        try await repository.reconcileFailedOutboxAction(id: rejected, accountId: "a", message: message("wrong"), body: nil)
    }
    await #expect(throws: (any Error).self) {
        try await repository.reconcileFailedOutboxAction(id: rejected, accountId: "a", message: message(mailboxIds: ["unknown"]), body: nil)
    }
    #expect(try await repository.nextOutboxAction(accountId: "a")?.id == rejected)
    let unchanged = try #require(try await repository.thread(accountId: "a", threadId: "t")?.messages.first)
    #expect(unchanged.mailboxIds.isEmpty)
    #expect(unchanged.flags == [.starred])

    try await repository.reconcileFailedOutboxAction(id: rejected, accountId: "a", message: remote, body: nil)
    let restored = try #require(try await repository.thread(accountId: "a", threadId: "t")?.messages.first)
    #expect(restored.mailboxIds == ["archive"])
    #expect(restored.flags == [.starred])
    #expect(try await repository.nextOutboxAction(accountId: "a")?.id == pending)
    try await repository.dequeueOutboxAction(id: pending, accountId: "a")
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(try await repository.nextOutboxAction(accountId: "a", now: .now.addingTimeInterval(3_601))?.id == scheduled)
}

@Test func clearedSenderNameSurvivesStaleBackfillAndDatabaseReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "mail.sqlite").path
    let repository = SQLiteMailRepository(writer: try AppDatabase(path: path).writer)
    try await repository.upsert(account("a"))
    #expect(try await repository.senderNameNeedsBackfill(accountId: "a"))
    try await repository.setSenderName(nil, accountId: "a")
    try await repository.setSenderName("Stale provider response", accountId: "a", onlyIfMissing: true)
    let reopened = SQLiteMailRepository(writer: try AppDatabase(path: path).writer)
    #expect(try await reopened.accounts().first?.email.name == nil)
    #expect(try await reopened.senderNameNeedsBackfill(accountId: "a") == false)
}

@Test func rankedSearchMatchesAnyTermSkipsDraftsAndReturnsMatchedText() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(account("a"))
    var cruise = message(mailboxIds: [])
    cruise.id = "cruise"
    cruise.subject = "Summer plans"
    cruise.bodyId = "cruise-body"
    try await repository.upsert(cruise, body: MessageBody(id: "cruise-body", plainText: "Join our fjord cruise next July"))
    var draft = cruise
    draft.id = "draft"
    draft.flags = [.draft]
    draft.bodyId = "draft-body"
    try await repository.upsert(draft, body: MessageBody(id: "draft-body", plainText: "cruise notes"))
    let hits = try await repository.rankedSearch(anyOf: ["sailing", "cruise"], limit: 5)
    #expect(hits.map(\.message.id) == ["cruise"])
    #expect(hits.first?.text == "Join our fjord cruise next July")
    #expect(try await repository.rankedSearch(anyOf: [], limit: 5).isEmpty)
}

@Test func threadCarriesLiveInferredState() async throws {
    let repository = try await repository()
    try await repository.upsert(message())
    #expect(try await repository.thread(accountId: "a", threadId: "t")?.state == .attention)
    try await repository.setOverride(ConversationOverride(accountId: "a", threadId: "t", state: .needsReply))
    #expect(try await repository.thread(accountId: "a", threadId: "t")?.state == .needsReply)
}
