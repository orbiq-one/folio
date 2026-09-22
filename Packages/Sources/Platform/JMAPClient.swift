import Foundation
import OSLog
import Domain

struct JMAPMailbox: Decodable, Sendable {
    let id: String
    let name: String
    let role: String?
    let parentId: String?
}

struct JMAPEmail: Decodable, Sendable {
    struct Address: Decodable, Sendable { let name: String?; let email: String }
    struct Part: Decodable, Sendable {
        let partId: String?
        let blobId: String?
        let name: String?
        let type: String?
        let size: Int64?
    }
    struct BodyValue: Decodable, Sendable { let value: String }
    let id: String
    let threadId: String
    let mailboxIds: [String: Bool]
    let keywords: [String: Bool]
    let from: [Address]?
    let to: [Address]?
    let cc: [Address]?
    let bcc: [Address]?
    let replyTo: [Address]?
    let subject: String?
    let receivedAt: String
    let sentAt: String?
    let messageId: [String]?
    let inReplyTo: [String]?
    let references: [String]?
    let bodyValues: [String: BodyValue]?
    let textBody: [Part]?
    let htmlBody: [Part]?
    let attachments: [Part]?
    let listUnsubscribe: String?
    let listId: String?
    let precedence: String?
    let autoSubmitted: String?
    let autoResponseSuppress: String?
    let feedbackId: String?

    enum CodingKeys: String, CodingKey {
        case id, threadId, mailboxIds, keywords, from, to, cc, bcc, replyTo, subject, receivedAt, sentAt, messageId,
             inReplyTo, references, bodyValues, textBody, htmlBody, attachments
        case listUnsubscribe = "header:List-Unsubscribe"
        case listId = "header:List-Id:asText"
        case precedence = "header:Precedence:asText"
        case autoSubmitted = "header:Auto-Submitted:asText"
        case autoResponseSuppress = "header:X-Auto-Response-Suppress:asText"
        case feedbackId = "header:Feedback-ID:asText"
    }
}

struct JMAPGet<Value: Decodable & Sendable>: Decodable, Sendable {
    let state: String
    let list: [Value]
    let notFound: [String]?
}

struct JMAPQuery: Decodable, Sendable { let ids: [String]; let total: Int? }
struct JMAPChanges: Decodable, Sendable {
    let newState: String
    let hasMoreChanges: Bool
    let created: [String]
    let updated: [String]
    let destroyed: [String]
}

enum JMAPError: LocalizedError, Equatable {
    case missingToken
    case invalidResponse
    case method(String)
    case unsupportedAction

    /// Retrying can never succeed for these; the outbox drops the action instead of blocking the queue.
    var isPermanent: Bool {
        if case .method(let type) = self { return ["invalidProperties", "invalidPatch", "invalidArguments", "notFound"].contains(type) }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Fastmail sign-in is missing. Remove this account and add it again with a current API token."
        case .invalidResponse:
            "Fastmail returned a response Folio could not read. Try Refresh. If this continues, verify the API token has Mail access and report the time of the failure."
        case .method(let type):
            switch type {
            case "forbidden", "accountNotFound":
                "Fastmail denied mail access. Verify this API token has Mail access (and read/write access for drafts and message actions), then refresh."
            case "cannotCalculateChanges":
                "Fastmail's sync state expired while Folio was rebuilding the local mail index. Try Refresh again."
            case "invalidArguments", "invalidProperties", "invalidPatch":
                "Fastmail rejected a mail change. The change was dropped; refresh to reload the message."
            case "notFound":
                "Fastmail no longer has a message this change referred to. The change was dropped."
            case "serverFail", "serverError":
                "Fastmail reported a temporary server error. Try Refresh again later."
            default:
                "Fastmail could not complete mail sync. Try Refresh. If this continues, verify the API token has Mail access and report the time of the failure."
            }
        case .unsupportedAction:
            "This Fastmail action is not supported."
        }
    }
}

