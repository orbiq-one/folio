import Domain
import SwiftUI

struct NewsletterReaderView: View {
    let message: Message
    let html: String
    @Bindable var model: ThreadDetailModel
    @State private var htmlHeight: CGFloat = 0
    @AppStorage("mail.hideQuotedText") private var hideQuotedText = true
    @State private var showsQuotedText = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.sender.name ?? message.sender.address)
                        .font(.headline)
                        .help(message.sender.address)
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject).font(.body).textSelection(.enabled)
                HStack {
                    Button("Unsubscribe") { model.unsubscribe() }
                        .disabled(model.unsubscribeURL == nil)
                        .help(model.unsubscribeURL?.absoluteString ?? "No unsubscribe link provided")
                    Spacer()
                    if model.hasRemoteImages && !model.allowsRemoteImages {
                        Button("Load remote content") { model.loadImages() }
                            .help("Load HTTPS images. This may let senders know you opened this newsletter.")
                    }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(.bar)
            Divider()
            ScrollView {
                VStack(alignment: .leading) {
                    HTMLMessageView(html: html, allowsRemoteImages: model.allowsRemoteImages,
                                    showsQuotedText: showsQuotedText, height: $htmlHeight)
                        .frame(height: htmlHeight)
                        .frame(maxWidth: .infinity)
                    if HTMLMessageView.containsQuotedContent(html) {
                        Toggle("Show quoted text", isOn: $showsQuotedText)
                            .toggleStyle(.button)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .padding(12)
                    }
                }
            }
        }
        .background(.background)
        .onChange(of: hideQuotedText, initial: true) { _, hide in
            showsQuotedText = !hide
        }
        .contextMenu {
            Button("Unsubscribe") { model.unsubscribe() }
                .disabled(model.unsubscribeURL == nil)
            Button("Load remote content") { model.loadImages() }
                .disabled(!model.hasRemoteImages || model.allowsRemoteImages)
            Divider()
            Button("Forward") { model.forward(message) }
        }
    }
}
