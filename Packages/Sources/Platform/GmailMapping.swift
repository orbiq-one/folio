import CoreFoundation
import Domain
import Foundation

struct MappedGmailMessage: Sendable {
    let message: Message
    let body: MessageBody
    let attachments: [Attachment]
}

enum GmailMapping {
    static let capabilities: ProviderCapabilities = [.labels, .serverSearch, .drafts, .sendAs, .spamActions]

    static func mailbox(_ label: GmailLabel, accountId: String) -> Mailbox? {
        guard label.id != "UNREAD" else { return nil }
        let kind: MailboxKind
        switch label.id {
        case "INBOX": kind = .inbox
        case "SENT": kind = .sent
        case "DRAFT": kind = .drafts
        case "TRASH": kind = .trash
        case "SPAM": kind = .spam
        case "STARRED": kind = .starred
        default: kind = .label
        }
        return Mailbox(id: label.id, accountId: accountId, kind: kind, name: label.name,
                       isHidden: label.id.hasPrefix("CATEGORY_") || label.id == "CHAT" || label.labelListVisibility == "labelHide",
                       isSystem: label.type == "system" || kind != .label || label.id == "IMPORTANT" || label.id == "CHAT" || label.id.hasPrefix("CATEGORY_"))
    }

    static func mailboxes(_ labels: [GmailLabel], accountId: String) -> [Mailbox] {
        let userLabels = labels.filter { $0.type != "system" }
        let parents = Dictionary(userLabels.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        return labels.compactMap { label -> Mailbox? in
            guard var mailbox = mailbox(label, accountId: accountId) else { return nil }
            if label.type != "system", label.name.contains("/") {
                let parentName = label.name.components(separatedBy: "/").dropLast().joined(separator: "/")
                mailbox.parentId = parents[parentName]
            }
            return mailbox
        }.sorted {
            let leftDepth = $0.name.components(separatedBy: "/").count
            let rightDepth = $1.name.components(separatedBy: "/").count
            return leftDepth == rightDepth ? $0.name < $1.name : leftDepth < rightDepth
        }
    }

    static func flags(labelIds: Set<String>) -> MessageFlags {
        var flags: MessageFlags = []
        if !labelIds.contains("UNREAD") { flags.insert(.read) }
        if labelIds.contains("STARRED") { flags.insert(.starred) }
        if labelIds.contains("DRAFT") { flags.insert(.draft) }
        return flags
    }

    static func message(_ value: GmailMessage, accountId: String) throws -> MappedGmailMessage {
        guard let milliseconds = Double(value.internalDate), milliseconds.isFinite else { throw URLError(.cannotParseResponse) }
        let headers = value.payload.headers ?? []
        func header(_ name: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        var plain: [String] = []
        var html: [String] = []
        var attachments: [Attachment] = []
        func visit(_ part: GmailPart, path: String) throws {
            if let filename = part.filename, !filename.isEmpty {
                attachments.append(Attachment(id: "\(value.id):\(part.partId ?? path)", filename: filename,
                                              mimeType: part.mimeType, size: max(0, part.body?.size ?? 0)))
                return
            }
            if let data = part.body?.data, ["text/plain", "text/html"].contains(part.mimeType) {
                let bytes = try decodeBase64URL(data)
                let contentType = part.headers?.first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
                let charset = contentType.components(separatedBy: ";").dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { $0.hasPrefix("charset=") }?.dropFirst(8)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? "utf-8"
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                guard cfEncoding != kCFStringEncodingInvalidId else { throw URLError(.cannotDecodeContentData) }
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                guard let text = String(data: bytes, encoding: encoding) else { throw URLError(.cannotDecodeContentData) }
                if part.mimeType == "text/plain" { plain.append(text) } else { html.append(text) }
            }
            for (index, child) in (part.parts ?? []).enumerated() { try visit(child, path: "\(path).\(index)") }
        }
        try visit(value.payload, path: "0")
        let labels = Set(value.labelIds ?? [])
        let flags = flags(labelIds: labels)
        let body = MessageBody(id: value.id, plainText: plain.isEmpty ? nil : plain.joined(separator: "\n"),
                               html: html.isEmpty ? nil : html.joined(separator: "\n"))
        let message = Message(id: value.id, accountId: accountId, threadId: value.threadId,
                              subject: header("Subject") ?? "", sender: addresses(header("From") ?? "").first ?? EmailAddress(address: ""),
                              to: addresses(header("To") ?? ""), cc: addresses(header("Cc") ?? ""), bcc: addresses(header("Bcc") ?? ""),
                              replyTo: addresses(header("Reply-To") ?? ""), date: Date(timeIntervalSince1970: milliseconds / 1_000),
                              internetMessageId: header("Message-ID"), inReplyTo: header("In-Reply-To"),
                              references: (header("References") ?? "").split(whereSeparator: \.isWhitespace).map(String.init),
                              flags: flags, mailboxIds: labels.subtracting(["UNREAD"]), bodyId: body.id, attachmentIds: attachments.map(\.id),
                              automationHeaders: TrafficClassifier.automationHeaders(headers.map { (name: $0.name, value: $0.value) }))
        return MappedGmailMessage(message: message, body: body, attachments: attachments)
    }

    static func decodeBase64URL(_ value: String) throws -> Data {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { throw URLError(.cannotDecodeContentData) }
        return data
    }

    static func addresses(_ value: String) -> [EmailAddress] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        var angle = false
        for character in value {
            if character == ",", !quoted, !angle { pieces.append(current); current = ""; continue }
            current.append(character)
            if escaped { escaped = false; continue }
            if character == "\\", quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if character == "<", !quoted { angle = true }
            else if character == ">", !quoted { angle = false }
        }
        pieces.append(current)
        return pieces.compactMap { piece in
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            if let start = text.lastIndex(of: "<"), let end = text.lastIndex(of: ">"), start < end {
                let name = text[..<start].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
                return EmailAddress(address: String(text[text.index(after: start)..<end]), name: name.isEmpty ? nil : name)
            }
            return EmailAddress(address: text)
        }
    }
}
