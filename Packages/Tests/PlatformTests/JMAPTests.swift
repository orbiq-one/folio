import Data
import Domain
import Foundation
import Synchronization
import Testing
@testable import Platform

private actor SyncRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false

    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@Test(arguments: [false, true])
func jmapOutboxWaitsForInFlightSyncWithoutRecursion(failSync: Bool) async throws {
    let gate = SyncRequestGate()
    let sets = Mutex(0)
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, _) = try jmapCall(request)
        switch method {
        case "Mailbox/get":
            await gate.wait()
            if failSync { return (503, Foundation.Data()) }
            return try jmapReply(method, ["state": "m1", "list": []])
        case "Email/get": return try jmapReply(method, ["state": "e1", "list": []])
        case "Email/query": return try jmapReply(method, ["ids": [], "total": 0])
        case "Email/set":
            sets.withLock { $0 += 1 }
            return try jmapReply(method, ["updated": ["e": NSNull()]])
        default: throw JMAPError.invalidResponse
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    await sync.start()
    let clock = ContinuousClock()
    let entryDeadline = clock.now.advanced(by: .seconds(2))
    while !(await gate.entered), clock.now < entryDeadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.entered)
    try await repository.enqueue(.changeFlags(messageId: "e", flags: .read, enabled: true), accountId: "a")
    try await Task.sleep(for: .milliseconds(100))
    #expect(sets.withLock { $0 } == 0)
    await gate.release()
    let deadline = clock.now.advanced(by: .seconds(2))
    while try await repository.nextOutboxAction(accountId: "a") != nil, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(sets.withLock { $0 } == 1)
    await sync.stop()
}

