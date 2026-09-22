import Data
import Domain
import Foundation
import GRDB
import Testing

private let me = "a@example.com"

private func repository() async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: me), capabilities: [.labels]))
    try await repository.upsert(Mailbox(id: "INBOX", accountId: "a", kind: .inbox, name: "Inbox", isSystem: true))
    try await repository.upsert(Mailbox(id: "SENT", accountId: "a", kind: .sent, name: "Sent", isSystem: true))
    try await repository.upsert(Mailbox(id: "TRASH", accountId: "a", kind: .trash, name: "Trash", isSystem: true))
    return repository
}

private func message(_ id: String, thread: String = "t", from: String, to: String? = nil, date: Double,
                     mailboxIds: Set<String> = ["INBOX"], headers: [String: String] = [:]) -> Message {
    Message(id: id, accountId: "a", threadId: thread, subject: "Subject \(id)", sender: EmailAddress(address: from),
            to: [EmailAddress(address: to ?? (from == me ? "anna@example.com" : me))], date: Date(timeIntervalSince1970: date),
            mailboxIds: mailboxIds, bodyId: id, automationHeaders: headers)
}

private func ids(_ conversations: [Conversation]) -> [String] { conversations.map(\.thread.id) }

@Test func conversationsAreGroupedByInferredStateAndKind() async throws {
    let repository = try await repository()
    try await repository.upsert(message("1", thread: "attention", from: "anna@example.com", date: 100),
                                body: MessageBody(id: "1", plainText: "Can we meet?\n\nOn Mon Anna wrote:\n> old"))
    try await repository.upsert(message("2", thread: "waiting", from: "bob@example.com", date: 100))
    try await repository.upsert(message("3", thread: "waiting", from: me, to: "bob@example.com", date: 200, mailboxIds: ["INBOX", "SENT"]))
    try await repository.upsert(message("4", thread: "done", from: "carl@example.com", date: 100, mailboxIds: []))
    try await repository.upsert(message("5", thread: "shop", from: "noreply@shop.example", date: 100))
    try await repository.upsert(message("6", thread: "list", from: "dora@example.com", date: 100, headers: ["list-unsubscribe": "<x>"]))
    try await repository.upsert(message("7", thread: "trash", from: "eve@example.com", date: 100, mailboxIds: ["TRASH"]))

    let attention = try await repository.conversations(in: .attention)
    #expect(ids(attention) == ["attention"])
    #expect(attention.first?.thread.snippet == "Can we meet?")
    #expect(attention.first?.state == .attention)
    #expect(ids(try await repository.conversations(in: .waiting)) == ["waiting"])
    #expect(ids(try await repository.conversations(in: .done)) == ["done"])
    #expect(Set(ids(try await repository.conversations(in: .activity))) == ["shop", "list"])
    #expect(try await repository.conversations(in: .later).isEmpty)
    var counts: [ConversationView: Int] = [:]
    for try await value in repository.observeConversationCounts() { counts = value; break }
    #expect(counts == [.attention: 1, .waiting: 1, .done: 1, .activity: 2])
}

@Test func knownContactsStayHumanAndSenderRulesReclassifyHistory() async throws {
    let repository = try await repository()
    try await repository.upsert(message("sent", thread: "s", from: me, to: "anna@team.example", date: 50, mailboxIds: ["SENT"]))
    try await repository.upsert(message("1", thread: "t1", from: "anna@team.example", date: 100, headers: ["list-id": "team"]))
    try await repository.upsert(message("2", thread: "t2", from: "noreply@shop.example", date: 100))
    #expect(ids(try await repository.conversations(in: .attention)) == ["t1"])
    #expect(ids(try await repository.conversations(in: .activity)) == ["t2"])

    try await repository.setSenderRule(SenderRule(accountId: "a", address: "NoReply@shop.example", kind: .human))
    #expect(Set(ids(try await repository.conversations(in: .attention))) == ["t1", "t2"])
    #expect(try await repository.senderRules(accountId: "a").map(\.address) == ["noreply@shop.example"])
    try await repository.upsert(message("3", thread: "t3", from: "noreply@shop.example", date: 300))
    #expect(Set(ids(try await repository.conversations(in: .attention))) == ["t1", "t2", "t3"])

    try await repository.clearSenderRule(accountId: "a", address: "noreply@shop.example")
    #expect(Set(ids(try await repository.conversations(in: .activity))) == ["t2", "t3"])
    #expect(try await repository.senderRules(accountId: "a").isEmpty)
}

