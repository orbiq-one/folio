import Foundation

public enum ProviderKind: String, Codable, Sendable {
    case gmail, microsoftGraph, imap, jmap, mock
}

public struct ProviderCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let labels = Self(rawValue: 1 << 0)
    public static let serverSearch = Self(rawValue: 1 << 1)
    public static let push = Self(rawValue: 1 << 2)
    public static let drafts = Self(rawValue: 1 << 3)
    public static let sendAs = Self(rawValue: 1 << 4)
    public static let spamActions = Self(rawValue: 1 << 5)
}

public struct Account: Codable, Equatable, Sendable {
    public var id: String
    public var provider: ProviderKind
    public var displayName: String
    public var email: EmailAddress
    public var capabilities: ProviderCapabilities

    public init(id: String, provider: ProviderKind, displayName: String, email: EmailAddress,
                capabilities: ProviderCapabilities = []) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.email = email
        self.capabilities = capabilities
    }
}
