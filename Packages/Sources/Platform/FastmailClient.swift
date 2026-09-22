import Domain
import Foundation

struct JMAPSession: Decodable, Sendable {
    struct Account: Decodable, Sendable { let name: String; let isPersonal: Bool }
    let username: String
    let apiUrl: String
    let accounts: [String: Account]
    let primaryAccounts: [String: String]

    var mailAccountId: String? { primaryAccounts["urn:ietf:params:jmap:mail"] }
}

enum FastmailClient {
    static let sessionURL = URL(string: "https://api.fastmail.com/jmap/session")!
    static let capabilities: ProviderCapabilities = [.labels, .serverSearch, .drafts, .push]

    static func session(token: String, session: URLSession) async throws -> JMAPSession {
        var request = URLRequest(url: sessionURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401, 403: throw FastmailError.unauthorized
        default: throw FastmailError.http(status)
        }
        let decoded = try JSONDecoder().decode(JMAPSession.self, from: data)
        guard decoded.mailAccountId != nil else { throw FastmailError.noMailAccount }
        return decoded
    }
}

enum FastmailError: LocalizedError, Equatable {
    case unauthorized
    case noMailAccount
    case emailMismatch(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Fastmail rejected the API token. Create one at fastmail.com under Settings › Privacy & Security › Connected apps & API tokens › Manage API tokens, with Mail read/write access. App passwords do not work here."
        case .noMailAccount: "This Fastmail account has no mail access."
        case .emailMismatch(let username): "That API token belongs to \(username), not the address you entered."
        case .http(let status): "Fastmail returned an error (\(status))."
        }
    }
}
