import Foundation

struct GmailProfile: Decodable, Sendable {
    let emailAddress: String
    let historyId: String
}

struct GmailLabel: Decodable, Sendable {
    let id: String
    let name: String
    let type: String?
    var labelListVisibility: String? = nil
}

struct GmailMessageState: Decodable, Sendable {
    let id: String
    let labelIds: [String]?
}

struct GmailMessageReference: Decodable, Sendable { let id: String }

struct GmailMessagePage: Decodable, Sendable {
    let messages: [GmailMessageReference]?
    let nextPageToken: String?
}

struct GmailHistoryPage: Decodable, Sendable {
    let history: [GmailHistory]?
    let nextPageToken: String?
    let historyId: String
}

struct GmailHistory: Decodable, Sendable {
    struct Change: Decodable, Sendable {
        let message: GmailMessageReference
        let labelIds: [String]?
    }
    let messagesAdded: [Change]?
    let messagesDeleted: [Change]?
    let labelsAdded: [Change]?
    let labelsRemoved: [Change]?

    var changedIds: Set<String> {
        Set(((messagesAdded ?? []) + (messagesDeleted ?? []) + (labelsAdded ?? []) + (labelsRemoved ?? [])).map(\.message.id))
    }
}

struct GmailMessage: Decodable, Sendable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let internalDate: String
    var payload: GmailPart
}

struct GmailPart: Decodable, Sendable {
    struct Header: Decodable, Sendable { let name: String; let value: String }
    struct Body: Decodable, Sendable {
        let size: Int64?
        var data: String?
        let attachmentId: String?
    }
    let partId: String?
    let mimeType: String
    let filename: String?
    let headers: [Header]?
    var body: Body?
    var parts: [GmailPart]?
}

enum GmailClientError: Error {
    case messageNotFound
    case historyExpired
    case unsupportedAction
}

struct GmailHTTPError: LocalizedError {
    let status: Int
    var detail: String?
    var errorDescription: String? {
        let base = switch status {
        case 401: "Google authorization expired. Sign in again."
        case 403: "Google denied access. Check that the Gmail API and Gmail permission are enabled."
        case 429: "Google's request limit was reached. Sync will retry."
        default: "Gmail request failed (HTTP \(status)). Sync will retry."
        }
        return detail.map { "\(base) (\($0))" } ?? base
    }

    init(status: Int, body: Data? = nil) {
        self.status = status
        struct Envelope: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
        detail = body.flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }?.error.message
    }
}

public struct GmailClient: Sendable {
    private let accountId: String
    private let oauth: OAuthSession
    private let session: URLSession

    public init(accountId: String, oauth: OAuthSession, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.accountId = accountId
        self.oauth = oauth
        self.session = session
    }

    func profile() async throws -> GmailProfile { try await get("profile") }

    static func profile(accessToken: String, session: URLSession) async throws -> GmailProfile {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(GmailProfile.self, from: data)
    }

    func labels() async throws -> [GmailLabel] {
        struct Response: Decodable, Sendable { let labels: [GmailLabel] }
        let response: Response = try await get("labels")
        return response.labels
    }

    func messages(pageToken: String? = nil) async throws -> GmailMessagePage {
        try await get("messages", query: [URLQueryItem(name: "q", value: "newer_than:90d"),
                                          URLQueryItem(name: "includeSpamTrash", value: "true"),
                                          URLQueryItem(name: "maxResults", value: "100"),
                                          URLQueryItem(name: "pageToken", value: pageToken)].filter { $0.value != nil })
    }

    func message(id: String) async throws -> GmailMessage {
        var message: GmailMessage
        do { message = try await get("messages/\(Self.pathComponent(id))", query: [URLQueryItem(name: "format", value: "full")]) }
        catch let error as GmailHTTPError where error.status == 404 { throw GmailClientError.messageNotFound }
        message.payload = try await hydrateText(message.payload, messageId: id)
        return message
    }

    func messageState(id: String) async throws -> GmailMessageState {
        do { return try await get("messages/\(Self.pathComponent(id))", query: [URLQueryItem(name: "format", value: "minimal")]) }
        catch let error as GmailHTTPError where error.status == 404 { throw GmailClientError.messageNotFound }
    }

    func modify(id: String, add: [String], remove: [String]) async throws {
        struct Body: Encodable { let addLabelIds: [String]; let removeLabelIds: [String] }
        try await post("messages/\(Self.pathComponent(id))/modify", body: Body(addLabelIds: add, removeLabelIds: remove))
    }

    func trash(id: String) async throws { try await post("messages/\(Self.pathComponent(id))/trash") }
    func untrash(id: String) async throws { try await post("messages/\(Self.pathComponent(id))/untrash") }

    func history(start: String, pageToken: String? = nil) async throws -> GmailHistoryPage {
        let types = ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"].map { URLQueryItem(name: "historyTypes", value: $0) }
        do {
            return try await get("history", query: types + [URLQueryItem(name: "startHistoryId", value: start),
                                                           URLQueryItem(name: "pageToken", value: pageToken)].filter { $0.value != nil })
        } catch let error as GmailHTTPError where error.status == 404 { throw GmailClientError.historyExpired }
    }

    private func hydrateText(_ part: GmailPart, messageId: String) async throws -> GmailPart {
        var result = part
        if (part.mimeType == "text/plain" || part.mimeType == "text/html"), (part.filename ?? "").isEmpty,
           part.body?.data == nil, let id = part.body?.attachmentId {
            let body: GmailPart.Body = try await get("messages/\(Self.pathComponent(messageId))/attachments/\(Self.pathComponent(id))")
            result.body?.data = body.data
        }
        if let parts = part.parts {
            var hydrated: [GmailPart] = []
            for child in parts { hydrated.append(try await hydrateText(child, messageId: messageId)) }
            result.parts = hydrated
        }
        return result
    }

    private func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try JSONDecoder().decode(T.self, from: await request(method: "GET", path: path, query: query))
    }

    private func post<T: Encodable & Sendable>(_ path: String, body: T) async throws {
        do { _ = try await request(method: "POST", path: path, body: JSONEncoder().encode(body)) }
        catch let error as GmailHTTPError where error.status == 404 { throw GmailClientError.messageNotFound }
    }

    private func post(_ path: String) async throws {
        do { _ = try await request(method: "POST", path: path) }
        catch let error as GmailHTTPError where error.status == 404 { throw GmailClientError.messageNotFound }
    }

    private func request(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var token = try await oauth.accessToken(accountId: accountId)
        for attempt in 0...1 {
            try Task.checkCancellation()
            var request = URLRequest(url: components.url!)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 401, attempt == 0 {
                token = try await oauth.accessToken(accountId: accountId, rejecting: token)
                continue
            }
            try Self.validate(response, data: data)
            return data
        }
        throw OAuthError.signInRequired
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else { throw GmailHTTPError(status: response.statusCode, body: data) }
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
}