public actor JMAPClient {
    private static let log = Logger(subsystem: "re.leob.Folio", category: "jmap")
    private let accountId: String
    private let tokens: any TokenStore
    private let session: URLSession
    private var loadedSession: JMAPSession?

    public init(accountId: String, tokens: any TokenStore, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.accountId = accountId
        self.tokens = tokens
        self.session = session
    }

    func loadSession() async throws -> JMAPSession {
        if let loadedSession { return loadedSession }
        guard let token = try await tokens.load(accountId: accountId)?.accessToken else { throw JMAPError.missingToken }
        let value = try await FastmailClient.session(token: token, session: session)
        loadedSession = value
        return value
    }

    struct Identity: Decodable, Sendable { let id: String; let email: String; let name: String? }

    func identities() async throws -> [Identity] {
        struct Identities: Decodable { let list: [Identity] }
        let result: Identities = try await call("Identity/get", arguments: [:], submission: true)
        return result.list
    }

    func mailboxes() async throws -> JMAPGet<JMAPMailbox> {
        try await call("Mailbox/get", arguments: [:])
    }

    func emails(ids: [String]) async throws -> JMAPGet<JMAPEmail> {
        try await call("Email/get", arguments: [
            "ids": ids,
            "properties": ["id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "bcc", "replyTo", "subject", "receivedAt", "sentAt", "messageId", "inReplyTo", "references", "hasAttachment", "preview", "bodyValues", "textBody", "htmlBody", "attachments",
                           "header:List-Unsubscribe", "header:List-Id:asText", "header:Precedence:asText",
                           "header:Auto-Submitted:asText", "header:X-Auto-Response-Suppress:asText", "header:Feedback-ID:asText"],
            "fetchAllBodyValues": true, "maxBodyValueBytes": 1_048_576
        ])
    }

    func query(after: Date, position: Int, limit: Int = 100) async throws -> JMAPQuery {
        try await call("Email/query", arguments: ["filter": ["after": after.ISO8601Format()],
            "sort": [["property": "receivedAt", "isAscending": false]],
            "position": position, "limit": limit, "calculateTotal": true])
    }

    func changes(kind: String, since: String) async throws -> JMAPChanges {
        try await call("\(kind)/changes", arguments: ["sinceState": since, "maxChanges": 500])
    }

    func replay(_ action: OutboxAction) async throws {
        var patch: [String: Any] = [:]
        let id: String
        func path(_ value: String) -> String { value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
        switch action {
        case .changeFlags(let message, let flags, let enabled):
            id = message
            for (flag, keyword) in [(MessageFlags.read, "$seen"), (.starred, "$flagged"), (.answered, "$answered"), (.draft, "$draft")] where flags.contains(flag) {
                patch["keywords/\(keyword)"] = enabled ? true : NSNull()
            }
        case .addMailbox(let message, let mailbox):
            id = message; patch["mailboxIds/\(path(mailbox))"] = true
        case .removeMailbox(let message, let mailbox):
            id = message; patch["mailboxIds/\(path(mailbox))"] = NSNull()
        case .move(let message, let from, let to):
            id = message
            if from != to { patch["mailboxIds/\(path(from))"] = NSNull(); patch["mailboxIds/\(path(to))"] = true }
        case .send, .saveDraft, .deleteDraft: throw JMAPError.unsupportedAction
        }
        guard !patch.isEmpty else { return }
        let result: SetResult = try await call("Email/set", arguments: ["update": [id: patch]])
        if let error = result.notUpdated?[id] {
            Self.log.error("Email/set update failed: \(error.type, privacy: .public) \(error.description ?? "", privacy: .public) patch=\(Array(patch.keys).sorted().joined(separator: ","), privacy: .public)")
            throw JMAPError.method(error.type)
        }
        guard result.updated?.keys.contains(id) == true else { throw JMAPError.invalidResponse }
    }

    func createDraft(message: Message, body: MessageBody, attachments: [Attachment]) async throws -> String {
        guard attachments.isEmpty, message.attachmentIds.isEmpty else { throw MIMEWriter.Failure.missingAttachmentData }
        if let messageID = message.internetMessageId {
            let found: JMAPQuery = try await call("Email/query", arguments: ["filter": ["header": ["Message-ID", messageID]], "limit": 1])
            if let id = found.ids.first { return id }
        }
        let mailboxes = try await mailboxes()
        guard let drafts = mailboxes.list.first(where: { $0.role == "drafts" })?.id else { throw JMAPError.method("Drafts mailbox unavailable") }
        func addresses(_ values: [EmailAddress]) -> [[String: String]] { values.map { ["email": $0.address, "name": $0.name ?? ""] } }
        func ids(_ values: [String]) -> [String] { values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) } }
        var email: [String: Any] = ["mailboxIds": [drafts: true], "keywords": ["$draft": true],
            "from": addresses([message.sender]), "to": addresses(message.to), "cc": addresses(message.cc), "bcc": addresses(message.bcc),
            "subject": message.subject, "sentAt": message.date.ISO8601Format(),
            "textBody": [["partId": "plain", "type": "text/plain"]], "htmlBody": [["partId": "html", "type": "text/html"]],
            "bodyValues": ["plain": ["value": body.plainText ?? ""], "html": ["value": body.html ?? ""]]]
        if !message.replyTo.isEmpty { email["replyTo"] = addresses(message.replyTo) }
        if let id = message.internetMessageId { email["messageId"] = ids([id]) }
        if let id = message.inReplyTo { email["inReplyTo"] = ids([id]) }
        if !message.references.isEmpty { email["references"] = ids(message.references) }
        let result: CreationResult = try await call("Email/set", arguments: ["create": ["draft": email]])
        if let failure = result.notCreated?["draft"] {
            Self.log.error("Email/set create failed: \(failure.type, privacy: .public) \(failure.description ?? "", privacy: .public)")
            throw JMAPError.method(failure.type)
        }
        guard let id = result.created?["draft"]?.id else { throw JMAPError.invalidResponse }
        return id
    }

    func submit(emailId: String, sender: EmailAddress) async throws {
        guard let identity = try await identities().first(where: { $0.email.caseInsensitiveCompare(sender.address) == .orderedSame }) else { throw JMAPError.method("No matching sending identity") }
        let boxes = try await mailboxes()
        guard let sent = boxes.list.first(where: { $0.role == "sent" })?.id else { throw JMAPError.method("Sent mailbox unavailable") }
        let result: CreationResult = try await call("EmailSubmission/set", arguments: [
            "create": ["submission": ["emailId": emailId, "identityId": identity.id]],
            "onSuccessUpdateEmail": ["#submission": ["mailboxIds": [sent: true], "keywords/$draft": NSNull()]]
        ], submission: true)
        if let error = result.notCreated?["submission"] { throw JMAPError.method(error.type) }
        guard result.created?["submission"] != nil else { throw JMAPError.invalidResponse }
    }

    func destroyDraft(id: String) async throws {
        struct DestroyResult: Decodable { let destroyed: [String]?; let notDestroyed: [String: SetResult.Failure]? }
        let result: DestroyResult = try await call("Email/set", arguments: ["destroy": [id]])
        if let error = result.notDestroyed?[id], error.type != "notFound" { throw JMAPError.method(error.type) }
        guard result.destroyed?.contains(id) == true || result.notDestroyed?[id]?.type == "notFound" else { throw JMAPError.invalidResponse }
    }

    private struct CreationResult: Decodable {
        struct Created: Decodable { let id: String }
        let created: [String: Created]?
        let notCreated: [String: SetResult.Failure]?
    }

    private struct SetResult: Decodable {
        struct Failure: Decodable { let type: String; let description: String? }
        struct Updated: Decodable {}
        let updated: [String: Updated?]?
        let notUpdated: [String: Failure]?
    }

    private func call<Result: Decodable>(_ name: String, arguments: [String: Any], submission: Bool = false) async throws -> Result {
        let info = try await loadSession()
        guard let remoteId = info.mailAccountId, let url = URL(string: info.apiUrl), url.scheme == "https" else { throw JMAPError.invalidResponse }
        guard let token = try await tokens.load(accountId: accountId)?.accessToken else { throw JMAPError.missingToken }
        var args = arguments
        args["accountId"] = remoteId
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"] + (submission ? ["urn:ietf:params:jmap:submission"] : []), "methodCalls": [[name, args, "0"]]])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 || status == 403 { throw FastmailError.unauthorized }
            throw FastmailError.http(status)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = object["methodResponses"] as? [[Any]], let result = responses.first,
              result.count == 3, result[2] as? String == "0", let payload = result[1] as? [String: Any] else { throw JMAPError.invalidResponse }
        if result[0] as? String == "error" {
            let type = payload["type"] as? String ?? "unknown"
            let detail = (payload["description"] as? String) ?? (payload["arguments"] as? [String])?.joined(separator: ",") ?? ""
            Self.log.error("\(name, privacy: .public) failed: \(type, privacy: .public) \(detail, privacy: .public) args=\(Array(args.keys).sorted().joined(separator: ","), privacy: .public)")
            throw JMAPError.method(type)
        }
        guard result[0] as? String == name else { throw JMAPError.invalidResponse }
        return try JSONDecoder().decode(Result.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