@Test(arguments: [false, true])
func gmailOutboxWaitsForInFlightSyncWithoutRecursion(failSync: Bool) async throws {
    let gate = SyncRequestGate()
    let modifications = Mutex(0)
    let stub = HTTPStub { request in
        switch request.url?.lastPathComponent {
        case "labels":
            await gate.wait()
            if failSync { return (503, Foundation.Data()) }
            return (200, try json(["labels": []]))
        case "profile": return (200, try json(["emailAddress": "a@example.com", "historyId": "1"]))
        case "messages": return (200, try json(["messages": []]))
        case "modify":
            modifications.withLock { $0 += 1 }
            return (200, try json([:]))
        default: throw URLError(.badServerResponse)
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    let tokens = MemoryTokenStore(["a": OAuthTokens(accessToken: "token", refreshToken: "", expiresAt: .distantFuture)])
    let oauth = OAuthSession(clientId: "test", tokens: tokens, session: stub.session)
    let sync = GmailAccountSync(accountId: "a", client: GmailClient(accountId: "a", oauth: oauth, session: stub.session), repository: repository)
    await sync.start()
    let clock = ContinuousClock()
    let entryDeadline = clock.now.advanced(by: .seconds(2))
    while !(await gate.entered), clock.now < entryDeadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.entered)
    try await repository.enqueue(.changeFlags(messageId: "e", flags: .read, enabled: true), accountId: "a")
    try await Task.sleep(for: .milliseconds(100))
    #expect(modifications.withLock { $0 } == 0)
    await gate.release()
    let deadline = clock.now.advanced(by: .seconds(2))
    while try await repository.nextOutboxAction(accountId: "a") != nil, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(modifications.withLock { $0 } == 1)
    await sync.stop()
}

@Test func jmapSubmissionCreatesDraftUsesIdentityAndMovesToSent() async throws {
    let methods = Mutex<[String]>([])
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let object = try #require(try JSONSerialization.jsonObject(with: Foundation.Data(requestBody(request).utf8)) as? [String: Any])
        let call = try #require((object["methodCalls"] as? [[Any]])?.first)
        let name = try #require(call[0] as? String)
        let args = try #require(call[1] as? [String: Any])
        methods.withLock { $0.append(name) }
        switch name {
        case "Email/query": return try jmapReply(name, ["ids": []])
        case "Mailbox/get": return try jmapReply(name, ["state": "m", "list": [["id": "drafts", "name": "Drafts", "role": "drafts"], ["id": "sent", "name": "Sent", "role": "sent"]]])
        case "Identity/get":
            #expect((object["using"] as? [String])?.contains("urn:ietf:params:jmap:submission") == true)
            return try jmapReply(name, ["list": [["id": "identity", "email": "a@example.com"]]])
        case "Email/set":
            if let create = args["create"] as? [String: [String: Any]], let draft = create["draft"] {
                #expect(draft["keywords"] as? [String: Bool] == ["$draft": true])
                #expect(draft["mailboxIds"] as? [String: Bool] == ["drafts": true])
                #expect((draft["bodyValues"] as? [String: [String: String]])?["plain"]?["value"] == "Body")
                return try jmapReply(name, ["created": ["draft": ["id": "remote-draft"]]])
            }
            return try jmapReply(name, ["destroyed": args["destroy"] as? [String] ?? []])
        case "EmailSubmission/set":
            let create = try #require(args["create"] as? [String: [String: String]])
            #expect(create["submission"] == ["emailId": "remote-draft", "identityId": "identity"])
            let update = try #require((args["onSuccessUpdateEmail"] as? [String: [String: Any]])?["#submission"])
            #expect(update["mailboxIds"] as? [String: Bool] == ["sent": true])
            #expect(update["keywords/$draft"] is NSNull)
            return try jmapReply(name, ["created": ["submission": ["id": "submission-id"]]])
        default: throw JMAPError.invalidResponse
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    let message = Message(id: "local-draft:test", accountId: "a", threadId: "t", subject: "Test", sender: EmailAddress(address: "a@example.com"), to: [EmailAddress(address: "b@example.com")], date: .now, internetMessageId: "<test@example.com>", bodyId: "local-draft:test")
    try await repository.enqueue(.send(message: message, body: MessageBody(id: message.id, plainText: "Body", html: "<b>Body</b>"), attachments: []), accountId: "a")
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    try await sync.replayOutbox()
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(methods.withLock { $0.filter { $0 == "EmailSubmission/set" }.count } == 1)
    try await sync.replayOutbox()
    #expect(methods.withLock { $0.filter { $0 == "EmailSubmission/set" }.count } == 1)
    await sync.stop()
}

@Test func jmapUncertainSubmissionIsNotAutomaticallySentAgain() async throws {
    let repository = try await jmapRepository()
    let message = Message(id: "local-draft:test", accountId: "a", threadId: "t", subject: "Test", sender: EmailAddress(address: "a@example.com"), date: .now, bodyId: "local-draft:test")
    let row = try await repository.enqueue(.send(message: message, body: MessageBody(id: message.id), attachments: []), accountId: "a")
    try await repository.setSyncCursor("submitting", accountId: "a", scope: "compose-send:\(row)")
    let stub = HTTPStub { _ in Issue.record("Must not submit again"); throw JMAPError.invalidResponse }
    defer { stub.finish() }
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    await #expect(throws: SMTPError.self) { try await sync.replayOutbox() }
    #expect(try await repository.nextOutboxAction(accountId: "a")?.id == row)
    await sync.stop()
}

private let jmapSessionJSON = """
{"username":"a@example.com","apiUrl":"https://api.fastmail.com/jmap/api/","accounts":{"remote":{"name":"A","isPersonal":true}},"primaryAccounts":{"urn:ietf:params:jmap:mail":"remote"}}
"""

private func jmapEmail(_ id: String = "e", seen: Bool = true) -> [String: Any] {
    ["id": id, "threadId": id, "mailboxIds": ["inbox": true, "ignored": false],
     "keywords": ["$seen": seen, "$flagged": true, "$answered": true],
     "from": [["name": "Sender", "email": "sender@example.com"]],
     "to": [["email": "a@example.com"]], "subject": "Hello", "receivedAt": Date().ISO8601Format(),
     "messageId": ["message@example.com"], "references": ["parent@example.com"],
     "textBody": [["partId": "plain"]], "htmlBody": [["partId": "html"]],
     "bodyValues": ["plain": ["value": "Hello plain"], "html": ["value": "<p>Hello HTML</p>"]],
     "attachments": [["partId": "file", "blobId": "blob", "name": "file.pdf", "type": "application/pdf", "size": 42]]]
}

private func jmapReply(_ method: String, _ value: [String: Any]) throws -> (Int, Foundation.Data) {
    (200, try json(["methodResponses": [[method, value, "0"]]]))
}

private func jmapCall(_ request: URLRequest) throws -> (String, [String: Any]) {
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
    let object = try #require(try JSONSerialization.jsonObject(with: Foundation.Data(requestBody(request).utf8)) as? [String: Any])
    let calls = try #require(object["methodCalls"] as? [[Any]])
    let submission = (calls.first?[0] as? String)?.hasPrefix("Identity/") == true || (calls.first?[0] as? String)?.hasPrefix("EmailSubmission/") == true
    #expect(object["using"] as? [String] == ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"] + (submission ? ["urn:ietf:params:jmap:submission"] : []))
    let args = try #require(calls.first?[1] as? [String: Any])
    #expect(args["accountId"] as? String == "remote")
    return (try #require(calls.first?[0] as? String), args)
}

private func jmapClient(_ session: URLSession) -> JMAPClient {
    JMAPClient(accountId: "a", tokens: MemoryTokenStore(["a": OAuthTokens(accessToken: "token", refreshToken: "", expiresAt: .distantFuture)]), session: session)
}

private func jmapRepository() async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .jmap, displayName: "A", email: EmailAddress(address: "a@example.com")))
    return repository
}

