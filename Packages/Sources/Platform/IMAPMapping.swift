import CryptoKit
import Domain
import Foundation

struct MappedIMAPMessage: Sendable {
    var message: Message
    var body: MessageBody
    var attachments: [Attachment]
}

enum IMAPMapping {
    static func kind(path: String, attributes: [String]) -> MailboxKind {
        let attributes = Set(attributes.map { $0.lowercased() })
        for (attribute, kind): (String, MailboxKind) in [("\\sent", .sent), ("\\drafts", .drafts), ("\\trash", .trash), ("\\junk", .spam), ("\\archive", .archive)] {
            if attributes.contains(attribute) { return kind }
        }
        let name = path.lowercased().components(separatedBy: CharacterSet(charactersIn: "/.")).last ?? path.lowercased()
        switch name {
        case "inbox": return .inbox
        case "sent", "sent mail", "sent items": return .sent
        case "draft", "drafts": return .drafts
        case "trash", "deleted items", "deleted messages": return .trash
        case "junk", "spam", "junk email", "junk e-mail": return .spam
        case "archive", "archives", "all mail": return .archive
        default: return .folder
        }
    }

    static func mailbox(_ folder: IMAPFolder, accountId: String) -> Mailbox {
        let kind = kind(path: folder.path, attributes: folder.attributes)
        let components = folder.separator.map { folder.path.components(separatedBy: $0) } ?? [folder.path]
        return Mailbox(id: folder.path, accountId: accountId, kind: kind, name: decodeMailboxName(components.last ?? folder.path),
                       parentId: components.count > 1 ? components.dropLast().joined(separator: folder.separator ?? "/") : nil,
                       isSystem: kind != .folder)
    }

    static func mailboxes(_ folders: [IMAPFolder], accountId: String) -> [Mailbox] {
        let paths = Set(folders.map(\.path))
        return folders.sorted { $0.path.count < $1.path.count }.map { folder in
            var mailbox = mailbox(folder, accountId: accountId)
            if let parent = mailbox.parentId, !paths.contains(parent) { mailbox.parentId = nil }
            return mailbox
        }
    }

    static func decodeMailboxName(_ value: String) -> String {
        var result = ""
        var remainder = value[...]
        while let amp = remainder.firstIndex(of: "&"), let end = remainder[amp...].firstIndex(of: "-") {
            result += remainder[..<amp]
            let encoded = String(remainder[remainder.index(after: amp)..<end])
            if encoded.isEmpty { result += "&" }
            else {
                let base64 = encoded.replacingOccurrences(of: ",", with: "/")
                let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
                if let bytes = Foundation.Data(base64Encoded: padded), let text = String(data: bytes, encoding: .utf16BigEndian) { result += text }
                else { result += String(remainder[amp...end]) }
            }
            remainder = remainder[remainder.index(after: end)...]
        }
        return result + remainder
    }

    static func flags(_ values: [String]) -> MessageFlags {
        var result: MessageFlags = []
        for value in values.map({ $0.lowercased() }) {
            switch value {
            case "\\seen": result.insert(.read)
            case "\\flagged": result.insert(.starred)
            case "\\draft": result.insert(.draft)
            case "\\answered": result.insert(.answered)
            default: break
            }
        }
        return result
    }

    static func messageIDs(_ value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<[^<>\\s]+>") else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    static func threadID(accountId: String, headers: [String: String]) -> String {
        let root = messageIDs(headers["references"] ?? "").first
            ?? messageIDs(headers["in-reply-to"] ?? "").first
            ?? messageIDs(headers["message-id"] ?? "").first
        if let root { return accountId + ":" + root }
        var subject = MIMEParser.decodeHeader(headers["subject"] ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = subject.range(of: "^(re|fw|fwd):\\s*", options: .regularExpression) { subject.removeSubrange(range) }
        let hash = SHA256.hash(data: Foundation.Data(subject.utf8)).map { String(format: "%02x", $0) }.joined()
        return accountId + ":subject:" + hash
    }

    static func location(_ id: String) throws -> (folder: String, uid: UInt32) {
        guard let slash = id.lastIndex(of: "/"), let uid = UInt32(id[id.index(after: slash)...]), uid > 0 else { throw IMAPError.invalidResponse }
        return (String(id[..<slash]), uid)
    }

    static func message(_ value: IMAPFetchedMessage, folder: String, accountId: String) -> MappedIMAPMessage {
        let parsed = MIMEParser.parse(value.data)
        let headers = parsed.headers
        let id = "\(folder)/\(value.uid)"
        let attachments = parsed.attachments.enumerated().map { index, attachment in
            var attachment = attachment
            attachment.id = "\(id):\(index)"
            return attachment
        }
        func addresses(_ field: String) -> [EmailAddress] { GmailMapping.addresses(MIMEParser.decodeHeader(headers[field] ?? "")) }
        let body = MessageBody(id: id, plainText: parsed.plainText, html: parsed.html)
        let message = Message(id: id, accountId: accountId, threadId: threadID(accountId: accountId, headers: headers),
                              subject: MIMEParser.decodeHeader(headers["subject"] ?? ""), sender: addresses("from").first ?? EmailAddress(address: ""),
                              to: addresses("to"), cc: addresses("cc"), bcc: addresses("bcc"), replyTo: addresses("reply-to"), date: value.date,
                              internetMessageId: messageIDs(headers["message-id"] ?? "").first,
                              inReplyTo: messageIDs(headers["in-reply-to"] ?? "").first, references: messageIDs(headers["references"] ?? ""),
                              flags: value.flags, mailboxIds: [folder], bodyId: id, attachmentIds: attachments.map(\.id),
                              automationHeaders: TrafficClassifier.automationHeaders(headers.map { (name: $0.key, value: $0.value) }))
        return MappedIMAPMessage(message: message, body: body, attachments: attachments)
    }
}
