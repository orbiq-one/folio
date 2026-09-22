import AppKit
import Data
import Domain
import SwiftUI

private struct ThreadListFocusedValueKey: FocusedValueKey { typealias Value = ThreadListModel }
private struct ThreadDetailFocusedValueKey: FocusedValueKey { typealias Value = ThreadDetailModel }
private struct MailSearchFocusedValueKey: FocusedValueKey { typealias Value = @MainActor () -> Void }

public extension FocusedValues {
    var focusMailSearch: (@MainActor () -> Void)? {
        get { self[MailSearchFocusedValueKey.self] }
        set { self[MailSearchFocusedValueKey.self] = newValue }
    }

    var threadDetail: ThreadDetailModel? {
        get { self[ThreadDetailFocusedValueKey.self] }
        set { self[ThreadDetailFocusedValueKey.self] = newValue }
    }

    var threadList: ThreadListModel? {
        get { self[ThreadListFocusedValueKey.self] }
        set { self[ThreadListFocusedValueKey.self] = newValue }
    }
}

@MainActor
public struct MailView: View {
    @SceneStorage("mail.mailboxSelection") private var savedMailbox = ""
    @SceneStorage("mail.threadSelection") private var savedThreads = ""
    @State private var isReady = false
    @State private var restoredThreads = false
    @State private var sidebar: MailboxSidebarModel
    @State private var list: ThreadListModel
    @Bindable private var accounts: AccountModel
    @Binding private var showingAddAccount: Bool
    @Environment(\.openWindow) private var openWindow
    @AppStorage("mail.badgeEnabled") private var badgeEnabled = true
    @SceneStorage("mail.sidebarWidth") private var sidebarWidth = Double(MailColumnLayout.sidebar.ideal)
    @State private var restoredSidebarWidth: CGFloat?
    @State private var isSearchPresented = false
    @State private var searchFocusRequest = 0
    @State private var isAssistantActive = false
    @State private var assistant: AssistantModel
    @State private var composeOriginId: UUID

    private var currentView: ConversationView? {
        if case .view(let view) = sidebar.selection { view } else { nil }
    }

    public init(repository: SQLiteMailRepository, accounts: AccountModel, showingAddAccount: Binding<Bool>) {
        _sidebar = State(initialValue: MailboxSidebarModel(repository: repository))
        _assistant = State(initialValue: AssistantModel(repository: repository))
        let composeOriginId = UUID()
        _composeOriginId = State(initialValue: composeOriginId)
        _list = State(initialValue: ThreadListModel(repository: repository, composeOriginId: composeOriginId))
        self.accounts = accounts
        _showingAddAccount = showingAddAccount
    }