@Test func jmapErrorsExplainRecoveryWithoutExposingCredentials() {
    let invalid = JMAPError.invalidResponse.localizedDescription
    #expect(invalid.contains("Fastmail"))
    #expect(invalid.localizedCaseInsensitiveContains("refresh"))
    #expect(!invalid.localizedCaseInsensitiveContains("bearer"))
    #expect(JMAPError.method("forbidden").localizedDescription.contains("read/write"))
}

@Test(arguments: [401, 403])
func jmapHTTPUnauthorizedMapsToActionableError(status: Int) async {
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        return (status, Foundation.Data())
    }
    defer { stub.finish() }
    await #expect(throws: FastmailError.unauthorized) {
        try await jmapClient(stub.session).mailboxes()
    }
}

@Test func jmapLoadsAndCachesSession() async throws {
    let requests = Mutex(0)
    let stub = HTTPStub { request in
        requests.withLock { $0 += 1 }
        #expect(request.url == FastmailClient.sessionURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        return (200, Foundation.Data(jmapSessionJSON.utf8))
    }
    defer { stub.finish() }
    let client = jmapClient(stub.session)
    #expect(try await client.loadSession().mailAccountId == "remote")
    #expect(try await client.loadSession().username == "a@example.com")
    #expect(requests.withLock { $0 } == 1)
}

@Test func jmapFullSyncMapsMailIntoSQLite() async throws {
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, args) = try jmapCall(request)
        switch method {
        case "Mailbox/get":
            return try jmapReply(method, ["state": "m1", "list": [["id": "inbox", "name": "Inbox", "role": "inbox"], ["id": "child", "name": "Child", "parentId": "inbox"]]])
        case "Email/query":
            #expect(args["position"] as? Int == 0)
            #expect((args["filter"] as? [String: String])?["after"] != nil)
            return try jmapReply(method, ["ids": ["e"], "total": 1])
        case "Email/get":
            #expect(args["fetchAllBodyValues"] as? Bool == true)
            #expect(args["maxBodyValueBytes"] as? Int == 1_048_576)
            return try jmapReply(method, ["state": "e1", "list": (args["ids"] as? [String]) == [] ? [] : [jmapEmail()]])
        default: throw JMAPError.invalidResponse
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    try await sync.synchronize()
    let thread = try #require(try await repository.thread(accountId: "a", threadId: "e"))
    let message = try #require(thread.messages.first)
    #expect(message.mailboxIds == ["inbox"])
    #expect(message.flags == [.read, .starred, .answered])
    #expect(message.sender.name == "Sender")
    #expect(message.internetMessageId == "<message@example.com>")
    #expect(thread.bodies["e"]?.plainText == "Hello plain")
    #expect(thread.bodies["e"]?.html == "<p>Hello HTML</p>")
    #expect(message.attachmentIds == ["e:file"])
    #expect(try await repository.mailboxes(accountId: "a").first { $0.id == "child" }?.parentId == "inbox")
    #expect(try await repository.syncCursor(accountId: "a", scope: "email") == "e1")
    #expect(try await repository.syncCursor(accountId: "a", scope: "mailbox") == "m1")
}

