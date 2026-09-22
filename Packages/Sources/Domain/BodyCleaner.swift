import Foundation

public enum HTMLText {
    public static func plainText(from html: String) -> String? {
        let visible = html
            .replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style|head|title)\b[^>]*>.*?</\1\s*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]*style\s*=\s*"[^"]*display\s*:\s*none[^"]*"[^>]*>.*?</[a-z]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<(br|/?p|/?div|/?li|/?tr|/?h[1-6]|/?blockquote|/?table)\b[^>]*>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]*>"#, with: " ", options: .regularExpression)
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
                        "hellip": "…", "copy": "©", "reg": "®", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        var decoded = visible
        if let pattern = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) {
            for match in pattern.matches(in: visible, range: NSRange(visible.startIndex..., in: visible)).reversed() {
                guard let range = Range(match.range, in: decoded), let keyRange = Range(match.range(at: 1), in: visible) else { continue }
                let key = String(visible[keyRange])
                let replacement: String?
                if key.hasPrefix("#x") {
                    replacement = UInt32(key.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map(String.init)
                } else if key.hasPrefix("#") {
                    replacement = UInt32(key.dropFirst()).flatMap(UnicodeScalar.init).map(String.init)
                } else { replacement = entities[key] }
                if let replacement { decoded.replaceSubrange(range, with: replacement) }
            }
        }
        let lines = decoded.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0.isWhitespace && !$0.isNewline }).joined(separator: " ") }
        let result = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

/// Produces the text the user actually wrote: no quoted history, signature, legal footer, or tracking noise.
public enum BodyCleaner {
    public struct Result: Equatable, Sendable {
        public var displayText: String
        public var quotedText: String?
        public var signature: String?
    }

    static let quoteStarters: [String] = [
        #"^\s*On .{3,200}? wrote:\s*$"#,
        #"^\s*-{2,}\s*Original Message\s*-{2,}\s*$"#,
        #"^\s*-{2,}\s*Forwarded message\s*-{2,}\s*$"#,
        #"^\s*Begin forwarded message:\s*$"#,
        #"^\s*Am .{3,200}? schrieb .{1,200}?:\s*$"#,
        #"^\s*Le .{3,200}? a écrit\s*:\s*$"#,
        #"^\s*_{5,}\s*$"#,
    ]

    static let outlookHeader = #"^\s*(From|Von|De)\s*:\s.+$"#
    static let outlookHeaderFollowers = #"^\s*(Sent|To|Subject|Cc|Date|Gesendet|An|Betreff|Envoyé|À|Objet)\s*:\s.+$"#

    static let signatureMarkers: [String] = [
        #"^-- ?$"#,
        #"^\s*(Sent|Get Outlook|Gesendet) (from|for|von|mit) (my )?.{2,40}$"#,
        #"^\s*(Best|Kind|Warm)( regards)?,?\s*$"#,
        #"^\s*(Regards|Cheers|Thanks|Thank you|Many thanks|Best wishes|Sincerely|Viele Grüße|Liebe Grüße|Mit freundlichen Grüßen|Beste Grüße|Cordialement|Saludos),?\s*$"#,
    ]

    static let footerPatterns: [String] = [
        #"(?i)\bconfidential(ity)?\b"#, #"(?i)\bunsubscribe\b"#, #"(?i)\bthis (e-?mail|message) (was|is) (sent|intended)"#,
        #"(?i)\byou('re| are) receiving this\b"#, #"(?i)\bprivileged\b"#, #"(?i)\bview (it|this) in your browser\b"#,
        #"(?i)\bmanage (your )?(email )?preferences\b"#, #"(?i)\ball rights reserved\b"#, #"(?i)\bprivacy policy\b"#,
        #"(?i)\bterms of (service|use)\b"#, #"(?i)\bif you (are not|aren't) the intended recipient\b"#,
    ]

