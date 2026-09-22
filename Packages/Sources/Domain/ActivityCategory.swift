import Foundation

public enum ActivityCategory: String, Codable, CaseIterable, Sendable {
    case orders, money, security, notifications, newsletters

    public static func classify(message: Message, body: MessageBody? = nil) -> ActivityCategory {
        let cleaned = BodyCleaner.clean(plainText: body?.plainText, html: body?.html).displayText
        let firstLines = cleaned.split(whereSeparator: \.isNewline).prefix(5).joined(separator: " ")
        let text = "\(message.sender.address) \(message.subject) \(firstLines)".lowercased()
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !words.isDisjoint(with: ["verification", "otp", "password", "authentication"])
            || ["one-time", "one time", "sign-in", "sign in", "security alert", "security code", "login code"].contains(where: text.contains) {
            return .security
        }
        if message.automationHeaders["list-unsubscribe"] != nil && message.automationHeaders["list-id"] != nil
            || !words.isDisjoint(with: ["newsletter", "newsletters", "digest"]) {
            return .newsletters
        }
        if !words.isDisjoint(with: ["order", "orders", "ordered", "shipped", "shipping", "delivery", "tracking", "parcel"]) {
            return .orders
        }
        if !words.isDisjoint(with: ["invoice", "invoices", "receipt", "receipts", "payment", "payments", "billing"])
            || text.range(of: #"(?:[$€]\s*\d|\d[\d.,]*\s*[$€])"#, options: .regularExpression) != nil {
            return .money
        }
        return .notifications
    }
}

public struct ActivityItem: Equatable, Sendable {
    public var message: Message
    public var displayText: String

    public init(message: Message, displayText: String) {
        self.message = message
        self.displayText = displayText
    }
}
