import Foundation

struct QuotedMessageText: Equatable {
    let body: String
    let quote: String?

    init(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }),
              lines[start...].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }) else {
            body = text
            quote = nil
            return
        }
        body = lines[..<start].joined(separator: "\n").trimmingCharacters(in: .newlines)
        quote = lines[start...].joined(separator: "\n")
    }
}