    public static func clean(plainText: String?, html: String?) -> Result {
        let source = plainText?.nonEmpty ?? html.flatMap(HTMLText.plainText(from:)) ?? ""
        return clean(source)
    }

    public static func clean(_ text: String) -> Result {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var quoted: [String] = []

        if let cut = quoteStart(in: lines) {
            quoted = Array(lines[cut...])
            lines = Array(lines[..<cut])
        }

        var signature: [String] = []
        if let cut = signatureStart(in: lines) {
            signature = Array(lines[cut...])
            lines = Array(lines[..<cut])
        }

        lines = stripFooters(lines)
        let display = normalize(lines)
        let fallback = display.isEmpty ? normalize(quoted.map { stripQuotePrefix($0) }) : display
        return Result(displayText: fallback.isEmpty ? normalize(text.components(separatedBy: "\n")) : fallback,
                      quotedText: normalize(quoted).nonEmpty, signature: normalize(signature).nonEmpty)
    }

    private static func quoteStart(in lines: [String]) -> Int? {
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                let rest = lines[index...]
                if rest.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }) {
                    return index
                }
                let quotedShare = Double(rest.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }.count) / Double(rest.count)
                if quotedShare > 0.6 { return index }
            }
            if quoteStarters.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) { return index }
            if line.range(of: outlookHeader, options: .regularExpression) != nil,
               index + 1 < lines.count,
               lines[index + 1].range(of: outlookHeaderFollowers, options: .regularExpression) != nil { return index }
            // Two-line "On <date>" / "<name> wrote:" split by a soft wrap.
            if line.range(of: #"^\s*On .{3,120}$"#, options: .regularExpression) != nil,
               index + 1 < lines.count,
               lines[index + 1].range(of: #"^.{0,120}wrote:\s*$"#, options: .regularExpression) != nil { return index }
        }
        return nil
    }

    private static func signatureStart(in lines: [String]) -> Int? {
        for (index, line) in lines.enumerated() where signatureMarkers.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) {
            if line.range(of: #"^-- ?$"#, options: .regularExpression) != nil { return index }
            if index > 0 || lines.count == 1 { return index }
        }
        // Trailing short block that looks like contact details.
        func blank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let end = lines.lastIndex(where: { !blank($0) }) else { return nil }
        var start = end
        while start > 0, !blank(lines[start - 1]) { start -= 1 }
        let tail = lines[start...end]
        guard (2...6).contains(tail.count), start > 0 else { return nil }
        let contactLike = tail.filter {
            $0.range(of: #"(?i)(\+?\d[\d ()/-]{6,}\d|https?://|www\.|@\w+\.\w+|\b(tel|phone|mobile|mobil|fax)\b)"#, options: .regularExpression) != nil
        }.count
        let sentenceLike = tail.filter { $0.range(of: #"[.!?]\s*$"#, options: .regularExpression) != nil && $0.split(separator: " ").count > 6 }.count
        guard contactLike >= 1, sentenceLike == 0 else { return nil }
        return start
    }

    private static func stripFooters(_ lines: [String]) -> [String] {
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { if !paragraphs.last!.isEmpty { paragraphs.append([]) } }
            else { paragraphs[paragraphs.count - 1].append(line) }
        }
        paragraphs = paragraphs.filter { !$0.isEmpty }
        while paragraphs.count > 1, let last = paragraphs.last {
            let text = last.joined(separator: " ")
            let hits = footerPatterns.filter { text.range(of: $0, options: .regularExpression) != nil }.count
            guard hits >= 1 else { break }
            paragraphs.removeLast()
        }
        return paragraphs.flatMap { $0 + [""] }
    }

    private static func stripQuotePrefix(_ line: String) -> String {
        line.replacingOccurrences(of: #"^\s*(>\s?)+"#, with: "", options: .regularExpression)
    }

    private static func normalize(_ lines: [String]) -> String {
        lines.map { $0.replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
