import AppKit
import Domain
import SwiftUI

@MainActor
enum MailListShortcut: Equatable {
    case next, previous, done, later, flag, reply, compose, unread, read, needsReply

    static func isEditingText(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }

    static func resolve(_ characters: String, modifiers: EventModifiers, isEditingText: Bool) -> Self? {
        guard !isEditingText, modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        if modifiers.contains(.shift) {
            return switch characters.lowercased() {
            case "u": .unread
            case "i": .read
            case "r": .needsReply
            default: nil
            }
        }
        return switch characters {
        case "j": .next
        case "k": .previous
        case "e": .done
        case "l": .later
        case "s": .flag
        case "r": .reply
        case "c": .compose
        default: nil
        }
    }
}

@MainActor
public struct ThreadListView: View {
    @Bindable var model: ThreadListModel
    let hasMailbox: Bool
    var status: [String: SyncStatus] = [:]
    var refresh: @MainActor () async -> Void = {}
    var emptyView: ConversationView? = nil
    var open: @MainActor (Set<ThreadSelection>) -> Void = { _ in }
    var isCovered = false
    @State private var showsPlaceholder = false
    @AppStorage(ListTextSize.storageKey) private var textSize = ListTextSize.standard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activity: SyncActivity { SyncActivity(status: status) }
    private var initialLoad: Bool { model.isLoading && model.rows.isEmpty }

