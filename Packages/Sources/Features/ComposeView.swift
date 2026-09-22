import AppKit
import SwiftUI

private struct ComposeFocusedKey: FocusedValueKey { typealias Value = ComposeModel }
public extension FocusedValues {
    var composeModel: ComposeModel? {
        get { self[ComposeFocusedKey.self] }
        set { self[ComposeFocusedKey.self] = newValue }
    }
}

public struct ComposeView: View {
    @Bindable private var model: ComposeModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: RichFormat?
    @State private var showingLink = false
    @State private var link = "https://"
    @State private var showsFormatting = true
    @State private var showsBcc = false
    @State private var fontFamily = "Helvetica"
    @State private var fontSize: CGFloat = 13
    @FocusState private var recipientFocused: Bool

    public init(model: ComposeModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                headerRow("To:") {
                    RecipientField("To", text: $model.to).labelsHidden().focused($recipientFocused)
                    Menu {
                        Toggle("Show Bcc", isOn: $showsBcc)
                    } label: { Image(systemName: "plus.circle.fill").foregroundStyle(.tertiary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Recipient Fields").accessibilityLabel("Recipient Fields")
                }
                headerRow("Cc:") { RecipientField("Cc", text: $model.cc).labelsHidden() }
                if showsBcc || !model.bcc.isEmpty {
                    headerRow("Bcc:") { RecipientField("Bcc", text: $model.bcc).labelsHidden() }
                }
                headerRow("Reply To:") { RecipientField("Reply To", text: $model.replyTo).labelsHidden() }
                headerRow("Subject:") {
                    TextField("Subject", text: $model.subject).textFieldStyle(.plain).labelsHidden()
                }
                headerRow("From:") {
                    Picker("From", selection: $model.accountId) {
                        ForEach(model.accounts, id: \.id) { account in
                            Text(account.email.name.map { "\($0) <\(account.email.address)>" } ?? account.email.address).tag(account.id)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).buttonStyle(.borderless).fixedSize()
                    .disabled(model.savedAt != nil || model.request.draftId != nil)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 20)
            if showsFormatting { formattingBar }
            RichBodyEditor(text: $model.text, format: format).frame(minHeight: 280)
            if !model.attachments.isEmpty {
                VStack(alignment: .leading) {
                    Text("Attachment contents are unavailable. Remove them to send this message.").font(.callout)
                    ForEach(model.attachments, id: \.id) { attachment in
                        HStack {
                            Label(attachment.filename, systemImage: "paperclip")
                            Button("Remove") { model.attachments.removeAll { $0.id == attachment.id }; model.changed() }
                        }
                    }
                }.padding()
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .disabled(model.isQueued)
        .frame(minWidth: 700, minHeight: 540)
        .navigationTitle(model.subject.isEmpty ? "New Message" : model.subject)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Button { showsFormatting.toggle() } label: { Text("Aa").font(.system(size: 15)) }
                    .help("Show or Hide Formatting").accessibilityLabel("Show or Hide Formatting")
                Button { format = RichFormat(action: .emoji) } label: { Label("Emoji & Symbols", systemImage: "face.smiling") }
                Button { showingLink = true } label: { Label("Insert Link", systemImage: "link") }
                Button { Task { _ = await model.save() } } label: { Label("Save Draft", systemImage: "square.and.arrow.down") }
                    .disabled(model.isBusy || !model.isLoaded).help("Save Draft (⌘S)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { _ = await model.send() } } label: { Label("Send", systemImage: "arrow.up") }
                    .disabled(!model.canSend).help("Send (⇧⌘D)")
            }
        }
        .background(ComposeCloseGuard(model: model))
        .modifier(ComposeLifecycle(model: model, dismiss: { dismiss() }))
        .onChange(of: model.isLoaded) { _, loaded in
            if loaded, model.request.kind == .newMessage, model.request.draftId == nil { recipientFocused = true }
        }
        .sheet(isPresented: $showingLink) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Insert Link").font(.headline)
                TextField("URL", text: $link)
                HStack {
                    Spacer()
                    Button("Cancel") { showingLink = false }.keyboardShortcut(.cancelAction)
                    Button("Insert") { format = RichFormat(action: .link(link)); showingLink = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!["https", "http", "mailto"].contains(URL(string: link)?.scheme?.lowercased() ?? ""))
                }
            }.padding(20).frame(width: 360)
        }
    }

    private func headerRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                content()
            }
            .frame(minHeight: 37)
            Divider()
        }
        .font(.system(size: 13))
    }

    private var formattingBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Picker("Font", selection: $fontFamily) {
                    ForEach(["Helvetica", "Avenir Next", "Georgia", "Times New Roman", "Menlo"], id: \.self) { Text($0) }
                }
                .frame(width: 150)
                .onChange(of: fontFamily) { _, family in format = RichFormat(action: .fontFamily(family)) }
                Picker("Font Size", selection: $fontSize) {
                    ForEach([10, 11, 12, 13, 14, 16, 18, 24, 32], id: \.self) { Text("\($0)").tag(CGFloat($0)) }
                }
                .frame(width: 65)
                .onChange(of: fontSize) { _, size in format = RichFormat(action: .fontSize(size)) }
                formatButton("More Fonts", symbol: "textformat", action: .fontPanel)
                Divider().frame(height: 16)
                HStack(spacing: 2) {
                    formatButton("Bold", symbol: "bold", action: .bold)
                    formatButton("Italic", symbol: "italic", action: .italic)
                    formatButton("Underline", symbol: "underline", action: .underline)
                    formatButton("Strikethrough", symbol: "strikethrough", action: .strikethrough)
                }
                Divider().frame(height: 16)
                HStack(spacing: 2) {
                    formatButton("Align Left", symbol: "text.alignleft", action: .alignLeft)
                    formatButton("Center", symbol: "text.aligncenter", action: .alignCenter)
                    formatButton("Align Right", symbol: "text.alignright", action: .alignRight)
                }
                formatButton("Bulleted List", symbol: "list.bullet", action: .list)
                Spacer(minLength: 8)
                if model.isBusy { ProgressView().controlSize(.mini) }
                else if let saved = model.savedAt { Text("Saved \(saved, style: .time)").font(.caption).foregroundStyle(.secondary) }
            }
            .labelsHidden().controlSize(.small)
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private func formatButton(_ title: String, symbol: String, action: RichFormat.Action) -> some View {
        Button { format = RichFormat(action: action) } label: {
            Image(systemName: symbol).frame(width: 20, height: 18)
        }
        .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}

