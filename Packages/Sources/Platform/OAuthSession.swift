import CryptoKit
import Foundation
import Security

public enum OAuthError: LocalizedError {
    case missingClientId, invalidCallback, denied, signInRequired, invalidResponse
    case temporarilyUnavailable(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .missingClientId: "Google sign-in is not configured. Set GMAIL_CLIENT_ID in Config/Local.xcconfig and rebuild."
        case .invalidCallback: "Google returned an invalid sign-in response. Please try again."
        case .denied: "Google sign-in was canceled or permission was denied."
        case .signInRequired: "Please sign in with Google again."
        case .invalidResponse: "Google returned an invalid token response."
        case .temporarilyUnavailable(let status, let detail):
            "Google authorization failed (HTTP \(status)\(detail.map { ": \($0)" } ?? "")). Sync will retry."
        }
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthError.invalidResponse }
        verifier = Self.base64URL(Data(bytes))
    }

    init(verifier: String) { self.verifier = verifier }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public actor OAuthSession {
    private let clientId: String
    private let tokens: any TokenStore
    private let session: URLSession
    private var refreshes: [String: Task<String, Error>] = [:]

    public init(clientId: String, tokens: any TokenStore, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tokens = tokens
        self.session = session
    }

    public func signIn() async throws -> OAuthTokens {
        let (url, redirect, state, pkce) = try authorizationRequest()
        let callback = try await WebAuthentication.authenticate(url: url, scheme: redirect.components(separatedBy: ":")[0])
        let code = try Self.authorizationCode(callback, redirect: redirect, state: state)
        return try await exchange(["client_id": clientId, "code": code, "code_verifier": pkce.verifier,
                                   "grant_type": "authorization_code", "redirect_uri": redirect], refreshToken: nil)
    }

    func authorizationRequest() throws -> (URL, String, String, PKCE) {
        try validateClientId()
        let redirect = clientId.components(separatedBy: ".").reversed().joined(separator: ".") + ":/oauth2redirect"
        let pkce = try PKCE()
        let state = try PKCE().verifier
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": clientId, "redirect_uri": redirect, "response_type": "code",
                          "scope": "https://www.googleapis.com/auth/gmail.modify", "access_type": "offline",
                          "prompt": "consent", "state": state, "code_challenge": pkce.challenge,
                          "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        return (url.url!, redirect, state, pkce)
    }

    static func authorizationCode(_ callback: URL, redirect: String, state: String) throws -> String {
        guard let expected = URL(string: redirect), callback.scheme == expected.scheme,
              callback.host == expected.host, callback.path == expected.path,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw OAuthError.invalidCallback }
        let items = components.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else { throw OAuthError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw OAuthError.denied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw OAuthError.invalidCallback }
        return code
    }

    public func accessToken(accountId: String, rejecting rejectedToken: String? = nil) async throws -> String {
        if let task = refreshes[accountId] { return try await task.value }
        guard let current = try await tokens.load(accountId: accountId) else { throw OAuthError.signInRequired }
        if let task = refreshes[accountId] { return try await task.value }
        if current.expiresAt > Date().addingTimeInterval(30), current.accessToken != rejectedToken { return current.accessToken }
        let task = Task {
            let updated = try await self.exchange(["client_id": self.clientId, "grant_type": "refresh_token",
                                                   "refresh_token": current.refreshToken], refreshToken: current.refreshToken)
            try Task.checkCancellation()
            try await self.tokens.save(updated, accountId: accountId)
            return updated.accessToken
        }
        refreshes[accountId] = task
        defer { refreshes[accountId] = nil }
        return try await task.value
    }

    private func validateClientId() throws {
        guard clientId.hasSuffix(".apps.googleusercontent.com"), !clientId.contains("YOUR_"), !clientId.contains("$(") else {
            throw OAuthError.missingClientId
        }
    }

    private func exchange(_ fields: [String: String], refreshToken: String?) async throws -> OAuthTokens {
        try validateClientId()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard response.statusCode == 200 else {
            struct Failure: Decodable { let error: String; let error_description: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if [400, 401].contains(response.statusCode), failure?.error == "invalid_grant" || failure?.error == "invalid_client" {
                throw OAuthError.signInRequired
            }
            let detail = failure.map { [$0.error, $0.error_description].compactMap { $0 }.joined(separator: ", ") }
            throw OAuthError.temporarilyUnavailable(response.statusCode, detail)
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !decoded.access_token.isEmpty, decoded.expires_in > 0,
              let refresh = decoded.refresh_token ?? refreshToken, !refresh.isEmpty else { throw OAuthError.invalidResponse }
        return OAuthTokens(accessToken: decoded.access_token, refreshToken: refresh,
                           expiresAt: Date().addingTimeInterval(decoded.expires_in))
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
    }
}
