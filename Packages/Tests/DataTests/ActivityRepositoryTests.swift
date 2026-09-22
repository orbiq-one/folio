import Data
import Domain
import Foundation
import GRDB
import Testing

private func activityRepository(_ database: AppDatabase) async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: database.writer)
    for account in ["a", "b"] {
        try await repository.upsert(Account(id: account, provider: .gmail, displayName: account,
                                            email: EmailAddress(address: "me@\(account).example"), capabilities: [.labels]))
        for kind in [MailboxKind.inbox, .trash, .spam] {
            try await repository.upsert(Mailbox(id: kind.rawValue, accountId: account, kind: kind, name: kind.rawValue))
        }
    }
    return repository
}

private func activityMessage(_ id: String, account: String = "a", subject: String = "Update",
                             flags: MessageFlags = [], mailboxes: Set<String> = ["inbox"]) -> Message {
    Message(id: id, accountId: account, threadId: "shared", subject: subject,
            sender: EmailAddress(address: "noreply@shop.example"), date: Date(timeIntervalSince1970: 100),
            flags: flags, mailboxIds: mailboxes, bodyId: id)
}

@Test func activityCategoriesPersistRebuildAndFollowSenderRules() async throws {
    let database = try AppDatabase()
    let repository = try await activityRepository(database)
    let message = activityMessage("m")
    let body = MessageBody(id: "m", plainText: "Your parcel shipped\n\n-- \nShop Team")
    try await repository.upsert(message, body: body)
    #expect(try await repository.thread(accountId: "a", threadId: "shared")?.messages.first?.activityCategory == .orders)
    #expect(try await repository.activityMessages().first?.displayText == "Your parcel shipped")

    try await repository.upsert(message)
    #expect(try await repository.activityMessages().first?.message.activityCategory == .orders, "header-only sync retains cached body classification")
    try await repository.upsert(message, body: MessageBody(id: "m", plainText: "Your payment: $19"))
    #expect(try await repository.activityMessages().first?.message.activityCategory == .money)

    try await database.writer.write { db in
        try db.execute(sql: "UPDATE message SET activityCategory = 'notifications'; UPDATE message_body SET displayText = 'stale'")
    }
    try await repository.rebuildDerivedData()
    #expect(try await repository.activityMessages().first?.message.activityCategory == .money)
    #expect(try await repository.activityMessages().first?.displayText == "Your payment: $19")

    try await repository.setSenderRule(SenderRule(accountId: "a", address: message.sender.address, kind: .human))
    #expect(try await repository.activityMessages().isEmpty)
    #expect(try await repository.thread(accountId: "a", threadId: "shared")?.messages.first?.activityCategory == nil)
    #expect(try await repository.conversations(in: .attention).count == 1)
    try await repository.clearSenderRule(accountId: "a", address: message.sender.address)
    #expect(try await repository.activityMessages().first?.message.activityCategory == .money)
    #expect(try await repository.conversations(in: .attention).isEmpty)
}

@Test func activityFeedIsMessageLevelAccountScopedAndExcludesHiddenAndDrafts() async throws {
    let repository = try await activityRepository(AppDatabase())
    try await repository.upsert(activityMessage("1", subject: "Order shipped"))
    try await repository.upsert(activityMessage("2", flags: [.read], mailboxes: []))
    try await repository.upsert(activityMessage("1", account: "b", subject: "Receipt"))
    try await repository.upsert(activityMessage("trash", mailboxes: ["inbox", "trash"]))
    try await repository.upsert(activityMessage("spam", mailboxes: ["spam"]))
    try await repository.upsert(activityMessage("draft", flags: [.draft]))
    let items = try await repository.activityMessages()
    #expect(items.map { "\($0.message.accountId):\($0.message.id)" } == ["a:1", "a:2", "b:1"])
    #expect(items.map(\.message.activityCategory) == [.orders, .notifications, .money])
    for try await counts in repository.observeUnreadCounts() {
        #expect(counts[.view(.activity)] == 2)
        #expect(counts[.view(.attention), default: 0] == 0)
        break
    }
}

@Test func activityObservationTracksBodiesSeenFlagsAndRules() async throws {
    let repository = try await activityRepository(AppDatabase())
    try await repository.upsert(activityMessage("m"))
    var observed: [ActivityItem?] = []
    for try await items in repository.observeActivityMessages() {
        observed.append(items.first)
        switch observed.count {
        case 1:
            try await repository.upsert(activityMessage("m"), body: MessageBody(id: "m", html: "<p>Order shipped</p>"))
        case 2:
            try await repository.perform(.changeFlags(messageId: "m", flags: .read, enabled: true), accountId: "a")
        case 3:
            try await repository.setSenderRule(SenderRule(accountId: "a", address: "noreply@shop.example", kind: .human))
        default: break
        }
        if observed.count == 4 { break }
    }
    #expect(observed.count == 4)
    #expect(observed[0]?.message.activityCategory == .notifications)
    #expect(observed[1]?.displayText == "Order shipped")
    #expect(observed[1]?.message.activityCategory == .orders)
    #expect(observed[2]?.message.flags.contains(.read) == true)
    #expect(observed[3] == nil)
}

@Test func activityUnseenCountObservationTracksIndividualFlags() async throws {
    let repository = try await activityRepository(AppDatabase())
    try await repository.upsert(activityMessage("1"))
    try await repository.upsert(activityMessage("2"))
    var counts: [Int] = []
    for try await values in repository.observeUnreadCounts() {
        counts.append(values[.view(.activity), default: 0])
        if counts.count == 1 {
            try await repository.perform(.changeFlags(messageId: "1", flags: .read, enabled: true), accountId: "a")
        }
        if counts.count == 2 { break }
    }
    #expect(counts == [2, 1])
}

@Test func migrationV4BackfillsExistingMessages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("mail.sqlite").path
    do {
        let database = try AppDatabase(path: path)
        let repository = try await activityRepository(database)
        try await repository.upsert(activityMessage("m"), body: MessageBody(id: "m", plainText: "Your parcel shipped"))
        try await database.writer.write { db in
            try db.execute(sql: "ALTER TABLE message DROP COLUMN activityCategory; DELETE FROM grdb_migrations WHERE identifier = 'v4'")
        }
    }
    let database = try AppDatabase(path: path)
    let repository = SQLiteMailRepository(writer: database.writer)
    #expect(try await repository.activityMessages().first?.message.activityCategory == .orders)
    #expect(try await repository.activityMessages().first?.displayText == "Your parcel shipped")
}