struct ComposeLifecycle: ViewModifier {
    @Bindable var model: ComposeModel
    let dismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .disabled(model.isQueued)
            .focusedSceneValue(\.composeModel, model)
            .task(id: model.request.id) { await model.load() }
            .onChange(of: model.isQueued) { if model.isQueued { dismiss() } }
            .onChange(of: model.to) { model.changed() }
            .onChange(of: model.cc) { model.changed() }
            .onChange(of: model.bcc) { model.changed() }
            .onChange(of: model.replyTo) { model.changed() }
            .onChange(of: model.subject) { model.changed() }
            .onChange(of: model.accountId) { model.changed() }
            .onChange(of: model.text) { model.changed() }
    }
}

private struct RichFormat: Equatable {
    enum Action: Equatable { case bold, italic, underline, strikethrough, alignLeft, alignCenter, alignRight, fontPanel, emoji, list, link(String), fontFamily(String), fontSize(CGFloat) }
    let id = UUID()
    let action: Action
}

struct RichBodyEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    fileprivate var format: RichFormat?
    var inset = NSSize(width: 20, height: 14)

    init(text: Binding<NSAttributedString>, inset: NSSize = NSSize(width: 20, height: 14)) {
        _text = text
        self.inset = inset
    }

    fileprivate init(text: Binding<NSAttributedString>, format: RichFormat?) {
        _text = text
        self.format = format
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isRichText = true; view.allowsUndo = true; view.isAutomaticLinkDetectionEnabled = true
        view.textContainerInset = inset
        view.font = NSFont(name: "Helvetica", size: 13)
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isContinuousSpellCheckingEnabled = true
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(text)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if !view.attributedString().isEqual(to: text) {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(text)
            view.setSelectedRange(NSRange(location: min(selection.location, text.length), length: 0))
        }
        if let format, context.coordinator.applied != format.id {
            context.coordinator.applied = format.id
            view.window?.makeFirstResponder(view)
            let range = view.selectedRange()
            switch format.action {
            case .bold, .italic:
                let trait: NSFontTraitMask = format.action == .bold ? .boldFontMask : .italicFontMask
                let font = (range.length > 0 ? view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) : view.typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: NSFont.systemFontSize)
                let converted = NSFontManager.shared.traits(of: font).contains(trait) ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait)
                if range.length == 0 { view.typingAttributes[.font] = converted }
                else if view.shouldChangeText(in: range, replacementString: nil) { view.textStorage?.addAttribute(.font, value: converted, range: range); view.didChangeText() }
            case .underline:
                view.underline(nil)
            case .strikethrough:
                let current = (range.length > 0 ? view.textStorage?.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) : view.typingAttributes[.strikethroughStyle]) as? Int ?? 0
                let value = current == 0 ? NSUnderlineStyle.single.rawValue : 0
                if range.length == 0 { view.typingAttributes[.strikethroughStyle] = value }
                else if view.shouldChangeText(in: range, replacementString: nil) {
                    view.textStorage?.addAttribute(.strikethroughStyle, value: value, range: range); view.didChangeText()
                }
            case .alignLeft: view.alignLeft(nil)
            case .alignCenter: view.alignCenter(nil)
            case .alignRight: view.alignRight(nil)
            case .fontPanel: NSFontManager.shared.orderFrontFontPanel(nil)
            case .emoji: NSApp.orderFrontCharacterPalette(nil)
            case .fontFamily, .fontSize:
                let font = (range.length > 0 ? view.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) : view.typingAttributes[.font]) as? NSFont ?? .systemFont(ofSize: 13)
                let converted: NSFont
                if case .fontFamily(let family) = format.action { converted = NSFontManager.shared.convert(font, toFamily: family) }
                else if case .fontSize(let size) = format.action { converted = NSFontManager.shared.convert(font, toSize: size) }
                else { converted = font }
                if range.length == 0 { view.typingAttributes[.font] = converted }
                else if view.shouldChangeText(in: range, replacementString: nil) {
                    view.textStorage?.addAttribute(.font, value: converted, range: range); view.didChangeText()
                }
            case .link(let url):
                if range.length > 0, view.shouldChangeText(in: range, replacementString: nil) { view.textStorage?.addAttribute(.link, value: url, range: range); view.didChangeText() }
                else { view.insertText(NSAttributedString(string: url, attributes: [.link: url]), replacementRange: range) }
            case .list:
                let paragraph = (view.string as NSString).paragraphRange(for: range)
                let style = NSMutableParagraphStyle(); style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
                if paragraph.length > 0, view.shouldChangeText(in: paragraph, replacementString: nil) { view.textStorage?.addAttribute(.paragraphStyle, value: style, range: paragraph); view.didChangeText() }
                else { view.typingAttributes[.paragraphStyle] = style; view.insertText("• ", replacementRange: range) }
            }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichBodyEditor
        var applied: UUID?
        init(_ parent: RichBodyEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = NSAttributedString(attributedString: view.attributedString())
        }
    }
}