@Test func overridesAreStoredWithLastWriterWinsAndDropWhenStale() async throws {
    let repository = try await repository()
    try await repository.upsert(message("1", from: "anna@example.com", date: 100))
    let later = ConversationOverride(accountId: "a", threadId: "t", state: .later, until: Date(timeIntervalSince1970: 4_000_000_000),
                                     setAt: Date(timeIntervalSince1970: 150))
    try await repository.setOverride(later)
    #expect(ids(try await repository.conversations(in: .later)) == ["t"])
    #expect(try await repository.conversations(in: .attention).isEmpty)

    let older = ConversationOverride(accountId: "a", threadId: "t", state: .needsReply, setAt: Date(timeIntervalSince1970: 120))
    try await repository.setOverride(older)
    #expect(try await repository.overrides(accountId: "a") == [later], "an older write does not replace a newer one")

    let newer = ConversationOverride(accountId: "a", threadId: "t", state: .needsReply, setAt: Date(timeIntervalSince1970: 160))
    try await repository.setOverride(newer)
    #expect(try await repository.overrides() == [newer])
    #expect(ids(try await repository.conversations(in: .attention)) == ["t"])

    try await repository.upsert(message("2", from: me, date: 200, mailboxIds: ["INBOX", "SENT"]))
    #expect(ids(try await repository.conversations(in: .waiting)) == ["t"], "my reply makes the stored needsReply inert")

    try await repository.clearOverride(accountId: "a", threadId: "t")
    #expect(try await repository.overrides().isEmpty)
    try await repository.removeAccount(id: "a")
    #expect(try await repository.overrides().isEmpty)
}

@Test func derivedDataIsReproducibleFromTheRawStore() async throws {
    let repository = try await repository()
    let raw = "Hello\n\n-- \nSig"
    try await repository.upsert(message("1", from: "anna@example.com", date: 100), body: MessageBody(id: "1", plainText: raw))
    try await repository.upsert(message("2", thread: "u", from: "noreply@shop.example", date: 100), body: MessageBody(id: "2", html: "<p>Order <b>shipped</b></p>"))
    #expect(try await repository.conversations(in: .attention).first?.thread.snippet == "Hello")
    #expect(try await repository.search("shipped").map(\.id) == ["2"])
    #expect(try await repository.search("Sig").isEmpty, "signatures are not indexed")

    try await repository.rebuildDerivedData()
    #expect(try await repository.conversations(in: .attention).first?.thread.snippet == "Hello")
    #expect(ids(try await repository.conversations(in: .activity)) == ["u"])
    #expect(try await repository.thread(accountId: "a", threadId: "t")?.bodies["1"]?.plainText == raw, "raw body untouched")
}

@Test func messageStateUpdatesMoveConversationsBetweenViews() async throws {
    let repository = try await repository()
    try await repository.upsert(message("1", from: "anna@example.com", date: 100))
    #expect(ids(try await repository.conversations(in: .attention)) == ["t"])
    try await repository.perform(.removeMailbox(messageId: "1", mailboxId: "INBOX"), accountId: "a")
    #expect(ids(try await repository.conversations(in: .done)) == ["t"])
    try await repository.updateMessageState(accountId: "a", id: "1", flags: [.read], mailboxIds: ["INBOX"])
    #expect(ids(try await repository.conversations(in: .attention)) == ["t"])
    var seen: [[String]] = []
    for try await conversations in repository.observeConversations(in: .attention) {
        seen.append(ids(conversations))
        if seen.count == 1 { try await repository.perform(.move(messageId: "1", fromMailboxId: "INBOX", toMailboxId: "TRASH"), accountId: "a") }
        if seen.count == 2 { break }
    }
    #expect(seen == [["t"], []])
}
