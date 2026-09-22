import AppKit
import Domain
import SwiftUI

@MainActor
public struct ThreadDetailView: View {
    @Bindable var model: ThreadDetailModel
    @State private var showsPlaceholder = false

    public var body: some View {
        GeometryReader { geometry in
            conversationContent.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.isLoading) {
            showsPlaceholder = false
            guard model.isLoading else { return }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            showsPlaceholder = true
        }
    }

    private var conversationContent: some View {
        Group {
            if let error = model.errorMessage {
                ContentUnavailableView("Unable to Load Conversation", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.isLoading {
                if showsPlaceholder {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            MessageDetailView(
                                message: Message(id: "placeholder", accountId: "placeholder", threadId: "placeholder",
                                                 subject: "Conversation subject", sender: EmailAddress(address: "sender@example.com", name: "Sender Name"),
                                                 to: [EmailAddress(address: "you@example.com")], date: .now),
                                messageBody: MessageBody(id: "placeholder", plainText: "Your message content will appear here."),
                                attachments: [], model: model, isPlaceholder: true
                            )
                        }
                        .padding(.vertical, 8)
                    }
                    .redacted(reason: .placeholder)
                    .disabled(true)
                    .accessibilityHidden(true)
                } else {
                    Color.clear
                }
            } else if let message = model.newsletterMessage, let bodyId = message.bodyId,
                      let html = model.thread?.bodies[bodyId]?.html {
                NewsletterReaderView(message: message, html: html, model: model)
                    .id(message.id)
            } else if let thread = model.thread {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ConversationHeaderView(thread: thread)
                        if model.hasRemoteImages && !model.allowsRemoteImages {
                            HStack(spacing: 8) {
                                Label("Remote images are blocked.", systemImage: "hand.raised")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Load remote content") { model.loadImages() }
                                    .help("Load HTTPS images for this conversation. This may let senders know you opened it.")
                            }
                            .font(.callout)
                            .padding(12)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                        }
                        ForEach(Array(thread.messages.enumerated()), id: \.element.id) { index, message in
                            MessageDetailView(
                                message: message,
                                messageBody: message.bodyId.flatMap { thread.bodies[$0] },
                                attachments: message.attachmentIds.compactMap { thread.attachments[$0] },
                                model: model,
                                showsSeparator: index > 0
                            )
                        }
                    }
                    .padding(.bottom, 16)
                }
            } else {
                Text("No Message Selected")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationHeaderView: View {
    let thread: MailThread

    private var subject: String {
        thread.messages.last?.subject.nonempty ?? thread.messages.first?.subject.nonempty ?? "No Subject"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(subject)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if let state = thread.state {
                    ConversationStateTag(state: state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("^[\(thread.messages.count) message](inflect: true)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

private struct ConversationStateTag: View {
    let state: ConversationState

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .accessibilityLabel("Conversation state: \(title)")
    }

    private var tint: Color { state.tint }

    private var title: String {
        switch state {
        case .attention: "Attention"
        case .needsReply: "Needs Reply"
        case .waiting: "Waiting"
        case .later: "Later"
        case .done: "Done"
        }
    }
}

@MainActor
private struct MessageDetailView: View {
    let message: Message
    let messageBody: MessageBody?
    let attachments: [Attachment]
    @Bindable var model: ThreadDetailModel
    var showsSeparator = false
    var isPlaceholder = false
    @AppStorage("mail.hideQuotedText") private var hideQuotedText = true
    @State private var showsQuotedText = false
    @State private var showsSignature = false
    @State private var showsDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let avatarSize: CGFloat = 36
    private static let bodyMeasure: CGFloat = 720

    private var isExpanded: Bool { isPlaceholder || model.expandedMessageIds.contains(message.id) }
    private var isOutgoing: Bool { model.isOutgoing(message) }
    private var senderName: String { message.sender.name?.nonempty ?? message.sender.address }
    private var rendering: ConversationMessageRendering {
        let cleaned = BodyCleaner.clean(plainText: messageBody?.plainText, html: messageBody?.html)
        return ConversationMessageRendering(
            messageId: message.id,
            displayText: cleaned.displayText,
            firstLine: cleaned.displayText.components(separatedBy: .newlines).first ?? "",
            quotedText: cleaned.quotedText,
            signature: cleaned.signature
        )
    }

    private var recipientsLine: String {
        let names = message.to.map { $0.name?.nonempty ?? $0.address }
        return names.isEmpty ? "" : "To: " + names.joined(separator: ", ")
    }

    private var initials: String {
        let parts = senderName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.nonempty?.uppercased() ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSeparator {
                Divider().padding(.horizontal, 20)
            }
            VStack(alignment: .leading, spacing: 12) {
                header
                if isExpanded {
                    MessageContentView(
                        messageBody: messageBody,
                        attachments: attachments,
                        rendering: rendering,
                        allowsRemoteImages: model.allowsRemoteImages,
                        showsQuotedText: $showsQuotedText,
                        showsSignature: $showsSignature,
                        showsDetails: $showsDetails,
                        message: message
                    )
                    .frame(maxWidth: Self.bodyMeasure, alignment: .leading)
                    .padding(.leading, Self.avatarSize + 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: hideQuotedText, initial: true) { _, hide in
            showsQuotedText = !hide
        }
    }

    private var header: some View {
        Button(action: toggleExpansion) {
            HStack(alignment: .top, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(senderName)
                            .font(.headline)
                            .lineLimit(1)
                            .help(message.sender.address)
                        Spacer(minLength: 8)
                        Text(message.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .help(message.date.formatted(date: .complete, time: .shortened))
                    }
                    Text(isExpanded ? recipientsLine : (rendering.firstLine.nonempty ?? "No content"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(showsDetails ? "Hide Details" : "Show Details") { showsDetails.toggle() }
        }
        .help(isExpanded ? "Collapse message" : "Expand message")
        .accessibilityLabel("\(senderName), \(isExpanded ? "collapse" : "expand") message")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var avatar: some View {
        Text(initials)
            .font(.callout.weight(.medium))
            .foregroundStyle(isOutgoing ? Color.accentColor : .secondary)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .background(isOutgoing ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08), in: Circle())
            .accessibilityHidden(true)
    }

    private func toggleExpansion() {
        withAnimation(reduceMotion ? nil : .snappy) {
            if isExpanded { model.expandedMessageIds.remove(message.id) }
            else { model.expandedMessageIds.insert(message.id) }
        }
    }
}

@MainActor
private struct MessageContentView: View {
    let messageBody: MessageBody?
    let attachments: [Attachment]
    let rendering: ConversationMessageRendering
    let allowsRemoteImages: Bool
    @Binding var showsQuotedText: Bool
    @Binding var showsSignature: Bool
    @Binding var showsDetails: Bool
    let message: Message
    @State private var htmlHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let html = messageBody?.html?.nonempty {
                HTMLMessageView(html: html, allowsRemoteImages: allowsRemoteImages,
                                showsQuotedText: showsQuotedText, height: $htmlHeight)
                    .frame(height: htmlHeight)
                    .opacity(htmlHeight > 0 ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: htmlHeight)
                if HTMLMessageView.containsQuotedContent(html) {
                    Toggle("Show quoted text", isOn: $showsQuotedText)
                        .toggleStyle(.button)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            } else if !rendering.displayText.isEmpty {
                Text(rendering.displayText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let quotedText = rendering.quotedText {
                    DisclosureGroup("Show quoted text", isExpanded: $showsQuotedText) {
                        Text(quotedText)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let signature = rendering.signature {
                    DisclosureGroup("Show signature", isExpanded: $showsSignature) {
                        Text(signature)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                Text("This message has no content.")
                    .foregroundStyle(.secondary)
            }

            if showsDetails {
                MessageDetailsView(message: message, messageBody: messageBody, attachments: attachments)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .font(.body)
        .textSelection(.enabled)
    }
}

private struct MessageDetailsView: View {
    let message: Message
    let messageBody: MessageBody?
    let attachments: [Attachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            detail("From", message.sender.address)
            detail("To", message.to.map(\.address).joined(separator: ", "))
            if !message.cc.isEmpty { detail("Cc", message.cc.map(\.address).joined(separator: ", ")) }
            if !message.bcc.isEmpty { detail("Bcc", message.bcc.map(\.address).joined(separator: ", ")) }
            detail("Date", message.date.formatted(date: .complete, time: .complete))
            detail("Subject", message.subject.displaySubject)
            if let id = message.internetMessageId { detail("Message-ID", id) }
            if let id = message.inReplyTo { detail("In-Reply-To", id) }
            if !message.references.isEmpty { detail("References", message.references.joined(separator: " ")) }
            ForEach(message.automationHeaders.keys.sorted(), id: \.self) { name in
                detail(name, message.automationHeaders[name] ?? "")
            }
            if !attachments.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(attachments, id: \.id) { attachment in
                    Label("\(attachment.filename.nonempty ?? "Untitled attachment") · \(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))",
                          systemImage: "paperclip")
                }
            }
            if let plainText = messageBody?.plainText?.nonempty {
                source("Plain-text source", plainText)
            }
            if let html = messageBody?.html?.nonempty {
                source("HTML source", html)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(name):").fontWeight(.medium)
            Text(value).textSelection(.enabled)
        }
    }

    private func source(_ title: String, _ value: String) -> some View {
        DisclosureGroup(title) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
struct InlineReplyView: View {
    @Bindable var model: ThreadDetailModel
    var expandsToFill = false
    @FocusState private var isFocused: Bool

    private var latestSender: String? {
        guard let message = model.thread?.messages.last else { return nil }
        return message.sender.name?.nonempty ?? message.sender.address.nonempty
    }

    private var placeholder: String {
        latestSender.map { "\(model.inlineReplyMode.rawValue) to \($0)" } ?? "Write a reply"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                replyModeMenu
                Text(placeholder)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button { model.openInlineReplyInCompose() } label: {
                    Label("Open in Compose Window", systemImage: "arrow.up.forward.square")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(model.thread?.messages.last == nil)
                .help("Open in Compose Window")
            }
            .frame(height: 28)
            Divider()
            if let error = model.inlineReplyErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            TextEditor(text: $model.inlineReplyText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 112, maxHeight: expandsToFill ? .infinity : 112)
                .accessibilityLabel("Reply message")
                .accessibilityHint("Enter your reply. Press Command-Return to send.")
            HStack(spacing: 8) {
                emojiButton
                Spacer()
                sendButton
            }
            .frame(height: 28)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background)
    }

    private var emojiButton: some View {
        Button {
            isFocused = true
            NSApp.orderFrontCharacterPalette(nil)
        } label: {
            Image(systemName: "face.smiling")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help("Emoji & Symbols")
        .accessibilityLabel("Emoji and Symbols")
    }

    private var sendButton: some View {
        Button {
            Task { _ = await model.sendInlineReply() }
        } label: {
            Group {
                if model.isSendingInlineReply {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Sending reply")
                } else {
                    Label("Send", systemImage: "paperplane.fill")
                }
            }
            .frame(minWidth: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
        .disabled(!model.canSendInlineReply)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send (⌘↩)")
        .accessibilityLabel("Send reply")
        .accessibilityHint("Press Command-Return to send this reply.")
    }

    private var replyModeMenu: some View {
        Menu {
            Picker("Reply type", selection: $model.inlineReplyMode) {
                ForEach(InlineReplyMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: model.inlineReplyMode == .replyAll ? "arrowshape.turn.up.left.2" : "arrowshape.turn.up.left")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Reply type: \(model.inlineReplyMode.rawValue)")
        .accessibilityLabel("Reply type")
        .accessibilityValue(model.inlineReplyMode.rawValue)
    }
}

extension String {
    var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
    var displaySubject: String { nonempty ?? String(localized: "(No Subject)") }
    var collapsingWhitespace: String { split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
