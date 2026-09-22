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

private let me = "a@example.com"

private func seed() async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: me)))
    try await repository.upsert(Mailbox(id: "INBOX", accountId: "a", kind: .inbox, name: "Inbox"))
    try await repository.upsert(Mailbox(id: "TRASH", accountId: "a", kind: .trash, name: "Trash"))
    for (index, thread) in ["Alpha", "Beta"].enumerated() {
        try await repository.upsert(Message(id: thread, accountId: "a", threadId: thread, subject: thread,
            sender: EmailAddress(address: "anna@example.com"), to: [EmailAddress(address: me)],
            date: Date(timeIntervalSince1970: Double(300 - index)), mailboxIds: ["INBOX"]))
    }
    return repository
}

@Test @MainActor func attentionCommandsMoveConversationsBetweenViewsAndServer() async throws {
    let repository = try await seed()
    let model = ThreadListModel(repository: repository)
    let observation = Task { await model.observe(.view(.attention)) }
    defer { observation.cancel() }
    try await eventually { model.rows.count == 2 }
    #expect(model.isConversationView)
    #expect(model.rows.map(\.id.threadId) == ["Alpha", "Beta"])
    #expect(model.rows.allSatisfy { $0.state == .attention })

    model.selection = ThreadSelection(accountId: "a", threadId: "Alpha")
    await model.perform(.needsReply)
    try await eventually { model.rows.first?.state == .needsReply }
    #expect(model.selectionState == .needsReply)
    #expect(model.rows.count == 2, "needsReply stays in Attention")

    let until = Date(timeIntervalSince1970: 4_000_000_000)
    await model.perform(.later(until: until))
    try await eventually { model.rows.count == 1 }
    #expect(model.selection?.threadId == "Beta", "selection advances to the next row")
    #expect(try await repository.conversations(in: .later).map(\.thread.id) == ["Alpha"])
    let scheduled = try await repository.nextOutboxAction(accountId: "a", now: until.addingTimeInterval(1))
    var returns: [OutboxEntry] = []
    var cursor = scheduled
    while let entry = cursor {
        returns.append(entry)
        try await repository.dequeueOutboxAction(id: entry.id, accountId: "a")
        cursor = try await repository.nextOutboxAction(accountId: "a", now: until.addingTimeInterval(1))
    }
    let addBack = returns.compactMap { entry -> String? in
        if case .addMailbox(let id, "INBOX") = entry.action, entry.notBefore == until { id } else { nil }
    }
    #expect(addBack == ["Alpha"], "the server re-adds the newest message to Inbox on the due date")

    await model.perform(.done)
    try await eventually { model.rows.isEmpty }
    #expect(try await repository.conversations(in: .done).map(\.thread.id) == ["Beta"])
    #expect(try await repository.overrides().map(\.threadId) == ["Alpha"], "Beta had no override; Alpha keeps its later")
}

@Test @MainActor func laterCancellationRemovesScheduledReturnAndReopenRestoresInbox() async throws {
    let repository = try await seed()
    let model = ThreadListModel(repository: repository)
    let observation = Task { await model.observe(.view(.attention)) }
    defer { observation.cancel() }
    try await eventually { model.rows.count == 2 }
    model.selection = ThreadSelection(accountId: "a", threadId: "Alpha")
    let until = Date(timeIntervalSince1970: 4_000_000_000)
    await model.perform(.later(until: until))
    try await eventually { model.rows.count == 1 }

    let later = ThreadListModel(repository: repository)
    let laterObservation = Task { await later.observe(.view(.later)) }
    defer { laterObservation.cancel() }
    try await eventually { later.rows.count == 1 }
    #expect(later.rows.first?.state == .later)
    later.selection = ThreadSelection(accountId: "a", threadId: "Alpha")
    await later.perform(.reopen)
    try await eventually { later.rows.isEmpty }
    try await eventually { model.rows.count == 2 }
    #expect(try await repository.nextOutboxAction(accountId: "a", now: until.addingTimeInterval(1)).flatMap {
        if case .addMailbox = $0.action { $0 } else { nil }
    } == nil, "the scheduled return was cancelled")
    #expect(try await repository.conversations(in: .attention).map(\.thread.id) == ["Alpha", "Beta"])
}

@Test func laterPresetsLandInTheFuture() {
    let calendar = Calendar(identifier: .gregorian)
    let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 10))!
    let tomorrow = LaterPreset.tomorrow.date(from: monday, calendar: calendar)
    #expect(calendar.component(.day, from: tomorrow) == 22 && calendar.component(.hour, from: tomorrow) == 9)
    #expect(calendar.component(.weekday, from: LaterPreset.thisWeekend.date(from: monday, calendar: calendar)) == 7)
    let nextWeek = LaterPreset.nextWeek.date(from: monday, calendar: calendar)
    #expect(calendar.component(.weekday, from: nextWeek) == 2 && calendar.component(.day, from: nextWeek) == 28)
    #expect(LaterPreset.laterToday.date(from: monday, calendar: calendar) > monday)
    for preset in LaterPreset.allCases { #expect(preset.date(from: monday, calendar: calendar) > monday) }
}

@Test @MainActor func singleKeyLayerMapsStateActions() {
    #expect(MailListShortcut.resolve("e", modifiers: [], isEditingText: false) == .done)
    #expect(MailListShortcut.resolve("l", modifiers: [], isEditingText: false) == .later)
    #expect(MailListShortcut.resolve("s", modifiers: [], isEditingText: false) == .flag)
    #expect(MailListShortcut.resolve("R", modifiers: .shift, isEditingText: false) == .needsReply)
    #expect(MailListShortcut.resolve("e", modifiers: [], isEditingText: true) == nil)
}
