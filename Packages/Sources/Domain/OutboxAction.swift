import Foundation

public enum OutboxAction: Codable, Equatable, Sendable {
    case changeFlags(messageId: String, flags: MessageFlags, enabled: Bool)
    case addMailbox(messageId: String, mailboxId: String)
    case removeMailbox(messageId: String, mailboxId: String)
    case move(messageId: String, fromMailboxId: String, toMailboxId: String)
    case send(message: Message, body: MessageBody, attachments: [Attachment])
    case saveDraft(message: Message, body: MessageBody, attachments: [Attachment])
    case deleteDraft(messageId: String)
}
