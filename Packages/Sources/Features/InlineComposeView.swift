import AppKit
import SwiftUI

@MainActor
struct InlineComposeView: View {
    @Bindable var model: ComposeModel
    let dismiss: () -> Void
    @State private var isShowingRecipients = false

    init(model: ComposeModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    private var title: String {
        switch model.request.kind {
        case .newMessage: "New Message"
        case .reply: "Reply"
        case .replyAll: "Reply All"
        case .forward: "Forward"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if model.request.kind == .replyAll {
                    Text("to all recipients").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        guard let request = await model.openInWindow() else { return }
                        ComposeRequest.open(request)
                        dismiss()
                    }
                } label: {
                    Label("Open in Compose Window", systemImage: "arrow.up.forward.square")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy || !model.isLoaded || model.isQueued)
                .help("Open in Compose Window")
                Button("Discard", role: .destructive) {
                    Task { if await model.discard() { dismiss() } }
                }
                .buttonStyle(.borderless)
                .disabled(model.isBusy || !model.isLoaded)
            }
            HStack(spacing: 8) {
                Text("To").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                TextField("Recipients", text: $model.to)
                    .textFieldStyle(.plain)
                Button(isShowingRecipients ? "Hide Cc/Bcc" : "Cc/Bcc") { isShowingRecipients.toggle() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            if isShowingRecipients {
                HStack(spacing: 8) {
                    Text("Cc").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    TextField("Cc", text: $model.cc).textFieldStyle(.plain)
                }
                HStack(spacing: 8) {
                    Text("Bcc").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                    TextField("Bcc", text: $model.bcc).textFieldStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Text("Subject").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                TextField("Subject", text: $model.subject).textFieldStyle(.plain)
            }
            Divider()
            RichBodyEditor(text: $model.text, inset: NSSize(width: 0, height: 8))
                .frame(minHeight: 80, maxHeight: .infinity)
                .accessibilityLabel("Message")
            HStack {
                Button("Save Draft") { Task { _ = await model.save() } }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy || !model.isLoaded)
                if model.isBusy { ProgressView().controlSize(.small) }
                else if let saved = model.savedAt { Text("Saved \(saved, style: .time)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button {
                    Task { _ = await model.send() }
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!model.canSend)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            if !model.attachments.isEmpty {
                Label("Remove attachments in the compose window before sending.", systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.background)
        .modifier(ComposeLifecycle(model: model, dismiss: dismiss))
    }
}

