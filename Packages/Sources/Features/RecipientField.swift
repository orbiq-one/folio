import Domain
import SwiftUI

public struct RecipientField: View {
    private let title: String
    @Binding private var text: String
    public init(_ title: String, text: Binding<String>) { self.title = title; _text = text }
    private var parts: [String] { text.components(separatedBy: ",") }
    private var entry: Binding<String> {
        Binding(get: { parts.last ?? "" }, set: { value in
            text = (parts.dropLast() + [value.replacingOccurrences(of: ";", with: ",")]).joined(separator: ",")
        })
    }
    public var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                if parts.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(Array(parts.dropLast().enumerated()), id: \.offset) { index, value in
                                let recipient = ComposeAddressing.parse(value).first ?? EmailAddress(address: value)
                                HStack(spacing: 4) {
                                    Text(recipient.name ?? recipient.address).lineLimit(1)
                                    Button {
                                        var values = parts; values.remove(at: index); text = values.joined(separator: ",")
                                    } label: { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.plain).accessibilityLabel("Remove \(recipient.address)")
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(ComposeAddressing.valid(recipient) ? Color.accentColor.opacity(0.12) : Color.red.opacity(0.12), in: Capsule())
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
                TextField(title, text: entry, prompt: Text("")).textFieldStyle(.plain).autocorrectionDisabled()
                    .accessibilityLabel(title)
                    .onSubmit { if !entry.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty { text += "," } }
            }
        }
    }
}