    public var body: some View {
        Group {
            if let error = model.errorMessage {
                ContentUnavailableView("Unable to Load Mail", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !hasMailbox {
                Color.clear
            } else if initialLoad {
                if showsPlaceholder { ProgressView().controlSize(.small) } else { Color.clear }
            } else {
                GeometryReader { proxy in
                    table(topInset: proxy.safeAreaInsets.top)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .overlay(alignment: .bottom) {
                    if model.isActivityView && !isCovered { ActivityTabBar(model: model) }
                }
                .overlay {
                    if model.rows.isEmpty {
                        ContentUnavailableView(model.searchText.isEmpty ? emptyTitle : "No Results", systemImage: model.searchText.isEmpty ? emptySymbol : "magnifyingglass", description: Text(model.searchText.isEmpty ? emptyDescription : "Try a different search in this mailbox."))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .onChange(of: reduceMotion, initial: true) { _, value in model.reduceMotion = value }
        .task(id: initialLoad) {
            showsPlaceholder = false
            guard initialLoad else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            showsPlaceholder = true
        }
        .alert("Unable to Update Message", isPresented: Binding(
            get: { model.actionErrorMessage != nil },
            set: { if !$0 { model.dismissActionError() } }
        )) { Button("OK") { model.dismissActionError() } } message: { Text(model.actionErrorMessage ?? "") }
    }

    private func table(topInset: CGFloat) -> ThreadTableView {
        ThreadTableView(
            rows: model.rows, isActivity: model.isActivityView,
            showsHeaders: model.activityFilter == nil,
            bottomInset: model.isActivityView ? ActivityTabBar.height : 0,
            isHidden: isCovered,
            selections: model.selections,
            expanded: model.expandedActivitySenders, topInset: topInset, isRefreshEnabled: !activity.isSyncing,
            reduceMotion: reduceMotion, textSize: textSize,
            setSelections: { model.selections = $0 },
            toggleGroup: { id in
                model.focusedActivitySender = id
                if !model.expandedActivitySenders.insert(id).inserted { model.expandedActivitySenders.remove(id) }
            },
            refresh: refresh, open: open, menu: menu(for:), swipeActions: swipeActions(for:edge:),
            shortcut: handle, delete: { perform(.trash, on: model.selections) })
    }

    private func handle(_ shortcut: MailListShortcut) {
        switch shortcut {
        case .next: model.selectNext(1)
        case .previous: model.selectNext(-1)
        case .done: perform(model.isConversationView ? .done : .archive, on: model.selections)
        case .later: perform(.later(until: LaterPreset.tomorrow.date()), on: model.selections)
        case .needsReply: perform(.needsReply, on: model.selections)
        case .flag: perform(.toggleStar, on: model.selections)
        case .reply: if model.selection != nil { model.composeMessage(.reply) }
        case .compose: model.composeMessage(.newMessage)
        case .unread: perform(.markUnread, on: model.selections)
        case .read: perform(.markRead, on: model.selections)
        }
    }

    private func swipeActions(for row: ThreadListRow, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        let targets = model.selections.contains(row.id) ? model.selections : [row.id]
        func action(_ key: String.LocalizationValue, symbol: String, color: NSColor?, style: NSTableViewRowAction.Style = .regular,
                    _ command: ThreadCommand) -> NSTableViewRowAction {
            let title = String(localized: key)
            let action = NSTableViewRowAction(style: style, title: title) { _, _ in perform(command, on: targets) }
            action.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            if let color { action.backgroundColor = color }
            return action
        }
        switch edge {
        case .trailing:
            let trash = action("Move to Trash", symbol: "trash", color: nil, style: .destructive, .trash)
            if model.isActivityView { return [trash] }
            return [trash, model.isConversationView
                        ? action("Done", symbol: "checkmark.circle", color: .systemGreen, .done)
                        : action("Archive", symbol: "archivebox", color: .systemBlue, .archive)]
        case .leading:
            if model.isActivityView { return [] }
            return [model.isConversationView
                        ? action("Later", symbol: "clock", color: .systemOrange, .later(until: LaterPreset.tomorrow.date()))
                        : action("Flag", symbol: "flag", color: .systemOrange, .toggleStar)]
        @unknown default:
            return []
        }
    }

    private var emptyTitle: String {
        switch emptyView {
        case .attention: "You're All Caught Up"
        case .waiting: "Nothing Waiting"
        case .later: "Nothing Set Aside"
        case .activity: "No Activity"
        case .done, nil: "No Messages"
        }
    }

    private var emptySymbol: String {
        switch emptyView {
        case .attention: "checkmark.circle"
        case .waiting: "hourglass"
        case .later: "clock"
        case .activity: "bell.slash"
        case .done, nil: "tray"
        }
    }

    private var emptyDescription: String {
        switch emptyView {
        case .attention: "Conversations that need you will appear here."
        case .waiting: "Conversations where you are waiting on a reply will appear here."
        case .later: "Conversations you set aside will return here on their date."
        case .activity: "Receipts, newsletters, and notifications will appear here."
        case .done, nil: "Messages will appear here after syncing."
        }
    }

    private func menu(for ids: Set<ThreadSelection>) -> NSMenu {
        let menu = NSMenu()
        guard let row = model.rows.first(where: { ids.contains($0.id) }) else { return menu }
        let isStarred = ids == model.selections ? model.isSelectionStarred : row.isStarred
        let isUnread = ids == model.selections ? model.isSelectionUnread : row.isUnread
        func item(_ title: String.LocalizationValue, _ symbol: String, _ handler: @escaping () -> Void) {
            menu.addItem(ActionMenuItem(String(localized: title), symbol: symbol, handler: handler))
        }
        func command(_ title: String.LocalizationValue, _ symbol: String, _ command: ThreadCommand) {
            item(title, symbol) { perform(command, on: ids) }
        }
        func senderRule(_ kind: TrafficKind?) { Task { if let kind { await model.setSenderRule(kind, on: ids) } else { await model.resetSenderRule(on: ids) } } }

        item("Open in New Window", "macwindow") { open(ids) }
        menu.addItem(.separator())
        if model.isConversationView && model.supportsConversationState {
            command("Done", "checkmark.circle", .done)
            let later = NSMenuItem(title: String(localized: "Later"), action: nil, keyEquivalent: "")
            later.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            let presets = NSMenu()
            for preset in LaterPreset.allCases {
                presets.addItem(ActionMenuItem(preset.title) { perform(.later(until: preset.date()), on: ids) })
            }
            later.submenu = presets
            menu.addItem(later)
            command("Needs Reply", "arrowshape.turn.up.left.circle", .needsReply)
            if row.state == .waiting || row.state == .done || row.state == .later {
                command("Move to Attention", "circle.inset.filled", .reopen)
            }
            menu.addItem(.separator())
        }
        item("Treat as Person", "person") { senderRule(.human) }
        if model.canSetSenderRule(.activity) { item("Treat as Activity", "bell") { senderRule(.activity) } }
        if model.hasSenderRule(for: row.id) { item("Reset Sender Rule", "arrow.counterclockwise") { senderRule(nil) } }
        menu.addItem(.separator())
        // Activity keeps its menu short: no Archive or Flag.
        if !model.isActivityView { command("Archive", "archivebox", .archive) }
        command("Move to Trash", "trash", .trash)
        if !model.isActivityView { command(isStarred ? "Unflag" : "Flag", "flag", .toggleStar) }
        command(isUnread ? "Mark as Read" : "Mark as Unread", "envelope", isUnread ? .markRead : .markUnread)
        return menu
    }

    private func perform(_ command: ThreadCommand, on ids: Set<ThreadSelection>) {
        guard !ids.isEmpty else { return }
        Task { await model.perform(command, on: ids) }
    }
}

extension ThreadListRow {
    var stateTag: String? {
        switch state {
        case .needsReply: String(localized: "Needs Reply")
        case .later: String(localized: "Later")
        default: nil
        }
    }

    /// Activity rows show the first snippet line as their title instead of a subject.
    var activityTitle: String? { snippet.split(whereSeparator: \.isNewline).first.map(String.init) }

    var accessibilityDescription: String {
        [sender, subject.displaySubject, stateTag ?? "",
         isUnread ? String(localized: "Unread") : String(localized: "Read"),
         isStarred ? String(localized: "Starred") : "",
         hasAttachments ? String(localized: "Has attachments") : "",
         messageCount > 1 ? "\(messageCount) messages" : "", snippet]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
