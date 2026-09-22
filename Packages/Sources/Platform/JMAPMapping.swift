import Domain
import Foundation

struct MappedJMAPMessage: Sendable {
    let message: Message
    let body: MessageBody
    let attachments: [Attachment]
}

enum JMAPMapping {
    static func mailbox(_ value: JMAPMailbox, accountId: String) -> Mailbox {
        let kind: MailboxKind = switch value.role {
        case "inbox": .inbox
        case "sent": .sent
        case "drafts": .drafts
        case "trash": .trash
        case "junk": .spam
        case "archive": .archive
        case "flagged": .starred
        default: .folder
        }
        return Mailbox(id: value.id, accountId: accountId, kind: kind, name: value.name,
                       parentId: value.parentId, isSystem: kind != .folder)
    }

    static func message(_ value: JMAPEmail, accountId: String) throws -> MappedJMAPMessage {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: value.receivedAt)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: value.receivedAt) else { throw JMAPError.invalidResponse }
        func addresses(_ values: [JMAPEmail.Address]?) -> [EmailAddress] {
            (values ?? []).map { EmailAddress(address: $0.email, name: $0.name) }
        }
        func bodyText(_ parts: [JMAPEmail.Part]?) -> String? {
            let values = (parts ?? []).compactMap { part in part.partId.flatMap { value.bodyValues?[$0]?.value } }
            return values.isEmpty ? nil : values.joined(separator: "\n")
        }
        var flags: MessageFlags = []
        for (keyword, flag) in [("$seen", MessageFlags.read), ("$flagged", .starred), ("$draft", .draft), ("$answered", .answered)] where value.keywords[keyword] == true { flags.insert(flag) }
        let attachments = (value.attachments ?? []).enumerated().map { index, part in
            Attachment(id: "\(value.id):\(part.partId ?? part.blobId ?? String(index))", filename: part.name ?? "",
                       mimeType: part.type ?? "application/octet-stream", size: max(0, part.size ?? 0))
        }
        let html = bodyText(value.htmlBody)
        let text = bodyText(value.textBody)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainText: String?
        if let text, !text.isEmpty {
            plainText = looksLikeHTML(text) ? textFromHTML(text) : text
        } else {
            plainText = html.flatMap(textFromHTML)
        }
        let body = MessageBody(id: value.id, plainText: plainText, html: html)
        let message = Message(id: value.id, accountId: accountId, threadId: value.threadId, subject: value.subject ?? "",
                              sender: addresses(value.from).first ?? EmailAddress(address: ""), to: addresses(value.to),
                              cc: addresses(value.cc), bcc: addresses(value.bcc), replyTo: addresses(value.replyTo), date: date,
                              internetMessageId: value.messageId?.first.map { "<\($0)>" },
                              inReplyTo: value.inReplyTo?.map { "<\($0)>" }.joined(separator: " "),
                              references: (value.references ?? []).map { "<\($0)>" }, flags: flags,
                              mailboxIds: Set(value.mailboxIds.filter(\.value).keys), bodyId: body.id, attachmentIds: attachments.map(\.id),
                              automationHeaders: TrafficClassifier.automationHeaders([
                                  ("list-unsubscribe", value.listUnsubscribe), ("list-id", value.listId), ("precedence", value.precedence),
                                  ("auto-submitted", value.autoSubmitted), ("x-auto-response-suppress", value.autoResponseSuppress),
                                  ("feedback-id", value.feedbackId),
                              ].compactMap { name, header in header.map { (name: name, value: $0) } }))
        return MappedJMAPMessage(message: message, body: body, attachments: attachments)
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: #"(?is)^\s*(?:<!doctype\s+html\b|<html\b|<head\b|<body\b|<(?:div|p|table)\b[^>]*>)"#, options: .regularExpression) != nil
    }

    static func textFromHTML(_ html: String) -> String? {
        let collapsed = HTMLText.plainText(from: html)?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return collapsed.isEmpty ? nil : collapsed
    }
}
