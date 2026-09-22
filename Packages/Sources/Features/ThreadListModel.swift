import Data
import Domain
import Foundation
import Observation
import SwiftUI

public struct ThreadSelection: Hashable, Codable, Sendable {
    public let accountId: String
    public let threadId: String

    public let messageId: String?

    public init(accountId: String, threadId: String, messageId: String? = nil) {
        self.accountId = accountId
        self.threadId = threadId
        self.messageId = messageId
    }
}

public enum ThreadCommand: Equatable, Sendable {
    case archive, trash, toggleStar, markRead, markUnread
    case done, later(until: Date), needsReply, reopen
}

public enum LaterPreset: CaseIterable, Sendable {
    case laterToday, tomorrow, thisWeekend, nextWeek

    public var title: String {
        switch self {
        case .laterToday: "Later Today"
        case .tomorrow: "Tomorrow"
        case .thisWeekend: "This Weekend"
        case .nextWeek: "Next Week"
        }
    }

    public func date(from now: Date = .now, calendar: Calendar = .current) -> Date {
        let morning = DateComponents(hour: 9, minute: 0)
        func nextMorning(_ base: Date) -> Date { calendar.nextDate(after: base, matching: morning, matchingPolicy: .nextTime) ?? base }
        switch self {
        case .laterToday:
            let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
            return evening > now.addingTimeInterval(1_800) ? evening : now.addingTimeInterval(3 * 3_600)
        case .tomorrow:
            return nextMorning(calendar.startOfDay(for: now).addingTimeInterval(86_400 - 1))
        case .thisWeekend:
            let saturday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 7), matchingPolicy: .nextTime) ?? now
            return saturday
        case .nextWeek:
            return calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) ?? now
        }
    }
}

public struct ThreadListRow: Identifiable, Equatable, Sendable {
    public let id: ThreadSelection
    public let sender: String
    public let senderAddress: String
    public let hasAttachments: Bool
    public let isStarred: Bool
    public let subject: String
    public let snippet: String
    public let date: Date
    public let isUnread: Bool
    public let messageCount: Int
    public var state: ConversationState? = nil
    public var activityCategory: ActivityCategory? = nil
}

@MainActor @Observable
public final class ThreadListModel {
    public var selections: Set<ThreadSelection> = []
    public var selection: ThreadSelection? {
        get { selections.count == 1 ? selections.first : nil }
        set { selections = newValue.map { [$0] } ?? [] }
    }
    public var hasSelection: Bool { !selections.isEmpty }
    public var searchText = ""
    public var unreadOnly = false { didSet { if unreadOnly != oldValue { refilter() } } }
    /// Activity tab; nil shows every category. Ignored outside Activity.
    public var activityFilter: ActivityCategory? { didSet { if activityFilter != oldValue { refilter() } } }
    public var reduceMotion = false
    public var compose: @MainActor (ComposeIntent) -> Void = { _ in }
    public enum ComposeIntent { case newMessage, reply, replyAll, forward, editDraft }
    public var selectedLocalDraft: Message? {
        selection.flatMap { threads[$0]?.messages.first { $0.id.hasPrefix("local-draft:") && $0.flags.contains(.draft) } }
    }
    public func composeMessage(_ intent: ComposeIntent) { compose(intent) }
    private var allRows: [ThreadListRow] = []
    public private(set) var rows: [ThreadListRow] = []
    public private(set) var errorMessage: String?
    public private(set) var actionErrorMessage: String?
    public private(set) var isLoading = false
    public var isSelectionStarred: Bool { selections.contains { threads[$0]?.messages.contains { $0.flags.contains(.starred) } == true } }
    public var isSelectionUnread: Bool { selections.contains { threads[$0]?.messages.contains { !$0.flags.contains(.read) } == true } }
    public var selectionState: ConversationState? { selections.count == 1 ? selections.first.flatMap { threads[$0]?.state } : nil }
    public var isConversationView: Bool { if case .view = observedMailbox { true } else { false } }
    public var isActivityView: Bool { observedMailbox == .view(.activity) }
    public private(set) var senderRuleConfirmation: String?
    public var canSetSenderRule: Bool { !selections.isEmpty && selections.allSatisfy { threads[$0]?.messages.first != nil } }
    /// Activity items have no conversation state, so Done, Later, Needs Reply, and Move to Attention don't apply.
    public var supportsConversationState: Bool { !isActivityView }
    public var canChangeConversationState: Bool { hasSelection && supportsConversationState }
    public func canSetSenderRule(_ kind: TrafficKind) -> Bool { canSetSenderRule && !(kind == .activity && isActivityView) }
    public func supports(_ command: ThreadCommand) -> Bool {
        switch command {
        case .done, .later, .needsReply, .reopen: supportsConversationState
        case .archive, .trash, .toggleStar, .markRead, .markUnread: true
        }
    }
    public var selectionHasSenderRule: Bool { selections.contains { hasSenderRule(for: $0) } }
    public var activitySections: [ActivityFeedSection] { ActivityFeedSection.group(rows) }
    public var expandedActivitySenders: Set<ActivityFeedGroup.ID> = []
    private var selectedSenderGroup: ActivityFeedGroup? {
        activitySections.flatMap(\.groups).first { group in
            group.isCollapsedGroup && group.rows.contains { selections.contains($0.id) }
        }
    }
    public var focusedActivitySender: ActivityFeedGroup.ID?
    private var expandableSenderGroup: ActivityFeedGroup? {
        if let selectedSenderGroup { return selectedSenderGroup }
        guard selections.isEmpty else { return nil }
        let groups = activitySections.flatMap(\.groups).filter(\.isCollapsedGroup)
        return groups.first { $0.id == focusedActivitySender } ?? groups.first
    }
    public var canToggleSenderExpansion: Bool { isActivityView && expandableSenderGroup != nil }
    public func toggleSelectedSenderExpansion() {
        guard let group = expandableSenderGroup else { return }
        focusedActivitySender = group.id
        if !expandedActivitySenders.insert(group.id).inserted { expandedActivitySenders.remove(group.id) }
    }
    private var senderRules: [SenderRule] = []
    private let repository: SQLiteMailRepository
    private var threads: [ThreadSelection: MailThread] = [:]
    private var generation = UUID()
    private var observedMailbox: MailboxSelection?

