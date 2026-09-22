import Data
import Domain
import Foundation
import Testing
@testable import Features

@MainActor
private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
}

@Test func mailboxSelectionStorageRoundTripsOpaqueIDs() {
    let selections: [MailboxSelection] = [.unified(.inbox), .unified(.starred), .unified(.drafts), .unified(.sent),
        .view(.attention), .view(.later), .mailbox(accountId: "a/\"b", mailboxId: "folder/子")]
    for selection in selections { #expect(MailboxSelection(storageValue: selection.storageValue) == selection) }
    #expect(MailboxSelection(storageValue: "invalid") == nil)
    #expect(MailboxSelection(storageValue: "[\"unified\",\"trash\"]") == nil)
    #expect(MailboxSelection(storageValue: "[\"view\",\"inbox\"]") == nil)
}

@Test func quotedTextPreservesInlineReplies() {
    #expect(QuotedMessageText("Hello\n\n> Old message\n> More").body == "Hello")
    #expect(QuotedMessageText("Hello\n> Old message").quote == "> Old message")
    let inline = "> Question\nMy answer\n> Another question"
    #expect(QuotedMessageText(inline).body == inline)
    #expect(QuotedMessageText(inline).quote == nil)
    #expect(QuotedMessageText("No quote").quote == nil)
}

@Test @MainActor func searchNavigationBulkActionsAndComposeRouting() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "a@example.com")))
    try await repository.upsert(Mailbox(id: "in", accountId: "a", kind: .inbox, name: "Inbox"))
    try await repository.upsert(Mailbox(id: "trash", accountId: "a", kind: .trash, name: "Trash"))
    for (index, subject) in ["Alpha", "Beta", "Gamma"].enumerated() {
        try await repository.upsert(Message(id: subject, accountId: "a", threadId: subject, subject: subject,
            sender: EmailAddress(address: "sender@example.com"), date: Date(timeIntervalSince1970: Double(300 - index)),
            flags: index == 0 ? [.starred] : [], mailboxIds: ["in"]))
    }
    let model = ThreadListModel(repository: repository)
    let restored: Set<ThreadSelection> = [ThreadSelection(accountId: "a", threadId: "Alpha"), ThreadSelection(accountId: "missing", threadId: "missing")]
    let observation = Task { await model.observe(.unified(.inbox), restoring: restored) }
    defer { observation.cancel() }
    try await eventually { model.rows.count == 3 }
    #expect(model.selection?.threadId == "Alpha")
    model.selection = nil
    model.selectNext(1)
    #expect(model.selection?.threadId == "Alpha")
    model.selectNext(1)
    #expect(model.selection?.threadId == "Beta")
    model.selectNext(-1)
    #expect(model.selection?.threadId == "Alpha")
    var composeCalls = 0
    model.compose = { _ in composeCalls += 1 }
    model.composeMessage(.reply)
    model.composeMessage(.forward)
    model.composeMessage(.newMessage)
    #expect(composeCalls == 3)
    model.selections = Set(model.rows.prefix(2).map(\.id))
    #expect(model.selection == nil)
    #expect(model.hasSelection)
    await model.perform(.toggleStar)
    try await eventually { !model.rows.contains(where: \.isStarred) }
    await model.perform(.markRead)
    try await eventually { model.rows.filter(\.isUnread).count == 1 }
    model.searchText = "Beta"
    await model.search()
    #expect(model.rows.map(\.subject) == ["Beta"])
    #expect(model.selection?.threadId == "Beta")
    model.searchText = ""
    await model.search()
    #expect(model.rows.count == 3)
    model.selections = Set(model.rows.prefix(2).map(\.id))
    await model.perform(.trash)
    try await eventually { model.rows.map(\.subject) == ["Gamma"] }
    #expect(try await repository.threads(in: .mailbox(accountId: "a", mailboxId: "trash")).count == 2)
    await model.observe(nil)
    await model.search()
    #expect(model.rows.isEmpty)
}

@Test @MainActor func unreadBadgesObserveFlagsAndDeduplicateUnifiedMembership() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "a@example.com")))
    for id in ["one", "two"] { try await repository.upsert(Mailbox(id: id, accountId: "a", kind: .inbox, name: id)) }
    try await repository.upsert(Message(id: "m", accountId: "a", threadId: "t", subject: "Subject",
        sender: EmailAddress(address: "s@example.com"), date: .now, mailboxIds: ["one", "two"]))
    let model = MailboxSidebarModel(repository: repository)
    let observation = Task { await model.observeUnreadCounts() }
    defer { observation.cancel() }
    try await eventually { model.unreadCounts[.unified(.inbox)] == 1 }
    #expect(model.unreadCounts[.mailbox(accountId: "a", mailboxId: "one")] == 1)
    try await repository.perform(.changeFlags(messageId: "m", flags: .read, enabled: true), accountId: "a")
    try await eventually { model.unreadCounts[.unified(.inbox), default: 0] == 0 }
}
