import CryptoKit
import Domain
import Foundation

struct ParsedMIME: Sendable {
    var headers: [String: String] = [:]
    var plainText: String?
    var html: String?
    var attachments: [Attachment] = []
}

enum MIMEParser {
    static func parse(_ data: Foundation.Data, depth: Int = 0) -> ParsedMIME {
        guard depth < 30 else { return ParsedMIME() }
        let separator = data.range(of: Foundation.Data("\r\n\r\n".utf8)) ?? data.range(of: Foundation.Data("\n\n".utf8))
        let headerData = separator.map { data[..<$0.lowerBound] } ?? data[...]
        let body = separator.map { Foundation.Data(data[$0.upperBound...]) } ?? Foundation.Data()
        var result = ParsedMIME(headers: headers(String(decoding: headerData, as: UTF8.self)))
        let contentType = result.headers["content-type"] ?? "text/plain"
        let type = contentType.components(separatedBy: ";")[0].lowercased().trimmingCharacters(in: .whitespaces)
        if type.hasPrefix("multipart/"), let boundary = parameter("boundary", in: contentType), !boundary.isEmpty {
            let marker = Foundation.Data(("--" + boundary).utf8)
            var start = body.startIndex
            var partStart: Int?
            while start < body.endIndex, let range = body.range(of: marker, in: start..<body.endIndex) {
                start = range.upperBound
                guard range.lowerBound == 0 || body[range.lowerBound - 1] == 10 else { continue }
                let closing = body[start...].starts(with: [45, 45])
                guard closing || body[start...].starts(with: [13, 10]) || body[start...].starts(with: [10]) else { continue }
                if let partStart {
                    var end = range.lowerBound
                    if end > partStart && body[end - 1] == 10 { end -= 1 }
                    if end > partStart && body[end - 1] == 13 { end -= 1 }
                    let child = parse(Foundation.Data(body[partStart..<end]), depth: depth + 1)
                    if let text = child.plainText { result.plainText = [result.plainText, text].compactMap { $0 }.joined(separator: "\n") }
                    if let html = child.html { result.html = [result.html, html].compactMap { $0 }.joined(separator: "\n") }
                    result.attachments += child.attachments
                }
                if closing { break }
                partStart = start + (body[start] == 13 ? 2 : 1)
            }
            return result
        }
        let decoded = decode(body, transfer: result.headers["content-transfer-encoding"] ?? "")
        let disposition = result.headers["content-disposition"] ?? ""
        let filename = parameter("filename", in: disposition) ?? parameter("name", in: contentType)
        if filename != nil || disposition.lowercased().hasPrefix("attachment") || !type.hasPrefix("text/") {
            let hash = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
            result.attachments = [Attachment(id: hash, filename: decodeHeader(filename ?? "Attachment"), mimeType: type, size: Int64(decoded.count), contentHash: hash)]
        } else {
            let text = string(decoded, charset: parameter("charset", in: contentType) ?? "utf-8")
            if type == "text/html" { result.html = text }
            else if type == "text/plain" { result.plainText = text }
        }
        return result
    }

    static func headers(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        var key: String?
        for line in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), let key {
                result[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased()
                key = name
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                result[name] = result[name].map { $0 + " " + value } ?? value
            }
        }
        return result
    }

    static func parameter(_ name: String, in value: String) -> String? {
        let pattern = "(?:^|;)\\s*" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*(?:\"((?:\\\\.|[^\"])*)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        for index in 1...2 {
            if let range = Range(match.range(at: index), in: value) { return String(value[range]).replacingOccurrences(of: "\\\"", with: "\"") }
        }
        return nil
    }

    static func decode(_ data: Foundation.Data, transfer: String) -> Foundation.Data {
        switch transfer.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": return Foundation.Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            let bytes = Array(data)
            var output = Foundation.Data()
            var index = 0
            while index < bytes.count {
                if bytes[index] == 61 {
                    if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                    if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                    if index + 2 < bytes.count, let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                        output.append(byte); index += 3; continue
                    }
                }
                output.append(bytes[index]); index += 1
            }
            return output
        default: return data
        }
    }

    static func string(_ data: Foundation.Data, charset: String) -> String {
        let encoding: String.Encoding = switch charset.lowercased() {
        case "iso-8859-1", "latin1": .isoLatin1
        case "windows-1252", "cp1252": .windowsCP1252
        default: .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    static func decodeHeader(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return value }
        let source = value.replacingOccurrences(of: "(?<=\\?=)[ \\t\\r\\n]+(?==\\?)", with: "", options: .regularExpression)
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let whole = Range(match.range, in: result), let charset = Range(match.range(at: 1), in: source),
                  let encoding = Range(match.range(at: 2), in: source), let payload = Range(match.range(at: 3), in: source) else { continue }
            let base64 = source[encoding].lowercased() == "b"
            let encoded = base64 ? String(source[payload]) : source[payload].replacingOccurrences(of: "_", with: " ")
            result.replaceSubrange(whole, with: string(decode(Foundation.Data(encoded.utf8), transfer: base64 ? "base64" : "quoted-printable"), charset: String(source[charset])))
        }
        return result
    }
}
