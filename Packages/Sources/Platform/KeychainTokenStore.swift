import Foundation
import Security

public struct OAuthTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol TokenStore: Sendable {
    func load(accountId: String) async throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens, accountId: String) async throws
    func delete(accountId: String) async throws
}

public actor KeychainTokenStore: TokenStore {
    private let service: String

    // Pre-rename service name; changing it would drop saved sign-ins.
    public init(service: String = "re.leob.ProjectMail.oauth") { self.service = service }

    public func load(accountId: String) throws -> OAuthTokens? {
        var query = query(accountId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens, accountId: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let query = query(accountId)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw KeychainError(status: result) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    public func delete(accountId: String) throws {
        let status = SecItemDelete(query(accountId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func query(_ accountId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountId]
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain access failed (\(status))." }
}