@Test func jmapIncrementalChangesPageAndDelete() async throws {
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, args) = try jmapCall(request)
        switch method {
        case "Mailbox/changes":
            #expect(args["sinceState"] as? String == "m0")
            return try jmapReply(method, ["newState": "m1", "hasMoreChanges": false, "created": ["inbox"], "updated": [], "destroyed": ["oldbox"]])
        case "Mailbox/get": return try jmapReply(method, ["state": "m1", "list": [["id": "inbox", "name": "Inbox", "role": "inbox"]]])
        case "Email/changes":
            let first = args["sinceState"] as? String == "e0"
            return try jmapReply(method, ["newState": first ? "e1" : "e2", "hasMoreChanges": first, "created": first ? ["e"] : [], "updated": first ? [] : ["e"], "destroyed": first ? ["deleted"] : []])
        case "Email/get": return try jmapReply(method, ["state": "e3", "list": [jmapEmail(seen: false)]])
        default: throw JMAPError.invalidResponse
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.upsert(Mailbox(id: "oldbox", accountId: "a", kind: .folder, name: "Old"))
    let deleted = try JMAPMapping.message(JSONDecoder().decode(JMAPEmail.self, from: json(jmapEmail("deleted"))), accountId: "a")
    try await repository.upsert(Mailbox(id: "inbox", accountId: "a", kind: .inbox, name: "Inbox"))
    try await repository.upsert(deleted.message, body: deleted.body, attachments: deleted.attachments)
    try await repository.setSyncCursor("m0", accountId: "a", scope: "mailbox")
    try await repository.setSyncCursor("e0", accountId: "a", scope: "email")
    try await JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository).synchronize()
    #expect(try await repository.messageIds(accountId: "a") == ["e"])
    #expect(try await repository.thread(accountId: "a", threadId: "e")?.messages.first?.flags.contains(.read) == false)
    #expect(try await repository.syncCursor(accountId: "a", scope: "email") == "e2")
    #expect(try await repository.mailboxes(accountId: "a").map(\.id) == ["inbox"])
}

@Test func jmapExpiredStatesFallBackToFullSync() async throws {
    let calls = Mutex<[String]>([])
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, _) = try jmapCall(request)
        calls.withLock { $0.append(method) }
        if method.hasSuffix("/changes") { return try jmapReply("error", ["type": "cannotCalculateChanges"]) }
        switch method {
        case "Mailbox/get": return try jmapReply(method, ["state": "m1", "list": []])
        case "Email/get": return try jmapReply(method, ["state": "e1", "list": []])
        case "Email/query": return try jmapReply(method, ["ids": [], "total": 0])
        default: throw JMAPError.invalidResponse
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.setSyncCursor("expired", accountId: "a", scope: "mailbox")
    try await repository.setSyncCursor("expired", accountId: "a", scope: "email")
    try await JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository).synchronize()
    #expect(calls.withLock { $0 } == ["Identity/get", "Mailbox/changes", "Mailbox/get", "Email/changes", "Email/get", "Email/query"])
    #expect(try await repository.syncCursor(accountId: "a", scope: "email") == "e1")
}

@Test func jmapOutboxFlagsAndMailboxPatches() async throws {
    let patches = Mutex<[String]>([])
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, args) = try jmapCall(request)
        #expect(method == "Email/set")
        let update = try #require(args["update"] as? [String: [String: Any]])
        let patch = try #require(update["e"])
        patches.withLock { $0.append(contentsOf: patch.keys) }
        if let seen = patch["keywords/$seen"] { #expect(seen is NSNull) }
        return try jmapReply(method, ["updated": ["e": NSNull()]])
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.enqueue(.changeFlags(messageId: "e", flags: [.read, .starred], enabled: false), accountId: "a")
    try await repository.enqueue(.addMailbox(messageId: "e", mailboxId: "a/b~c"), accountId: "a")
    try await repository.enqueue(.removeMailbox(messageId: "e", mailboxId: "old"), accountId: "a")
    try await repository.enqueue(.move(messageId: "e", fromMailboxId: "old", toMailboxId: "new"), accountId: "a")
    try await JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository).replayOutbox()
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(Set(patches.withLock { $0 }) == ["keywords/$seen", "keywords/$flagged", "mailboxIds/a~1b~0c", "mailboxIds/old", "mailboxIds/new"])
}

@Test func jmapFullSyncHandlesServerLimitedPages() async throws {
    let positions = Mutex<[Int]>([])
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, args) = try jmapCall(request)
        switch method {
        case "Mailbox/get": return try jmapReply(method, ["state": "m1", "list": [["id": "inbox", "name": "Inbox", "role": "inbox"]]])
        case "Email/query":
            let position = try #require(args["position"] as? Int)
            positions.withLock { $0.append(position) }
            return try jmapReply(method, ["ids": [position == 0 ? "a" : "b"], "total": 2])
        case "Email/get":
            let ids = try #require(args["ids"] as? [String])
            return try jmapReply(method, ["state": ids.isEmpty ? "before" : "after", "list": ids.map { jmapEmail($0) }])
        default: throw JMAPError.invalidResponse
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository).synchronize()
    #expect(positions.withLock { $0 } == [0, 1])
    #expect(try await repository.messageIds(accountId: "a") == ["a", "b"])
    #expect(try await repository.syncCursor(accountId: "a", scope: "email") == "before")
}

