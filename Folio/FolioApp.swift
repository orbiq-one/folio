import Domain
import Features
import SwiftUI

@main
struct FolioApp: App {
    @State private var application = ApplicationModel()
    @State private var undoSend = UndoSendModel()

    var body: some Scene {
        WindowGroup("Folio") { ComposeMailRoot(application: application, undoSend: undoSend) }
            .defaultSize(width: 900, height: 680)
            .windowToolbarStyle(.unified)
            .commands { MailCommands(application: application) }
        WindowGroup("New Message", for: ComposeRequest.self) { $request in
            if let request { ComposeWindow(request: request, application: application, undoSend: undoSend) }
        }
        .defaultSize(width: 1000, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        .windowStyle(.hiddenTitleBar)
        WindowGroup("Message", for: ThreadWindowRequest.self) { $request in
            if let request, let repository = application.repository {
                ThreadWindowView(request: request, repository: repository, undoSend: undoSend)
            }
        }
        .defaultSize(width: 760, height: 720)
        .windowToolbarStyle(.unifiedCompact)
        Settings {
            if let repository = application.repository, let accounts = application.accounts {
                TabView {
                    GeneralSettingsView()
                        .tabItem { Label("General", systemImage: "gear") }
                    AccountsSettingsView(repository: repository, model: accounts)
                        .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                }
            } else { Text(application.errorMessage ?? "Unable to open the local database.").padding() }
        }
    }
}

private struct MailCommands: Commands {
    let application: ApplicationModel
    @FocusedValue(\.addAccount) private var addAccount
    @FocusedValue(\.threadList) private var threadList
    @FocusedValue(\.threadDetail) private var threadDetail
    @FocusedValue(\.composeModel) private var composeModel
    @FocusedValue(\.focusMailSearch) private var focusMailSearch
    @AppStorage(ListTextSize.storageKey) private var listTextSize = ListTextSize.standard

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") { focusMailSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusMailSearch == nil)
        }
        CommandGroup(after: .newItem) {
            Button("New Message") { threadList?.composeMessage(.newMessage) }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(threadList == nil)
            Button("Add Account…") { addAccount?() }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(addAccount == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Draft") { Task { _ = await composeModel?.save() } }
                .keyboardShortcut("s").disabled(composeModel == nil || composeModel?.isBusy == true)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await application.accounts?.refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(application.accounts?.status.isEmpty != false || application.accounts?.isSyncing == true)
        }
        CommandGroup(after: .toolbar) {
            Button("Make Text Bigger") { listTextSize = ListTextSize.step(listTextSize, by: 1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(listTextSize >= ListTextSize.range.upperBound)
            Button("Make Text Smaller") { listTextSize = ListTextSize.step(listTextSize, by: -1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(listTextSize <= ListTextSize.range.lowerBound)
            Button("Actual Size") { listTextSize = ListTextSize.standard }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(listTextSize == ListTextSize.standard)
            Divider()
        }
        CommandGroup(after: .toolbar) {
            Button("Next Message") { threadList?.selectNext(1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command]).disabled(threadList?.rows.isEmpty != false)
            Button("Previous Message") { threadList?.selectNext(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command]).disabled(threadList?.rows.isEmpty != false)
        }
        CommandMenu("Message") {
            Button("Send") { Task { _ = await composeModel?.send() } }
                .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(composeModel?.canSend != true)
            Divider()
            Button("Done") { Task { await threadList?.perform(.done) } }
                .keyboardShortcut("e", modifiers: [.control, .command]).disabled(threadList?.canChangeConversationState != true)
            Menu("Later") {
                ForEach(LaterPreset.allCases, id: \.self) { preset in
                    Button(preset.title) { Task { await threadList?.perform(.later(until: preset.date())) } }
                }
            }.disabled(threadList?.canChangeConversationState != true)
            Button("Later Tomorrow") { Task { await threadList?.perform(.later(until: LaterPreset.tomorrow.date())) } }
                .keyboardShortcut("l", modifiers: [.control, .command]).disabled(threadList?.canChangeConversationState != true)
            Button("Needs Reply") { Task { await threadList?.perform(.needsReply) } }
                .keyboardShortcut("r", modifiers: [.control, .command]).disabled(threadList?.canChangeConversationState != true)
            Button("Move to Attention") { Task { await threadList?.perform(.reopen) } }
                .disabled(threadList?.canChangeConversationState != true)
            Divider()
            Button("Treat as Person") { Task { await threadList?.setSenderRule(.human) } }
                .keyboardShortcut("p", modifiers: [.control, .command])
                .disabled(threadList?.canSetSenderRule(.human) != true)
            Button("Treat as Activity") { Task { await threadList?.setSenderRule(.activity) } }
                .keyboardShortcut("a", modifiers: [.control, .option, .command])
                .disabled(threadList?.canSetSenderRule(.activity) != true)
            Button("Reset Sender Rule") { Task { await threadList?.resetSenderRule() } }
                .keyboardShortcut("p", modifiers: [.control, .option, .command])
                .disabled(threadList?.selectionHasSenderRule != true)
            Button("Expand or Collapse Sender") { threadList?.toggleSelectedSenderExpansion() }
                .keyboardShortcut("s", modifiers: [.control, .option, .command])
                .disabled(threadList?.canToggleSenderExpansion != true)
            Button("Unsubscribe") { threadDetail?.unsubscribe() }
                .keyboardShortcut("u", modifiers: [.control, .option, .command])
                .disabled(threadDetail?.unsubscribeURL == nil)
            Button("Load remote content") { threadDetail?.loadImages() }
                .keyboardShortcut("i", modifiers: [.control, .option, .command])
                .disabled(threadDetail?.hasRemoteImages != true || threadDetail?.allowsRemoteImages == true)
            Divider()
            Button("Archive") { Task { await threadList?.perform(.archive) } }
                .keyboardShortcut("a", modifiers: [.control, .command]).disabled(threadList?.hasSelection != true)
            Button("Move to Trash") { Task { await threadList?.perform(.trash) } }
                .keyboardShortcut(.delete, modifiers: .command).disabled(threadList?.hasSelection != true)
            Button(threadList?.isSelectionStarred == true ? "Unflag" : "Flag") {
                Task { await threadList?.perform(.toggleStar) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift]).disabled(threadList?.hasSelection != true)
            Button(threadList?.isSelectionUnread == true ? "Mark as Read" : "Mark as Unread") {
                Task { await threadList?.perform(threadList?.isSelectionUnread == true ? .markRead : .markUnread) }
            }
            .keyboardShortcut("u", modifiers: [.shift, .command]).disabled(threadList?.hasSelection != true)
            Button("Mark as Read") { Task { await threadList?.perform(.markRead) } }
                .disabled(threadList?.hasSelection != true)
            Button("Mark as Unread") { Task { await threadList?.perform(.markUnread) } }
                .disabled(threadList?.hasSelection != true)
            Divider()
            Button("Edit Draft") { threadList?.composeMessage(.editDraft) }
                .keyboardShortcut("o").disabled(threadList?.selectedLocalDraft == nil)
            Button("Reply") { threadList?.composeMessage(.reply) }
                .keyboardShortcut("r").disabled(threadList?.selection == nil)
            Button("Reply All") { threadList?.composeMessage(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(threadList?.selection == nil)
            Button("Forward") { threadList?.composeMessage(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(threadList?.selection == nil)
        }
        SidebarCommands()
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("mail.badgeEnabled") private var badgeEnabled = true
    @AppStorage("mail.hideQuotedText") private var hideQuotedText = true
    @AppStorage(ListTextSize.storageKey) private var listTextSize = ListTextSize.standard

    var body: some View {
        Form {
            Toggle("Show Attention count on the Dock icon", isOn: $badgeEnabled)
            Section("Message List") {
                Slider(value: $listTextSize, in: ListTextSize.range, step: 1) {
                    Text("Text Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller").accessibilityLabel("Smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger").accessibilityLabel("Larger")
                }
                .accessibilityValue("\(Int(listTextSize)) points")
                Text("Rows, avatars, and icons scale with the text. Use ⌘+ and ⌘− to adjust from the list, ⌘0 to reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Reading") {
                Toggle("Hide quoted reply history", isOn: $hideQuotedText)
                Text("Collapse previous messages quoted in emails. You can reveal them in each message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

private struct ComposeMailRoot: View {
    let application: ApplicationModel
    let undoSend: UndoSendModel
    var body: some View {
        ContentView(application: application)
            .overlay(alignment: .top) { UndoSendBanner(model: undoSend) }
            .task { undoSend.refresh = { await application.accounts?.refresh() } }
    }
}

private struct ComposeWindow: View {
    let request: ComposeRequest
    let application: ApplicationModel
    let undoSend: UndoSendModel
    @State private var model: ComposeModel?
    var body: some View {
        Group {
            if let model { ComposeView(model: model) }
            else { ProgressView("Opening Draft…").padding() }
        }
        .task {
            guard model == nil, let repository = application.repository else { return }
            model = ComposeModel(request: request, repository: repository, undo: undoSend)
        }
    }
}
