import Domain
import SwiftUI

@MainActor
struct AssistantView: View {
    @Bindable var model: AssistantModel
    /// `true` opens the whole conversation; `false` opens it focused on that email.
    let open: (AssistantResult, _ conversation: Bool) -> Void
    let close: () -> Void
    @FocusState private var isFieldFocused: Bool

    private let suggestions = [
        "Who asked me to go on a cruise next year?",
        "When is my train to Hamburg?",
        "What did Jordan say about the Atlas timeline?",
    ]

    var body: some View {
        Group {
            if model.answer == nil && model.errorMessage == nil {
                field
                    .overlay(alignment: .bottom) {
                        // Hangs below the field so the field itself stays vertically centered.
                        suggestionList
                            .opacity(model.isAsking ? 0 : 1)
                            .alignmentGuide(.bottom) { $0[.top] - 20 }
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        field
                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        } else if let answer = model.answer {
                            results(answer)
                        }
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { isFieldFocused = true }
        .onExitCommand(perform: close)
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 22))
                .foregroundStyle(IntelligenceGradient.gradient)
                .accessibilityHidden(true)
            TextField("Ask anything about your mail", text: $model.question)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($isFieldFocused)
                .onSubmit { model.ask() }
            if model.isAsking {
                ProgressView().controlSize(.small)
            } else if !model.question.isEmpty {
                Button { model.reset(); isFieldFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.usesModel ? "Try asking" : "Apple Intelligence is off, so questions run as keyword searches.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    model.question = suggestion
                    model.ask()
                } label: {
                    Label(suggestion, systemImage: "text.magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func results(_ answer: AssistantAnswer) -> some View {
        if let summary = answer.summary {
            answerCard(summary: summary, answer: answer)
        }
        if answer.results.isEmpty {
            if answer.best == nil {
                Text("No emails match “\(model.askedQuestion)”.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(answer.best == nil ? "Found Emails" : "Other Emails")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(answer.results) { result in
                        Button { open(result, false) } label: { resultRow(result) }
                            .buttonStyle(.plain)
                        if result.id != answer.results.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .padding(.vertical, 4)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
            }
        }
    }

    private func answerCard(summary: String, answer: AssistantAnswer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary)
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
            if let status = answer.replyStatus {
                replyLabel(status)
            }
            if let best = answer.best {
                let message = best.message
                let sender = message.sender.name ?? message.sender.address
                HStack(spacing: 10) {
                    AvatarView(name: sender, address: message.sender.address, size: 24)
                    Text(message.subject.displaySubject)
                        .lineLimit(1)
                    Spacer()
                    Text(ThreadDateFormat.compact(for: message.date)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                HStack(spacing: 8) {
                    Button("Open Email") { open(best, false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    if answer.conversationLength > 1 {
                        Button("Open Conversation (\(answer.conversationLength))") { open(best, true) }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private func replyLabel(_ status: ReplyStatus) -> some View {
        switch status {
        case .notReplied:
            Label("You haven’t replied", systemImage: "arrowshape.turn.up.left")
                .foregroundStyle(.orange)
        case .replied(let date):
            Label("You replied \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func resultRow(_ result: AssistantResult) -> some View {
        let message = result.message
        let sender = message.sender.name ?? message.sender.address
        return HStack(alignment: .top, spacing: 12) {
            AvatarView(name: sender, address: message.sender.address, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(sender).font(.headline).lineLimit(1)
                    Spacer()
                    Text(ThreadDateFormat.compact(for: message.date)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(message.subject.displaySubject).lineLimit(1)
                if !result.excerpt.isEmpty {
                    Text(result.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the conversation in a new window")
    }
}

enum IntelligenceGradient {
    static let colors: [Color] = [Color(red: 0.74, green: 0.51, blue: 0.95), Color(red: 0.96, green: 0.73, blue: 0.92),
                                  Color(red: 0.55, green: 0.62, blue: 1.0), Color(red: 1.0, green: 0.40, blue: 0.47),
                                  Color(red: 1.0, green: 0.73, blue: 0.44), Color(red: 0.74, green: 0.51, blue: 0.95)]

    static let gradient = AngularGradient(colors: colors, center: .center)
}