@Test func jmapIncompleteDownloadDoesNotAdvanceCursor() async throws {
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, _) = try jmapCall(request)
        switch method {
        case "Mailbox/changes": return try jmapReply(method, ["newState": "m1", "hasMoreChanges": false, "created": [], "updated": [], "destroyed": []])
        case "Email/changes": return try jmapReply(method, ["newState": "e1", "hasMoreChanges": false, "created": ["missing"], "updated": [], "destroyed": []])
        case "Email/get": return try jmapReply(method, ["state": "e1", "list": []])
        default: throw JMAPError.invalidResponse
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.setSyncCursor("m0", accountId: "a", scope: "mailbox")
    try await repository.setSyncCursor("e0", accountId: "a", scope: "email")
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    await #expect(throws: JMAPError.invalidResponse) { try await sync.synchronize() }
    #expect(try await repository.syncCursor(accountId: "a", scope: "email") == "e0")
}

@Test func jmapUnsupportedActionsAndStoppedSync() async throws {
    let stub = HTTPStub { _ in throw JMAPError.invalidResponse }
    defer { stub.finish() }
    let client = jmapClient(stub.session)
    let message = Message(id: "e", accountId: "a", threadId: "t", subject: "", sender: EmailAddress(address: "a@example.com"), date: .now)
    let body = MessageBody(id: "e")
    for action: OutboxAction in [.send(message: message, body: body, attachments: []), .saveDraft(message: message, body: body, attachments: []), .deleteDraft(messageId: "e")] {
        await #expect(throws: JMAPError.unsupportedAction) { try await client.replay(action) }
    }
    let sync = JMAPAccountSync(accountId: "a", client: client, repository: try await jmapRepository())
    await sync.stop()
    await #expect(throws: CancellationError.self) { try await sync.synchronize() }
}

@Test(arguments: [("inbox", MailboxKind.inbox), ("sent", .sent), ("drafts", .drafts), ("trash", .trash), ("junk", .spam), ("archive", .archive), ("flagged", .starred), ("custom", .folder)])
func jmapMailboxRoles(role: String, kind: MailboxKind) {
    let mapped = JMAPMapping.mailbox(JMAPMailbox(id: "m", name: "Mailbox", role: role, parentId: "parent"), accountId: "a")
    #expect(mapped.kind == kind)
    #expect(mapped.parentId == "parent")
}

@Test func jmapSetFailureKeepsOutboxAction() async throws {
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        return try jmapReply("Email/set", ["notUpdated": ["e": ["type": "forbidden"]]])
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.enqueue(.changeFlags(messageId: "e", flags: .read, enabled: true), accountId: "a")
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    await #expect(throws: JMAPError.method("forbidden")) { try await sync.replayOutbox() }
    #expect(try await repository.nextOutboxAction(accountId: "a") != nil)
}

@Test func jmapPermanentSetFailureDropsActionAndContinues() async throws {
    let calls = Mutex(0)
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (_, args) = try jmapCall(request)
        calls.withLock { $0 += 1 }
        let update = args["update"] as? [String: Any] ?? [:]
        if update["gone"] != nil { return try jmapReply("Email/set", ["notUpdated": ["gone": ["type": "invalidProperties", "description": "Email must belong to at least one mailbox"]]]) }
        if args["ids"] as? [String] == ["gone"] { return try jmapReply("Email/get", ["list": [], "notFound": ["gone"], "state": "e1"]) }
        return try jmapReply("Email/set", ["updated": ["e": NSNull()]])
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.enqueue(.removeMailbox(messageId: "gone", mailboxId: "inbox"), accountId: "a")
    try await repository.enqueue(.changeFlags(messageId: "e", flags: .read, enabled: true), accountId: "a")
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    await #expect(throws: JMAPError.method("invalidProperties")) { try await sync.replayOutbox() }
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(calls.withLock { $0 } == 3)
    await sync.stop()
}