    public init(repository: SQLiteMailRepository, composeOriginId: UUID = UUID()) {
        self.repository = repository
        compose = { [weak self] intent in
            if case .editDraft = intent {
                guard let draft = self?.selectedLocalDraft else { return }
                ComposeRequest.open(ComposeRequest(id: UUID(uuidString: String(draft.id.dropFirst("local-draft:".count))) ?? UUID(), source: self?.selection, messageId: draft.id, draftId: draft.id, inlineOrigin: composeOriginId))
                return
            }
            let kind: ComposeRequest.Kind = switch intent {
            case .newMessage, .editDraft: .newMessage
            case .reply: .reply
            case .replyAll: .replyAll
            case .forward: .forward
            }
            ComposeRequest.open(ComposeRequest(kind: kind, source: kind == .newMessage ? nil : self?.selection,
                messageId: kind == .newMessage ? nil : self?.selection?.messageId, inlineOrigin: composeOriginId))
        }
    }

    public func observe(_ mailbox: MailboxSelection?, restoring restoredSelections: Set<ThreadSelection> = []) async {
        var pendingRestoration = restoredSelections
        let generation = UUID()
        self.generation = generation
        if mailbox != observedMailbox {
            rows = []
            allRows = []
            threads = [:]
            senderRuleConfirmation = nil
            selection = nil
        }
        observedMailbox = mailbox
        errorMessage = nil
        guard let mailbox else { rows = []; selection = nil; isLoading = false; return }
        isLoading = true
        do {
            if isActivityView {
                for try await items in repository.observeActivityMessages() {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.threads = Dictionary(uniqueKeysWithValues: items.map { item in
                        let message = item.message
                        let id = ThreadSelection(accountId: message.accountId, threadId: message.threadId, messageId: message.id)
                        return (id, MailThread(id: message.threadId, accountId: message.accountId, messages: [message], snippet: item.displayText))
                    })
                    allRows = items.map { item in
                        let message = item.message
                        return ThreadListRow(id: ThreadSelection(accountId: message.accountId, threadId: message.threadId, messageId: message.id),
                            sender: message.sender.name ?? message.sender.address, senderAddress: message.sender.address,
                            hasAttachments: !message.attachmentIds.isEmpty, isStarred: message.flags.contains(.starred),
                            subject: message.subject, snippet: item.displayText, date: message.date,
                            isUnread: !message.flags.contains(.read), messageCount: 1, activityCategory: message.activityCategory ?? .notifications)
                    }
                    try await refreshSenderRules()
                    await search(animate: false)
                    guard self.generation == generation, !Task.isCancelled else { return }
                    if !pendingRestoration.isEmpty {
                        selections = pendingRestoration.intersection(Set(rows.map(\.id)))
                        pendingRestoration = []
                    }
                    isLoading = false
                }
                return
            }
            for try await threads in repository.observeThreads(in: mailbox) {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.threads = Dictionary(uniqueKeysWithValues: threads.map {
                    (ThreadSelection(accountId: $0.accountId, threadId: $0.id), $0)
                })
                allRows = threads.compactMap { thread in
                    guard let latest = thread.messages.first else { return nil }
                    return ThreadListRow(id: ThreadSelection(accountId: thread.accountId, threadId: thread.id),
                                         sender: latest.sender.name ?? latest.sender.address,
                                         senderAddress: latest.sender.address,
                                         hasAttachments: thread.messages.contains { !$0.attachmentIds.isEmpty },
                                         isStarred: thread.messages.contains { $0.flags.contains(.starred) }, subject: latest.subject,
                                         snippet: thread.snippet, date: latest.date,
                                         isUnread: thread.messages.contains { !$0.flags.contains(.read) }, messageCount: thread.messages.count,
                                         state: thread.state)
                }
                try await refreshSenderRules()
                await search(animate: false)
                guard self.generation == generation, !Task.isCancelled else { return }
                if !pendingRestoration.isEmpty {
                    selections = pendingRestoration.intersection(Set(rows.map(\.id)))
                    pendingRestoration = []
                }
                isLoading = false
            }
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func refilter() { Task { await search() } }

    public func search(animate: Bool = true) async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = self.generation
        do {
            let matches: Set<ThreadSelection>?
            if query.isEmpty { matches = nil }
            else {
                let messages = try await repository.search(query)
                matches = Set(messages.map { ThreadSelection(accountId: $0.accountId, threadId: $0.threadId, messageId: isActivityView ? $0.id : nil) })
            }
            guard !Task.isCancelled, generation == self.generation,
                  query == searchText.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            withAnimation(animate && !reduceMotion ? .snappy : nil) {
                let category = isActivityView ? activityFilter : nil
                rows = allRows.filter {
                    (matches?.contains($0.id) ?? true) && (!unreadOnly || $0.isUnread) && (category == nil || $0.activityCategory == category)
                }
                selections.formIntersection(Set(rows.map(\.id)))
            }
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func selectNext(_ offset: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { selections.contains($0.id) } ?? (offset > 0 ? -1 : rows.count)
        selection = rows[min(max(index + offset, 0), rows.count - 1)].id
        if isActivityView, let group = selectedSenderGroup {
            expandedActivitySenders.insert(group.id)
        }
    }

    private func refreshSenderRules() async throws {
        var rules: [SenderRule] = []
        for accountId in Set(allRows.map(\.id.accountId)) {
            rules += try await repository.senderRules(accountId: accountId)
        }
        senderRules = rules
    }

    public func hasSenderRule(for selection: ThreadSelection) -> Bool {
        guard let message = threads[selection]?.messages.first else { return false }
        return senderRules.contains { $0.accountId == message.accountId && $0.address == message.sender.address.lowercased() }
    }

    public func setSenderRule(_ kind: TrafficKind, on targets: Set<ThreadSelection>? = nil) async {
        await updateSenderRules(kind, on: targets ?? selections)
    }

    public func resetSenderRule(on targets: Set<ThreadSelection>? = nil) async {
        await updateSenderRules(nil, on: targets ?? selections)
    }

    private func updateSenderRules(_ kind: TrafficKind?, on targets: Set<ThreadSelection>) async {
        let messages = targets.compactMap { threads[$0]?.messages.first }
        actionErrorMessage = nil
        senderRuleConfirmation = nil
        var updated = Set<String>()
        do {
            for message in messages {
                let address = message.sender.address.lowercased()
                guard updated.insert(message.accountId + ":" + address).inserted else { continue }
                if let kind {
                    try await repository.setSenderRule(SenderRule(accountId: message.accountId, address: address, kind: kind))
                } else {
                    try await repository.clearSenderRule(accountId: message.accountId, address: address)
                }
            }
            guard !updated.isEmpty else { return }
            try await refreshSenderRules()
            senderRuleConfirmation = switch kind {
            case .human: "Sender treated as a person."
            case .activity: "Sender treated as Activity."
            case nil: "Sender rule reset."
            }
        } catch { actionErrorMessage = error.localizedDescription }
    }

    public func dismissActionError() { actionErrorMessage = nil }

    public func perform(_ command: ThreadCommand, on targets: Set<ThreadSelection>? = nil) async {
        guard supports(command) else { return }
        let targets = targets ?? selections
        let snapshot = rows.filter { targets.contains($0.id) }.compactMap { row in
            threads[row.id].map { (row.id, $0) }
        }
        let originalSelections = selections
        let generation = self.generation
        let lastIndex = rows.lastIndex { targets.contains($0.id) }
        let nextSelection = lastIndex.flatMap { index in
            rows.dropFirst(index + 1).first { !targets.contains($0.id) }?.id
                ?? rows.prefix(index).last { !targets.contains($0.id) }?.id
        }
        actionErrorMessage = nil
        let enableStar = !snapshot.contains { $0.1.messages.contains { $0.flags.contains(.starred) } }
        for (selection, thread) in snapshot {
            await perform(command, selection: selection, thread: thread, enableStar: enableStar)
            if actionErrorMessage != nil { break }
        }
        if actionErrorMessage == nil, Self.removesFromList(command),
           generation == self.generation, !originalSelections.isDisjoint(with: targets),
           selections.isSubset(of: originalSelections) {
            selection = nextSelection.flatMap { candidate in rows.contains { $0.id == candidate } ? candidate : nil }
        }
    }

    private static func removesFromList(_ command: ThreadCommand) -> Bool {
        switch command {
        case .archive, .trash, .done, .later, .reopen: true
        case .toggleStar, .markRead, .markUnread, .needsReply: false
        }
    }

    private func perform(_ command: ThreadCommand, selection: ThreadSelection, thread: MailThread, enableStar: Bool) async {
        do {
            let mailboxes = try await repository.mailboxes(accountId: selection.accountId)
            let inbox = mailboxes.first { $0.kind == .inbox }?.id
            let trash = mailboxes.first { $0.kind == .trash }?.id
            let archiveBox = mailboxes.first { $0.kind == .archive }?.id
            let newest = thread.messages.max { ($0.date, $0.id) < ($1.date, $1.id) }
            func archive() async throws {
                guard let inbox else { return }
                for message in thread.messages where message.mailboxIds.contains(inbox) {
                    // JMAP rejects an email with no mailbox; move it to Archive when Inbox is its only one.
                    if let archiveBox, message.mailboxIds.subtracting([inbox]).isEmpty {
                        try await repository.perform(.move(messageId: message.id, fromMailboxId: inbox, toMailboxId: archiveBox), accountId: selection.accountId)
                    } else {
                        try await repository.perform(.removeMailbox(messageId: message.id, mailboxId: inbox), accountId: selection.accountId)
                    }
                }
            }
            func cancelReturn() async throws {
                try await repository.cancelScheduledMailboxAdditions(accountId: selection.accountId, messageIds: Set(thread.messages.map(\.id)))
            }
            switch command {
            case .archive:
                try await archive()
            case .done:
                try await cancelReturn()
                try await repository.clearOverride(accountId: selection.accountId, threadId: selection.threadId)
                try await archive()
            case .later(let until):
                guard let inbox, let newest else { return }
                try await cancelReturn()
                try await repository.setOverride(ConversationOverride(accountId: selection.accountId, threadId: selection.threadId, state: .later, until: until))
                try await archive()
                // The server brings it back at the due date; a sync then turns the expired override into Attention.
                try await repository.enqueue(.addMailbox(messageId: newest.id, mailboxId: inbox), accountId: selection.accountId, notBefore: until)
            case .needsReply:
                try await repository.setOverride(ConversationOverride(accountId: selection.accountId, threadId: selection.threadId, state: .needsReply))
            case .reopen:
                guard let inbox, let newest else { return }
                try await cancelReturn()
                try await repository.setOverride(ConversationOverride(accountId: selection.accountId, threadId: selection.threadId, state: .attention))
                if !newest.mailboxIds.contains(inbox) {
                    try await repository.perform(.addMailbox(messageId: newest.id, mailboxId: inbox), accountId: selection.accountId)
                }
            case .trash:
                guard let trash else { return }
                for message in thread.messages where !message.mailboxIds.contains(trash) {
                    if let inbox, message.mailboxIds.contains(inbox) {
                        try await repository.perform(.move(messageId: message.id, fromMailboxId: inbox, toMailboxId: trash), accountId: selection.accountId)
                    } else {
                        try await repository.perform(.addMailbox(messageId: message.id, mailboxId: trash), accountId: selection.accountId)
                    }
                }
            case .toggleStar:
                let starred = thread.messages.filter { $0.flags.contains(.starred) }
                for message in enableStar ? thread.messages.max(by: { $0.date < $1.date }).map({ [$0] }) ?? [] : starred {
                    try await repository.perform(.changeFlags(messageId: message.id, flags: .starred, enabled: enableStar), accountId: selection.accountId)
                }
            case .markRead:
                for message in thread.messages where !message.flags.contains(.read) {
                    try await repository.perform(.changeFlags(messageId: message.id, flags: .read, enabled: true), accountId: selection.accountId)
                }
            case .markUnread:
                if let message = thread.messages.max(by: { $0.date < $1.date }) {
                    try await repository.perform(.changeFlags(messageId: message.id, flags: .read, enabled: false), accountId: selection.accountId)
                }
            }
        } catch { actionErrorMessage = error.localizedDescription }
    }

}
