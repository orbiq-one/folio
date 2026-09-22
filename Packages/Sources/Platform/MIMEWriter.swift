import Domain
import Foundation

public enum MIMEWriter {
    public enum Failure: LocalizedError {
        case invalidHeader, missingAttachmentData
        public var errorDescription: String? {
            switch self {
            case .invalidHeader: "A message header or address is invalid."
            case .missingAttachmentData: "Attachment contents are unavailable. Remove the attachment before sending."
            }
        }
    }

    public static func write(message: Message, body: MessageBody, attachments: [Attachment] = []) throws -> Data {
        guard attachments.isEmpty, message.attachmentIds.isEmpty else { throw Failure.missingAttachmentData }
        func header(_ value: String) throws -> String {
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw Failure.invalidHeader }
            return value
        }
        func addresses(_ values: [EmailAddress]) throws -> String {
            try values.map { value in
                let address = try header(value.address)
                guard address.contains("@"), !address.contains(where: { $0.isWhitespace || "<>,;".contains($0) }) else { throw Failure.invalidHeader }
                return value.name.map { encodedWord($0) + " <" + address + ">" } ?? address
            }.joined(separator: ", ")
        }
        let boundary = "Folio-" + UUID().uuidString
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var headers = ["From: \(try addresses([message.sender]))", "To: \(try addresses(message.to))",
                       "Subject: \(encodedWord(try header(message.subject)))", "Date: \(date.string(from: message.date))",
                       "Message-ID: \(try header(message.internetMessageId ?? "<\(UUID().uuidString)@projectmail.local>"))", "MIME-Version: 1.0"]
        if !message.cc.isEmpty { headers.append("Cc: \(try addresses(message.cc))") }
        if !message.replyTo.isEmpty { headers.append("Reply-To: \(try addresses(message.replyTo))") }
        if let reply = message.inReplyTo { headers.append("In-Reply-To: \(try header(reply))") }
        if !message.references.isEmpty { headers.append("References: \(try message.references.map(header).joined(separator: " "))") }
        headers.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
        var text = headers.joined(separator: "\r\n") + "\r\n\r\n"
        for (type, content) in [("text/plain", body.plainText ?? ""), ("text/html", body.html ?? "<pre>\(escape(body.plainText ?? ""))</pre>")] {
            text += "--\(boundary)\r\nContent-Type: \(type); charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n\(quotedPrintable(content))\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }

    static func encodedWord(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        var words: [String] = []; var chunk = ""
        for character in value {
            if chunk.utf8.count + String(character).utf8.count > 42, !chunk.isEmpty {
                words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?="); chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append("=?UTF-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    static func quotedPrintable(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n").map { line in
            var output = ""; var length = 0
            for byte in line.utf8 {
                let token = (33...60).contains(byte) || (62...126).contains(byte) ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if length + token.count > 72 { output += "=\r\n"; length = 0 }
                output += token; length += token.count
            }
            return output
        }.joined(separator: "\r\n")
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