@Test func jmapSyncBackfillsSenderNameFromIdentityWithoutOverridingUserChoice() async throws {
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, _) = try jmapCall(request)
        switch method {
        case "Identity/get": return try jmapReply("Identity/get", ["list": [["id": "i1", "email": "A@example.com", "name": "Ada Example"]]])
        case "Mailbox/get": return try jmapReply("Mailbox/get", ["list": [], "state": "m1"])
        case "Email/query": return try jmapReply("Email/query", ["ids": [], "queryState": "q1", "position": 0, "total": 0])
        case "Email/get": return try jmapReply("Email/get", ["list": [], "state": "e1"])
        default: return try jmapReply(method, ["list": [], "state": "s"])
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    try? await sync.synchronize()
    #expect(try await repository.accounts().first?.email.name == "Ada Example")
    try await repository.setSenderName("Custom", accountId: "a")
    try? await sync.synchronize()
    #expect(try await repository.accounts().first?.email.name == "Custom")
    try await repository.setSenderName("  ", accountId: "a")
    #expect(try await repository.accounts().first?.email.name == nil)
    try? await sync.synchronize()
    #expect(try await repository.accounts().first?.email.name == nil)
    await sync.stop()
}

@Test func jmapRejectedMutationRestoresRemoteMessageAndKeepsDueMutation() async throws {
    let updates = Mutex(0)
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, _) = try jmapCall(request)
        switch method {
        case "Email/set":
            if updates.withLock({ value in value += 1; return value }) == 1 {
                return try jmapReply(method, ["notUpdated": ["e": ["type": "invalidProperties"]]])
            }
            return try jmapReply(method, ["updated": ["e": NSNull()]])
        case "Email/get":
            var remote = jmapEmail("e", seen: false)
            remote["keywords"] = [String: Bool]()
            return try jmapReply(method, ["list": [remote], "state": "e1"])
        case "Mailbox/get": return try jmapReply(method, ["list": [["id": "inbox", "name": "Inbox", "role": "inbox"]], "state": "m1"])
        default: return try jmapReply(method, ["list": [], "state": "s"])
        }
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.upsert(Mailbox(id: "inbox", accountId: "a", kind: .inbox, name: "Inbox"))
    try await repository.upsert(Message(id: "e", accountId: "a", threadId: "e", subject: "", sender: EmailAddress(address: "sender@example.com"), date: .now, mailboxIds: ["inbox"]))
    try await repository.perform(.changeFlags(messageId: "e", flags: .read, enabled: true), accountId: "a")
    try await repository.perform(.changeFlags(messageId: "e", flags: .starred, enabled: true), accountId: "a")
    try await repository.enqueue(.changeFlags(messageId: "e", flags: .answered, enabled: true), accountId: "a",
                                 notBefore: .now.addingTimeInterval(3_600))
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    await #expect(throws: JMAPError.method("invalidProperties")) { try await sync.replayOutbox() }
    let restored = try #require(try await repository.thread(accountId: "a", threadId: "e")?.messages.first)
    #expect(restored.flags.contains(.starred))
    #expect(!restored.flags.contains(.read))
    #expect(try await repository.nextOutboxAction(accountId: "a", now: .now.addingTimeInterval(3_600))?.action ==
            .changeFlags(messageId: "e", flags: .answered, enabled: true))
    #expect(!restored.flags.contains(.answered))
    await sync.stop()
}

@Test func jmapRejectedMutationRetainsActionWhenRefetchFails() async throws {
    let retry = Mutex(false)
    let stub = HTTPStub { request in
        if request.url == FastmailClient.sessionURL { return (200, Foundation.Data(jmapSessionJSON.utf8)) }
        let (method, _) = try jmapCall(request)
        if method == "Email/set" { return try jmapReply(method, ["notUpdated": ["e": ["type": "invalidProperties"]]]) }
        if method == "Email/get" && !retry.withLock({ $0 }) { throw JMAPError.invalidResponse }
        if method == "Email/get" { return try jmapReply(method, ["list": [], "notFound": ["e"], "state": "e1"]) }
        return try jmapReply(method, ["list": [], "state": "s"])
    }
    defer { stub.finish() }
    let repository = try await jmapRepository()
    try await repository.enqueue(.changeFlags(messageId: "e", flags: .read, enabled: true), accountId: "a")
    let sync = JMAPAccountSync(accountId: "a", client: jmapClient(stub.session), repository: repository)
    await #expect(throws: (any Error).self) { try await sync.replayOutbox() }
    #expect(try await repository.nextOutboxAction(accountId: "a") != nil)
    retry.withLock { $0 = true }
    await #expect(throws: JMAPError.method("invalidProperties")) { try await sync.replayOutbox() }
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    await sync.stop()
}
