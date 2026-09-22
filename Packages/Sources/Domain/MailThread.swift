import Foundation

public struct MailThread: Equatable, Sendable {
    public var id: String
    public var accountId: String
    public var messages: [Message]
    public var snippet: String
    public var bodies: [String: MessageBody]
    public var attachments: [String: Attachment]
    /// Set when the thread was fetched through a conversation view; nil for mailbox listings.
    public var state: ConversationState?

    public init(id: String, accountId: String, messages: [Message], snippet: String = "",
                bodies: [String: MessageBody] = [:], attachments: [String: Attachment] = [:], state: ConversationState? = nil) {
        self.id = id
        self.accountId = accountId
        self.messages = messages
        self.snippet = snippet
        self.bodies = bodies
        self.attachments = attachments
        self.state = state
    }
}
