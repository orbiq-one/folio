import Foundation

public enum TrafficKind: String, Codable, Sendable, CaseIterable {
    case human, activity
}

public struct SenderRule: Codable, Equatable, Sendable {
    public var accountId: String
    public var address: String
    public var kind: TrafficKind
    public var setAt: Date

    public init(accountId: String, address: String, kind: TrafficKind, setAt: Date = .now) {
        self.accountId = accountId
        self.address = address.lowercased()
        self.kind = kind
        self.setAt = setAt
    }
}

public enum TrafficClassifier {
    public static let automationHeaderNames: Set<String> = [
        "list-unsubscribe", "list-id", "precedence", "auto-submitted", "x-auto-response-suppress", "feedback-id",
    ]

    static let automatedLocalParts: Set<String> = [
        "noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notifications", "notification", "mailer",
        "mailer-daemon", "postmaster", "receipts", "receipt", "billing", "invoice", "invoices", "newsletter",
        "newsletters", "digest", "alerts", "alert", "marketing", "updates",
    ]

    public static func automationHeaders(_ headers: [(name: String, value: String)]) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers {
            let name = header.name.lowercased()
            if automationHeaderNames.contains(name) { result[name] = header.value }
        }
        return result
    }

    public static func classify(_ message: Message, accountEmail: String, isKnownContact: Bool, rule: TrafficKind?) -> TrafficKind {
        if let rule { return rule }
        let sender = message.sender.address.lowercased()
        if sender == accountEmail.lowercased() { return .human }
        if isKnownContact { return .human }
        let headers = message.automationHeaders
        if headers["list-unsubscribe"] != nil || headers["list-id"] != nil || headers["feedback-id"] != nil { return .activity }
        if let precedence = headers["precedence"]?.lowercased(), ["bulk", "list", "junk"].contains(where: precedence.contains) { return .activity }
        if let auto = headers["auto-submitted"]?.lowercased(), auto != "no" { return .activity }
        if headers["x-auto-response-suppress"] != nil { return .activity }
        let local = sender.split(separator: "@").first.map(String.init) ?? sender
        if automatedLocalParts.contains(local) { return .activity }
        if local.hasPrefix("noreply") || local.hasPrefix("no-reply") || local.hasPrefix("notification") || local.hasSuffix("-noreply") { return .activity }
        return .human
    }
}