struct ComposeCloseGuard: NSViewRepresentable {
    let model: ComposeModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WindowHook {
        let view = WindowHook()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: WindowHook, context: Context) {
        if context.coordinator.model !== model {
            context.coordinator.model = model
            context.coordinator.allowed = false
        }
    }
    static func dismantleNSView(_ view: WindowHook, coordinator: Coordinator) {
        coordinator.detach()
    }
    final class WindowHook: NSView {
        var attach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var model: ComposeModel
        weak var window: NSWindow?
        weak var previous: (any NSWindowDelegate)?
        var allowed = false
        var asking = false
        init(model: ComposeModel) { self.model = model }
        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            detach()
            guard let window else { return }
            self.window = window
            previous = window.delegate; window.delegate = self
        }
        func detach() {
            if let window, window.delegate === self { window.delegate = previous }
            window = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !allowed, model.hasUnsavedChanges else { return previous?.windowShouldClose?(sender) ?? true }
            guard !asking else { return false }
            asking = true
            let alert = NSAlert()
            alert.messageText = "Save this draft before closing?"
            alert.informativeText = "Your unsaved changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
            let model = model
            alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
                Task { @MainActor in
                    guard let self, let sender else { return }
                    self.asking = false
                    let close: Bool
                    switch response {
                    case .alertFirstButtonReturn: close = await model.save() && !model.hasUnsavedChanges
                    case .alertSecondButtonReturn: close = await model.discard()
                    default: close = false
                    }
                    if close { self.allowed = true; sender.performClose(nil) }
                }
            }
            return false
        }
        func windowWillClose(_ notification: Notification) { previous?.windowWillClose?(notification) }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previous?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector)
        }
    }
}
