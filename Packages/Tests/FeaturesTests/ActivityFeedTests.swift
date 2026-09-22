import Data
import Domain
import Foundation
import Testing
@testable import Features

@MainActor private func waitForFeed(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate())
}

private func feedRow(_ number: Int, category: ActivityCategory = .notifications, unread: Bool = true, account: String = "a", address: String = "alerts@example.com") -> ThreadListRow {
    ThreadListRow(id: ThreadSelection(accountId: account, threadId: "thread", messageId: "\(number)"),
        sender: "Alerts", senderAddress: address, hasAttachments: false, isStarred: false,
        subject: "Update", snippet: "First line\nSecond line", date: Date(timeIntervalSince1970: Double(number)),
        isUnread: unread, messageCount: 1, activityCategory: category)
}

@Test func activityGroupsUseCategoryOrderAndStrictUnseenThreshold() throws {
    let rows = [feedRow(0, category: .newsletters), feedRow(1, category: .security), feedRow(2, category: .money),
                feedRow(3, category: .orders)] + (4...7).map { feedRow($0) } + [feedRow(8, unread: false)]
    let sections = ActivityFeedSection.group(rows)
    #expect(sections.map(\.category) == [.orders, .money, .security, .notifications, .newsletters])
    let group = try #require(sections.first { $0.category == .notifications }?.groups.first)
    #expect(group.unseenCount == 4)
    #expect(group.isCollapsedGroup)
    #expect(group.rows.map(\.id.messageId) == ["8", "7", "6", "5", "4"])
    let three = ActivityFeedSection.group(Array(rows.filter { $0.activityCategory == .notifications }.dropFirst()))
    #expect(three.first?.groups.first?.unseenCount == 3)
    #expect(three.first?.groups.first?.isCollapsedGroup == false)
}

@Test func activityGroupingScopesSenderToAccountAndCategory() {
    let rows = [feedRow(1), feedRow(2, address: "ALERTS@example.com"), feedRow(3, account: "b"), feedRow(4, category: .orders)]
    let sections = ActivityFeedSection.group(rows)
    #expect(sections.count == 2)
    #expect(sections.last?.groups.count == 2)
    #expect(sections.last?.groups.first { $0.id.accountId == "a" }?.rows.count == 2)
    #expect(ActivityFeedSection.group([]).isEmpty)
}

@Test @MainActor func senderRulesFromListReclassifyHistoryAndMoveViews() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "me@example.com")))
    try await repository.upsert(Mailbox(id: "inbox", accountId: "a", kind: .inbox, name: "Inbox"))
    for index in 0..<4 {
        try await repository.upsert(Message(id: "m\(index)", accountId: "a", threadId: "thread", subject: "Update",
            sender: EmailAddress(address: "alerts@example.com"), date: Date(timeIntervalSince1970: Double(index)), mailboxIds: ["inbox"]))
    }
    let activity = ThreadListModel(repository: repository)
    let attention = ThreadListModel(repository: repository)
    let activityTask = Task { await activity.observe(.view(.activity)) }
    let attentionTask = Task { await attention.observe(.view(.attention)) }
    defer { activityTask.cancel(); attentionTask.cancel() }
    try await waitForFeed { activity.rows.count == 4 && !attention.isLoading }
    #expect(attention.rows.isEmpty)
    #expect(activity.rows.allSatisfy { $0.id.messageId != nil })
    #expect(activity.canToggleSenderExpansion)
    activity.toggleSelectedSenderExpansion()
    #expect(activity.selection == nil)
    #expect(activity.expandedActivitySenders.count == 1)
    #expect(activity.rows.allSatisfy { $0.isUnread })
    activity.toggleSelectedSenderExpansion()
    activity.selection = activity.rows.first?.id
    #expect(activity.canSetSenderRule)
    #expect(activity.canToggleSenderExpansion)
    activity.toggleSelectedSenderExpansion()
    #expect(activity.expandedActivitySenders.count == 1)
    await activity.perform(.needsReply)
    #expect(try await repository.overrides().isEmpty)
    await activity.setSenderRule(.human)
    try await waitForFeed { activity.rows.isEmpty && attention.rows.count == 1 }
    #expect(activity.senderRuleConfirmation == "Sender treated as a person.")
    #expect(activity.selection == nil)
    attention.selection = attention.rows.first?.id
    #expect(attention.selectionHasSenderRule)
    await attention.resetSenderRule()
    try await waitForFeed { attention.rows.isEmpty && activity.rows.count == 4 }
    #expect(try await repository.senderRules(accountId: "a").isEmpty)
    activity.selection = activity.rows.first?.id
    await activity.setSenderRule(.human)
    try await waitForFeed { attention.rows.count == 1 }
    attention.selection = attention.rows.first?.id
    await attention.setSenderRule(.activity)
    try await waitForFeed { attention.rows.isEmpty && activity.rows.count == 4 }
    #expect(try await repository.senderRules(accountId: "a").first?.kind == .activity)
}

@MainActor private final class ComposeCapture {
    var request: ComposeRequest?
}

@Test @MainActor func activityComposeTargetsSelectedMessage() throws {
    let model = ThreadListModel(repository: SQLiteMailRepository(writer: try AppDatabase().writer))
    model.selection = ThreadSelection(accountId: "a", threadId: "thread", messageId: "older-message")
    let capture = ComposeCapture()
    let observer = NotificationCenter.default.addObserver(forName: ComposeRequest.notification, object: nil, queue: nil) { notification in
        let request = notification.object as? ComposeRequest
        MainActor.assumeIsolated { capture.request = request }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    for intent in [ThreadListModel.ComposeIntent.reply, .replyAll, .forward] {
        model.composeMessage(intent)
        #expect(capture.request?.messageId == "older-message")
        #expect(capture.request?.source == model.selection)
    }
    model.composeMessage(.newMessage)
    #expect(capture.request?.messageId == nil)
    #expect(capture.request?.source == nil)
}

@Test func activitySelectionIdentityPreservesLegacyDecoding() throws {
    let data = Data(#"{"accountId":"a","threadId":"thread"}"#.utf8)
    let selection = try JSONDecoder().decode(ThreadSelection.self, from: data)
    #expect(selection.messageId == nil)
    #expect(selection != ThreadSelection(accountId: "a", threadId: "thread", messageId: "m"))
}

@Test @MainActor func activityTabFiltersByCategory() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "me@example.com")))
    try await repository.upsert(Mailbox(id: "inbox", accountId: "a", kind: .inbox, name: "Inbox"))
    for (index, subject) in ["Update", "Update", "Your verification code"].enumerated() {
        try await repository.upsert(Message(id: "m\(index)", accountId: "a", threadId: "t\(index)", subject: subject,
            sender: EmailAddress(address: "alerts@example.com"), date: Date(timeIntervalSince1970: Double(index)),
            mailboxIds: ["inbox"], automationHeaders: ["auto-submitted": "auto-generated"]))
    }
    let model = ThreadListModel(repository: repository)
    let task = Task { await model.observe(.view(.activity)) }
    defer { task.cancel() }
    try await waitForFeed { model.rows.count == 3 }
    #expect(Set(model.rows.compactMap(\.activityCategory)) == [.notifications, .security])
    model.activityFilter = .security
    await model.search(animate: false)
    #expect(model.rows.map(\.id.messageId) == ["m2"])
    model.activityFilter = nil
    await model.search(animate: false)
    #expect(model.rows.count == 3)
}
