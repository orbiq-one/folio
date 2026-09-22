import Domain

public struct ConversationMessageRendering: Equatable, Sendable {
    public let messageId: String
    public let displayText: String
    public let firstLine: String
    public let quotedText: String?
    public let signature: String?
}

public struct ConversationRenderingModel: Equatable, Sendable {
    public let expandedMessageIds: Set<String>
    private let messages: [String: ConversationMessageRendering]

    public init(thread: MailThread) {
        expandedMessageIds = Set(thread.messages.max(by: { ($0.date, $0.id) < ($1.date, $1.id) }).map { [$0.id] } ?? [])
        messages = Dictionary(uniqueKeysWithValues: thread.messages.map { message in
            let body = message.bodyId.flatMap { thread.bodies[$0] }
            let cleaned = BodyCleaner.clean(plainText: body?.plainText, html: body?.html)
            let firstLine = cleaned.displayText.components(separatedBy: .newlines).first ?? ""
            return (message.id, ConversationMessageRendering(
                messageId: message.id,
                displayText: cleaned.displayText,
                firstLine: firstLine,
                quotedText: cleaned.quotedText,
                signature: cleaned.signature
            ))
        })
    }

    public func message(id: String) -> ConversationMessageRendering? {
        messages[id]
    }
}
