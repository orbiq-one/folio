import Foundation

public struct SyncProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) { self.completed = completed; self.total = total }
}

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing(SyncProgress?)
    case error(String)

    public var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }
}

public struct FastmailCredentials: Equatable, Sendable {
    public var email: String
    public var apiToken: String

    public init(email: String, apiToken: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool { email.contains("@") && !apiToken.isEmpty }
}

public struct IMAPCredentials: Equatable, Codable, Sendable {
    public enum Security: String, Codable, Sendable { case tls, startTLS }
    public var email: String
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var security: Security
    public var smtpHost: String?
    public var smtpPort: Int?
    public var smtpSecurity: Security?
    public var senderName: String?
    public var resolvedSMTPHost: String { smtpHost ?? host.replacingOccurrences(of: "imap", with: "smtp", options: .caseInsensitive) }
    public var resolvedSMTPPort: Int { smtpPort ?? 587 }
    public var resolvedSMTPSecurity: Security { smtpSecurity ?? .startTLS }

    public init(email: String, host: String, port: Int = 993, username: String = "", password: String, security: Security = .tls, smtpHost: String? = nil, smtpPort: Int? = nil, smtpSecurity: Security? = nil, senderName: String? = nil) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.isEmpty ? self.email : username
        self.password = password
        self.security = security
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpSecurity = smtpSecurity
        let trimmed = senderName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.senderName = trimmed.isEmpty ? nil : trimmed
    }

    public var isComplete: Bool {
        email.contains("@") && !host.isEmpty && (1...65535).contains(port) && !username.isEmpty && !password.isEmpty
    }
}

public protocol AccountService: Sendable {
    func addMockAccount() async throws
    func addAccount() async throws
    func addFastmailAccount(_ credentials: FastmailCredentials) async throws
    func addIMAPAccount(_ credentials: IMAPCredentials) async throws
    func removeAccount(id: String) async throws
    /// Sets the display name used in the From header; nil clears it.
    func setSenderName(_ name: String?, accountId: String) async throws
    func refresh() async
    func statuses() async -> AsyncStream<[String: SyncStatus]>
}