    public var body: some View {
        NavigationSplitView {
            MailboxSidebarView(model: sidebar, status: accounts.status)
                .modifier(PersistedColumnWidth(column: MailColumnLayout.sidebar, restored: $restoredSidebarWidth, stored: $sidebarWidth))
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button { list.composeMessage(.newMessage) } label: {
                            Label("New Message", systemImage: "plus")
                        }
                        .help("New Message (⇧⌘N)")
                    }
                }
        } detail: {
            Group {
                if sidebar.accounts.isEmpty && !sidebar.isLoading {
                    ContentUnavailableView {
                        Label("No Accounts", systemImage: "envelope")
                    } description: {
                        Text("Add an account to start reading your mail.")
                    } actions: {
                        Button("Add Account…") { showingAddAccount = true }
                    }
                } else {
                    ThreadListView(model: list, hasMailbox: sidebar.selection != nil, status: accounts.status, refresh: {
                        guard !accounts.isSyncing else { return }
                        await accounts.refresh()
                    }, emptyView: currentView, open: openThreads, isCovered: isAssistantActive)
                }
            }
            // The list stays mounted under Ask Mail so toggling never rebuilds the table.
            .opacity(isAssistantActive ? 0 : 1)
            .allowsHitTesting(!isAssistantActive)
            .overlay {
                if isAssistantActive {
                    AssistantView(model: assistant, open: openAssistantResult, close: toggleAssistant)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(sidebar.title)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Text(sidebar.title).font(.system(size: 13, weight: .semibold))
                        if !list.rows.isEmpty {
                            Text(list.rows.count, format: .number)
                                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .fixedSize()
                    .help(list.senderRuleConfirmation ?? "")
                    .accessibilityElement(children: .combine)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    if isSearchPresented {
                        MailSearchField(text: $list.searchText, focusRequest: searchFocusRequest) {
                            isSearchPresented = false
                        }
                        .frame(width: 220, height: 22)
                    } else {
                        Button(action: presentSearch) {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .help("Search (⌘F)")
                    }
                }
                .sharedBackgroundVisibility(isSearchPresented ? .hidden : .automatic)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleAssistant) {
                        Label("Ask Mail", systemImage: "apple.intelligence")
                    }
                    .tint(isAssistantActive ? .accentColor : nil)
                    .help(isAssistantActive ? "Close Ask Mail (Esc)" : "Ask Mail")
                    .accessibilityValue(isAssistantActive ? "On" : "Off")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        list.unreadOnly.toggle()
                    } label: {
                        Label("Filter Unread", systemImage: "line.3.horizontal.decrease")
                    }
                    .tint(list.unreadOnly ? .accentColor : nil)
                    .help("Filter Unread")
                }
            }
            .task(id: list.searchText) {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                await list.search()
            }
        }
        .focusedSceneValue(\.threadList, list)
        .focusedSceneValue(\.focusMailSearch, presentSearch)
        .onReceive(NotificationCenter.default.publisher(for: ComposeRequest.notification)) { notification in
            guard let request = notification.object as? ComposeRequest else { return }
            guard request.inlineOrigin == nil || request.inlineOrigin == composeOriginId else { return }
            openWindow(value: request)
        }
        .frame(minWidth: MailColumnLayout.windowMinimumWidth, minHeight: 420)
        .sheet(isPresented: $showingAddAccount) { AddAccountView(model: accounts) }
        .task {
            if let restored = MailboxSelection(storageValue: savedMailbox) { sidebar.selection = restored }
            isReady = true
            await sidebar.observe()
        }
        .onChange(of: sidebar.selection) { _, selection in
            savedMailbox = selection?.storageValue ?? ""
            isAssistantActive = false
        }
        .task { await sidebar.observeUnreadCounts() }
        .onChange(of: sidebar.unreadCounts[.view(.attention)], initial: true) { _, _ in updateBadge() }
        .onChange(of: badgeEnabled) { _, _ in updateBadge() }
        .task(id: isReady ? sidebar.selection?.storageValue : nil) {
            guard isReady else { return }
            let restored = restoredThreads ? [] : (try? JSONDecoder().decode(Set<ThreadSelection>.self, from: Foundation.Data(savedThreads.utf8))) ?? []
            restoredThreads = true
            await list.observe(sidebar.selection, restoring: restored)
        }
        .onChange(of: list.selections) { _, selection in
            guard !list.isLoading else { return }
            savedThreads = String(decoding: (try? JSONEncoder().encode(selection)) ?? Foundation.Data(), as: UTF8.self)
        }
    }

    private func openThreads(_ ids: Set<ThreadSelection>) {
        for row in list.rows where ids.contains(row.id) {
            openWindow(value: ThreadWindowRequest(selection: row.id, isActivity: list.isActivityView,
                                                  showsState: currentView != nil))
        }
    }

    private func toggleAssistant() {
        isAssistantActive.toggle()
    }

    private func openAssistantResult(_ result: AssistantResult, conversation: Bool) {
        let message = result.message
        let focus = message.activityCategory != nil || !conversation
        openWindow(value: ThreadWindowRequest(selection: ThreadSelection(accountId: message.accountId, threadId: message.threadId,
                                                                         messageId: focus ? message.id : nil),
                                              isActivity: message.activityCategory != nil, showsState: false))
    }

    private func presentSearch() {
        isSearchPresented = true
        searchFocusRequest += 1
    }

    private func updateBadge() {
        let count = badgeEnabled ? sidebar.unreadCounts[.view(.attention), default: 0] : 0
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}

private struct MailSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, dismiss: dismiss) }

    func makeNSView(context: Context) -> NSStackView {
        let field = NSSearchField(string: text)
        field.controlSize = .small
        field.placeholderString = "Search"
        field.setAccessibilityLabel("Search messages")
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.delegate = context.coordinator
        // Prevent AppKit from applying its full-height toolbar search styling.
        return NSStackView(views: [field])
    }

    func updateNSView(_ view: NSStackView, context: Context) {
        guard let field = view.views.first as? NSSearchField else { return }
        context.coordinator.text = $text
        context.coordinator.dismiss = dismiss
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var dismiss: () -> Void
        var focusRequest = 0

        init(text: Binding<String>, dismiss: @escaping () -> Void) {
            self.text = text
            self.dismiss = dismiss
        }

        @objc func search(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            text.wrappedValue = ""
            control.stringValue = ""
            control.window?.makeFirstResponder(nil)
            dismiss()
            return true
        }
    }
}

// Ideal is frozen at the restored value; the bridge ignores later ideal changes anyway. See docs/research/navigation-split-view-column-min-width.md.
private struct PersistedColumnWidth: ViewModifier {
    let column: MailColumnWidth
    @Binding var restored: CGFloat?
    @Binding var stored: Double

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.task(id: geometry.size.width) {
                        // Persist after layout so state changes cannot reenter the geometry action.
                        let width = geometry.size.width
                        guard !Task.isCancelled, width >= column.minimum, width <= column.maximum else { return }
                        if restored == nil { restored = MailColumnLayout.clamped(CGFloat(stored), to: column) }
                        if stored != Double(width) { stored = Double(width) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: column.minimum,
                                            ideal: restored ?? MailColumnLayout.clamped(CGFloat(stored), to: column),
                                            max: column.maximum)
    }
}
