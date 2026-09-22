import Foundation

enum NewsletterLink {
    static func unsubscribeURL(in header: String?) -> URL? {
        guard let header else { return nil }
        let enclosed = header.matches(of: /<([^<>]+)>/).map { String($0.output.1) }
        let candidates = enclosed.isEmpty ? header.components(separatedBy: ",") : enclosed
        for part in candidates {
            let candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.contains(where: { $0.isWhitespace }),
                  let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { continue }
            if scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil { return url }
            if scheme == "mailto", !url.path.isEmpty { return url }
        }
        return nil
    }
}
