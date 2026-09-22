import Data
import Domain
import Foundation
import Synchronization
import Testing
@testable import Platform

@Test func pkceMatchesRFC7636AndUsesSecureRandomVerifiers() throws {
    let known = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    #expect(known.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let first = try PKCE()
    let second = try PKCE()
    #expect(first.verifier.count == 43)
    #expect(first.verifier != second.verifier)
    #expect(first.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
}

@Test func oauthConfigurationAndCallbackValidation() async throws {
    let oauth = OAuthSession(clientId: "123-test.apps.googleusercontent.com", tokens: MemoryTokenStore())
    let (url, redirect, state, pkce) = try await oauth.authorizationRequest()
    #expect(redirect == "com.googleusercontent.apps.123-test:/oauth2redirect")
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(query.contains(URLQueryItem(name: "code_challenge", value: pkce.challenge)))
    #expect(query.contains(URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.modify")))
    #expect(try OAuthSession.authorizationCode(URL(string: "\(redirect)?state=\(state)&code=abc")!, redirect: redirect, state: state) == "abc")
    #expect(throws: (any Error).self) {
        try OAuthSession.authorizationCode(URL(string: "\(redirect)?state=wrong&code=abc")!, redirect: redirect, state: state)
    }
    #expect(throws: (any Error).self) {
        try OAuthSession.authorizationCode(URL(string: "\(redirect)?state=\(state)&state=wrong&code=abc")!, redirect: redirect, state: state)
    }
    await #expect(throws: (any Error).self) {
        try await OAuthSession(clientId: "", tokens: MemoryTokenStore()).authorizationRequest()
    }
}

@Test func clientRefreshesOnceOn401AndPersistsRotatedTokens() async throws {
    let calls = Mutex<[String]>([])
    let stub = HTTPStub { request in
        let path = request.url!.path
        calls.withLock { $0.append(path) }
        if path == "/token" {
            let body = requestBody(request)
            #expect(body.contains("refresh_token=r%2B%26"))
            #expect(body.contains("grant_type=refresh_token"))
            return (200, try json(["access_token": "new", "refresh_token": "rotated", "expires_in": 3600]))
        }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" { return (401, try json([:])) }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new")
        return (200, try json(["labels": [["id": "INBOX", "name": "Inbox", "type": "system"]]]))
    }
    defer { stub.finish() }
    let tokens = MemoryTokenStore(["a": OAuthTokens(accessToken: "old", refreshToken: "r+&", expiresAt: .distantFuture)])
    let oauth = OAuthSession(clientId: "test.apps.googleusercontent.com", tokens: tokens, session: stub.session)
    let client = GmailClient(accountId: "a", oauth: oauth, session: stub.session)
    #expect(try await client.labels().map(\.id) == ["INBOX"])
    #expect(calls.withLock { $0.filter { $0 == "/token" }.count } == 1)
    #expect(await tokens.load(accountId: "a")?.refreshToken == "rotated")
    #expect(await tokens.load(accountId: "a")?.accessToken == "new")
}

@Test func expiredTokensRefreshWithoutLosingRefreshToken() async throws {
    let count = Mutex(0)
    let stub = HTTPStub { request in
        #expect(request.url?.path == "/token")
        count.withLock { $0 += 1 }
        return (200, try json(["access_token": "new", "expires_in": 3600]))
    }
    defer { stub.finish() }
    let tokens = MemoryTokenStore(["a": OAuthTokens(accessToken: "old", refreshToken: "keep", expiresAt: .distantPast)])
    let oauth = OAuthSession(clientId: "test.apps.googleusercontent.com", tokens: tokens, session: stub.session)
    try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<10 { group.addTask { try await oauth.accessToken(accountId: "a") } }
        for try await token in group { #expect(token == "new") }
    }
    #expect(count.withLock { $0 } == 1)
    #expect(await tokens.load(accountId: "a")?.refreshToken == "keep")
}

@Test func tokenErrorsDistinguishRevocationFromTransientFailures() async throws {
    let cases = [(400, "invalid_grant", true), (401, "invalid_client", true), (503, "invalid_grant", false),
                 (400, "invalid_request", false), (401, "unauthorized", false), (429, "rate_limit", false)]
    for (status, code, requiresSignIn) in cases {
        let stub = HTTPStub { _ in (status, try json(["error": code])) }
        defer { stub.finish() }
        let tokens = MemoryTokenStore(["a": OAuthTokens(accessToken: "old", refreshToken: "keep", expiresAt: .distantPast)])
        let oauth = OAuthSession(clientId: "test.apps.googleusercontent.com", tokens: tokens, session: stub.session)
        let repository = try await seededRepository()
        let sync = GmailAccountSync(accountId: "a", client: GmailClient(accountId: "a", oauth: oauth, session: stub.session), repository: repository)
        do { try await sync.synchronize(); Issue.record("Expected a token error") }
        catch {
            #expect((error.localizedDescription == OAuthError.signInRequired.localizedDescription) == requiresSignIn)
            var statuses = sync.status.makeAsyncIterator()
            #expect(await statuses.next() == .error(error.localizedDescription))
        }
        #expect(await tokens.load(accountId: "a")?.refreshToken == "keep")
        #expect(await tokens.load(accountId: "a")?.accessToken == "old")
        #expect(await tokens.saves == 0)
    }
}

@Test func offlineTokenRefreshPreservesCredentials() async throws {
    let stub = HTTPStub { _ in throw URLError(.notConnectedToInternet) }
    defer { stub.finish() }
    let tokens = MemoryTokenStore(["a": OAuthTokens(accessToken: "old", refreshToken: "keep", expiresAt: .distantPast)])
    let oauth = OAuthSession(clientId: "test.apps.googleusercontent.com", tokens: tokens, session: stub.session)
    await #expect(throws: URLError.self) { try await oauth.accessToken(accountId: "a") }
    #expect(await tokens.load(accountId: "a")?.refreshToken == "keep")
    #expect(await tokens.saves == 0)
}

@Test func multipartMappingDecodesNestedBodiesAndListsAttachments() throws {
    let object: [String: Any] = [
        "id": "m", "threadId": "t", "internalDate": "1700000000000", "labelIds": ["INBOX", "UNREAD", "STARRED"],
        "payload": ["mimeType": "multipart/mixed", "headers": [
            ["name": "From", "value": "\"Doe, Jane\" <jane@example.com>"], ["name": "Subject", "value": "Hello"],
            ["name": "To", "value": "One <one@example.com>, two@example.com"]
        ], "parts": [
            ["mimeType": "multipart/alternative", "parts": [
                ["mimeType": "text/plain", "body": ["data": PKCE.base64URL(Foundation.Data("Hello 🌍".utf8))]],
                ["mimeType": "text/html", "body": ["data": Foundation.Data("<p>Hello</p>".utf8).base64EncodedString()]]
            ]],
            ["mimeType": "text/plain", "partId": "2", "filename": "notes.txt", "body": ["size": 12, "attachmentId": "file"]]
        ]]
    ]
    let source = try JSONDecoder().decode(GmailMessage.self, from: json(object))
    let mapped = try GmailMapping.message(source, accountId: "a")
    #expect(mapped.body.plainText == "Hello 🌍")
    #expect(mapped.body.html == "<p>Hello</p>")
    #expect(mapped.message.sender == EmailAddress(address: "jane@example.com", name: "Doe, Jane"))
    #expect(mapped.message.to.count == 2)
    #expect(mapped.message.threadId == "t")
    #expect(mapped.message.flags == .starred)
    #expect(mapped.message.mailboxIds == ["INBOX", "STARRED"])
    #expect(mapped.attachments.map(\.filename) == ["notes.txt"])
    #expect(try GmailMapping.decodeBase64URL("-_8") == Foundation.Data([251, 255]))
    #expect(try GmailMapping.decodeBase64URL("-_8=") == Foundation.Data([251, 255]))
    #expect(throws: (any Error).self) { try GmailMapping.decodeBase64URL("not base64!") }
}

@Test func payloadUsesItsDeclaredCharset() throws {
    let data = try json(["id": "m", "threadId": "t", "internalDate": "1700000000000",
                         "payload": ["mimeType": "text/plain", "headers": [["name": "Content-Type", "value": "text/plain; charset=\"windows-1252\""]],
                                     "body": ["data": PKCE.base64URL(Foundation.Data([0x80]))]]])
    let mapped = try GmailMapping.message(JSONDecoder().decode(GmailMessage.self, from: data), accountId: "a")
    #expect(mapped.body.plainText == "€")
}

@Test func systemAndUserLabelMapping() {
    let cases: [(String, MailboxKind)] = [("INBOX", .inbox), ("SENT", .sent), ("DRAFT", .drafts), ("TRASH", .trash),
                                         ("SPAM", .spam), ("STARRED", .starred), ("IMPORTANT", .label),
                                         ("CATEGORY_SOCIAL", .label), ("Label_1", .label)]
    for (id, kind) in cases {
        #expect(GmailMapping.mailbox(GmailLabel(id: id, name: id, type: nil), accountId: "a")?.kind == kind)
    }
    #expect(GmailMapping.mailbox(GmailLabel(id: "UNREAD", name: "Unread", type: "system"), accountId: "a") == nil)
    #expect(GmailMapping.capabilities == [.labels, .serverSearch, .drafts, .sendAs, .spamActions])
}

@Test func labelVisibilityAndParentsAreMappedWithoutDroppingMemberships() throws {
    let labels = try JSONDecoder().decode([GmailLabel].self, from: json([
        ["id": "child", "name": "Work/Team", "type": "user"],
        ["id": "parent", "name": "Work", "type": "user"],
        ["id": "hidden", "name": "Hidden", "type": "user", "labelListVisibility": "labelHide"],
        ["id": "CATEGORY_SOCIAL", "name": "Social", "type": "system"],
        ["id": "CHAT", "name": "Chat", "type": "system"],
        ["id": "IMPORTANT", "name": "Important", "type": "system"],
        ["id": "orphan", "name": "Missing/Child", "type": "user"]
    ]))
    let mailboxes = GmailMapping.mailboxes(labels, accountId: "a")
    #expect(mailboxes.first { $0.id == "child" }?.parentId == "parent")
    #expect(mailboxes.firstIndex { $0.id == "parent" }! < mailboxes.firstIndex { $0.id == "child" }!)
    #expect(mailboxes.filter(\.isHidden).map(\.id).sorted() == ["CATEGORY_SOCIAL", "CHAT", "hidden"])
    #expect(mailboxes.first { $0.id == "IMPORTANT" }?.isHidden == false)
    #expect(mailboxes.first { $0.id == "IMPORTANT" }?.isSystem == true)
    #expect(mailboxes.first { $0.id == "orphan" }?.parentId == nil)
    #expect(mailboxes.count == labels.count)
}

private func gmailMessage(_ id: String, labels: [String] = ["INBOX"]) -> [String: Any] {
    ["id": id, "threadId": id, "internalDate": String(Int64(Date().timeIntervalSince1970 * 1000)), "labelIds": labels,
     "payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": id]],
                 "body": ["data": PKCE.base64URL(Foundation.Data("Body \(id)".utf8))]]]
}

private func seededRepository() async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "a@example.com")))
    try await repository.upsert(Mailbox(id: "INBOX", accountId: "a", kind: .inbox, name: "Inbox"))
    try await repository.upsert(Mailbox(id: "Label_1", accountId: "a", kind: .label, name: "Label"))
    for id in ["deleted", "tagged", "untagged"] {
        let mapped = try GmailMapping.message(JSONDecoder().decode(GmailMessage.self, from: json(gmailMessage(id, labels: ["INBOX", "Label_1"]))), accountId: "a")
        try await repository.upsert(mapped.message, body: mapped.body)
    }
    return repository
}

private func sync(repository: SQLiteMailRepository, session: URLSession) -> GmailAccountSync {
    let oauth = OAuthSession(clientId: "test.apps.googleusercontent.com",
                             tokens: MemoryTokenStore(["a": OAuthTokens(accessToken: "test", refreshToken: "refresh", expiresAt: .distantFuture)]), session: session)
    return GmailAccountSync(accountId: "a", client: GmailClient(accountId: "a", oauth: oauth, session: session), repository: repository)
}

private let labelsResponse: [[String: String]] = [["id": "INBOX", "name": "Inbox"], ["id": "Label_1", "name": "Label"]]

@Test func historyAppliesAddDeleteAndLabelChangesAcrossPages() async throws {
    let stub = HTTPStub { request in
        let url = request.url!
        switch url.lastPathComponent {
        case "labels": return (200, try json(["labels": labelsResponse]))
        case "history":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(URLQueryItem(name: "startHistoryId", value: "10")))
            #expect(query.filter { $0.name == "historyTypes" }.count == 4)
            if query.contains(URLQueryItem(name: "pageToken", value: "next")) {
                return (200, try json(["historyId": "20", "history": [["messagesDeleted": [["message": ["id": "deleted"]]],
                                                                      "labelsRemoved": [["message": ["id": "untagged"], "labelIds": ["Label_1"]]]]]]))
            }
            return (200, try json(["historyId": "20", "nextPageToken": "next", "history": [
                ["messagesAdded": [["message": ["id": "added"]]], "labelsAdded": [["message": ["id": "tagged"], "labelIds": ["Label_1"]]]]
            ]]))
        case "deleted": return (404, try json([:]))
        case "tagged": return (200, try json(gmailMessage("tagged", labels: ["INBOX", "Label_1", "UNREAD"])))
        case "added", "untagged": return (200, try json(gmailMessage(url.lastPathComponent)))
        default: throw URLError(.unsupportedURL)
        }
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    try await repository.setSyncCursor("10", accountId: "a")
    let sync = sync(repository: repository, session: stub.session)
    try await sync.synchronize()
    #expect(try await repository.thread(accountId: "a", threadId: "deleted") == nil)
    #expect(try await repository.thread(accountId: "a", threadId: "added")?.bodies["added"]?.plainText == "Body added")
    #expect(try await repository.thread(accountId: "a", threadId: "tagged")?.messages.first?.flags.isEmpty == true)
    #expect(try await repository.threads(in: .mailbox(accountId: "a", mailboxId: "Label_1")).map(\.id) == ["tagged"])
    #expect(try await repository.syncCursor(accountId: "a") == "20")
}

@Test func staleHistoryFallsBackToPaginatedFullSyncAndReconcilesDeletedMail() async throws {
    let stub = HTTPStub { request in
        let url = request.url!
        switch url.lastPathComponent {
        case "labels": return (200, try json(["labels": labelsResponse]))
        case "history": return (404, try json([:]))
        case "profile": return (200, try json(["emailAddress": "a@example.com", "historyId": "30"]))
        case "messages":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(URLQueryItem(name: "q", value: "newer_than:90d")))
            #expect(query.contains(URLQueryItem(name: "includeSpamTrash", value: "true")))
            if query.contains(URLQueryItem(name: "pageToken", value: "next")) {
                return (200, try json(["messages": [["id": "second"]]]))
            }
            return (200, try json(["messages": [["id": "tagged"]], "nextPageToken": "next"]))
        case "tagged":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(URLQueryItem(name: "format", value: "minimal")))
            return (200, try json(["id": "tagged", "labelIds": ["INBOX", "UNREAD"]]))
        case "second":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(URLQueryItem(name: "format", value: "full")))
            return (200, try json(gmailMessage("second")))
        default: throw URLError(.unsupportedURL)
        }
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    try await repository.setSyncCursor("stale", accountId: "a")
    let sync = sync(repository: repository, session: stub.session)
    try await sync.synchronize()
    #expect(Set(try await repository.threads(in: .unified(.inbox)).map(\.id)) == ["tagged", "second"])
    let retained = try #require(try await repository.thread(accountId: "a", threadId: "tagged"))
    #expect(retained.bodies["tagged"]?.plainText == "Body tagged")
    #expect(retained.messages.first?.flags.isEmpty == true)
    #expect(retained.messages.first?.mailboxIds == ["INBOX"])
    #expect(try await repository.syncCursor(accountId: "a") == "30")
}

@Test(.timeLimit(.minutes(1))) func fullSyncReportsProgressAfterEachBatch() async throws {
    let gates = [10: DispatchSemaphore(value: 0), 20: DispatchSemaphore(value: 0)]
    let ids = (0..<25).map { String(format: "m%02d", $0) }
    let stub = HTTPStub { request in
        let id = request.url!.lastPathComponent
        switch id {
        case "labels": return (200, try json(["labels": labelsResponse]))
        case "profile": return (200, try json(["emailAddress": "a@example.com", "historyId": "30"]))
        case "messages": return (200, try json(["messages": ids.map { ["id": $0] }]))
        default:
            if id == "m10" || id == "m20" {
                let completed = Int(id.dropFirst())!
                #expect(gates[completed]!.wait(timeout: .now() + 5) == .success)
            }
            return (200, try json(gmailMessage(id)))
        }
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    let sync = sync(repository: repository, session: stub.session)
    let observation = Task {
        var progress: [SyncProgress] = []
        var started = false
        for await status in sync.status {
            if status.isSyncing { started = true }
            if case .syncing(let value?) = status {
                progress.append(value)
                gates[value.completed]?.signal()
            }
            if status == .idle, started { return progress }
        }
        return progress
    }
    defer { observation.cancel() }
    try await sync.synchronize()
    let progress = await observation.value
    #expect(progress.contains(SyncProgress(completed: 10, total: 25)))
    #expect(progress.contains(SyncProgress(completed: 20, total: 25)))
    #expect(progress.allSatisfy { $0.total == 25 && $0.completed <= 25 })
}

@Test func failedHistoryDoesNotAdvanceCursor() async throws {
    let stub = HTTPStub { request in
        switch request.url!.lastPathComponent {
        case "labels": return (200, try json(["labels": labelsResponse]))
        case "history": return (200, try json(["historyId": "20", "history": [["messagesAdded": [["message": ["id": "failed"]]]]]]))
        default: return (500, try json([:]))
        }
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    try await repository.setSyncCursor("10", accountId: "a")
    let sync = sync(repository: repository, session: stub.session)
    await #expect(throws: (any Error).self) { try await sync.synchronize() }
    #expect(try await repository.syncCursor(accountId: "a") == "10")
    var status = sync.status.makeAsyncIterator()
    guard case .error = await status.next() else { Issue.record("Expected an error sync status"); return }
}

@Test func missingBodyAttachmentDoesNotDeleteMessageOrTriggerFullResync() async throws {
    let stub = HTTPStub { request in
        switch request.url!.lastPathComponent {
        case "labels": return (200, try json(["labels": labelsResponse]))
        case "history": return (200, try json(["historyId": "20", "history": [["messagesAdded": [["message": ["id": "tagged"]]]]]]))
        case "tagged": return (200, try json(["id": "tagged", "threadId": "tagged", "internalDate": "1700000000000",
                                              "payload": ["mimeType": "text/plain", "body": ["attachmentId": "missing-body"]]]))
        case "missing-body": return (404, try json([:]))
        default: Issue.record("Unexpected full resync"); throw URLError(.unsupportedURL)
        }
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    try await repository.setSyncCursor("10", accountId: "a")
    let sync = sync(repository: repository, session: stub.session)
    await #expect(throws: GmailHTTPError.self) { try await sync.synchronize() }
    #expect(try await repository.thread(accountId: "a", threadId: "tagged") != nil)
    #expect(try await repository.syncCursor(accountId: "a") == "10")
}

@Test func stoppedSyncCannotBeRestartedByAnOverlappingRefresh() async throws {
    let stub = HTTPStub { _ in Issue.record("Stopped sync issued a request"); throw URLError(.cancelled) }
    defer { stub.finish() }
    let repository = try await seededRepository()
    let sync = sync(repository: repository, session: stub.session)
    await sync.stop()
    await sync.start()
    await #expect(throws: CancellationError.self) { try await sync.synchronize() }
}

@Test func accountRemovalDeletesTokensAndCascadedDatabaseRows() async throws {
    let repository = try await seededRepository()
    let tokens = MemoryTokenStore(["a": OAuthTokens(accessToken: "test", refreshToken: "refresh", expiresAt: .distantFuture)])
    let store = AccountStore(repository: repository, clientId: "", tokens: tokens)
    try await repository.setSyncCursor("10", accountId: "a")
    try await repository.enqueue(.deleteDraft(messageId: "deleted"), accountId: "a")
    try await store.removeAccount(id: "a")
    #expect(await tokens.load(accountId: "a") == nil)
    #expect(try await repository.accounts().isEmpty)
    #expect(try await repository.threads(in: .unified(.inbox)).isEmpty)
    #expect(try await repository.syncCursor(accountId: "a") == nil)
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
}

@Test func missingClientIdFailsBeforeOpeningBrowserOrSavingTokens() async throws {
    let repository = try await seededRepository()
    let tokens = MemoryTokenStore()
    let store = AccountStore(repository: repository, clientId: "YOUR_CLIENT_ID.apps.googleusercontent.com", tokens: tokens)
    await #expect(throws: (any Error).self) { try await store.addAccount() }
    #expect(await tokens.saves == 0)
}

@Test func largeTextPartsAreHydratedThroughAttachmentEndpoint() async throws {
    let stub = HTTPStub { request in
        if request.url!.path.hasSuffix("/attachments/body-part") {
            return (200, try json(["data": PKCE.base64URL(Foundation.Data("Large text".utf8)), "size": 10]))
        }
        return (200, try json(["id": "m", "threadId": "t", "internalDate": "1700000000000",
                               "payload": ["mimeType": "text/plain", "body": ["attachmentId": "body-part", "size": 10]]]))
    }
    defer { stub.finish() }
    let oauth = OAuthSession(clientId: "test.apps.googleusercontent.com",
                             tokens: MemoryTokenStore(["a": OAuthTokens(accessToken: "test", refreshToken: "refresh", expiresAt: .distantFuture)]), session: stub.session)
    let client = GmailClient(accountId: "a", oauth: oauth, session: stub.session)
    let mapped = try GmailMapping.message(try await client.message(id: "m"), accountId: "a")
    #expect(mapped.body.plainText == "Large text")
}

@Test func outboxReplayModifiesAndTrashesThenDequeues() async throws {
    let requests = Mutex<[(String, String, String)]>([])
    let stub = HTTPStub { request in
        let path = request.url!.path
        requests.withLock { $0.append((request.httpMethod ?? "", path, requestBody(request))) }
        if path.hasSuffix("/modify") || path.hasSuffix("/trash") { return (200, try json([:])) }
        if path.hasSuffix("/labels") { return (200, try json(["labels": labelsResponse])) }
        if path.hasSuffix("/history") { return (200, try json(["historyId": "11"])) }
        throw URLError(.unsupportedURL)
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    try await repository.setSyncCursor("10", accountId: "a")
    try await repository.enqueue(.changeFlags(messageId: "tagged", flags: .read, enabled: true), accountId: "a")
    try await repository.enqueue(.addMailbox(messageId: "deleted", mailboxId: "TRASH"), accountId: "a")
    try await sync(repository: repository, session: stub.session).synchronize()
    let values = requests.withLock { $0 }
    #expect(values.contains { $0.0 == "POST" && $0.1.hasSuffix("/tagged/modify") && $0.2.contains("\"removeLabelIds\":[\"UNREAD\"]") })
    #expect(values.contains { $0.0 == "POST" && $0.1.hasSuffix("/deleted/trash") })
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
}

@Test func outboxWatcherRetriesAfterFailureWhenQueueChanges() async throws {
    let modifyAttempts = Mutex(0)
    let stub = HTTPStub { request in
        let path = request.url!.path
        if path.hasSuffix("/modify") {
            let attempt = modifyAttempts.withLock { value in value += 1; return value }
            return (attempt == 1 ? 500 : 200, try json([:]))
        }
        if path.hasSuffix("/labels") { return (200, try json(["labels": labelsResponse])) }
        if path.hasSuffix("/history") { return (200, try json(["historyId": "11"])) }
        throw URLError(.unsupportedURL)
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    try await repository.setSyncCursor("10", accountId: "a")
    try await repository.enqueue(.changeFlags(messageId: "tagged", flags: .starred, enabled: true), accountId: "a")
    let accountSync = sync(repository: repository, session: stub.session)
    await accountSync.start()
    for _ in 0..<200 where modifyAttempts.withLock({ $0 }) < 1 { try await Task.sleep(for: .milliseconds(10)) }
    try await repository.enqueue(.changeFlags(messageId: "untagged", flags: .read, enabled: true), accountId: "a")
    for _ in 0..<200 {
        if try await repository.nextOutboxAction(accountId: "a") == nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(modifyAttempts.withLock { $0 } == 3)
    await accountSync.stop()
}

@Test func outboxReplayDrops404ButLeaves500Queued() async throws {
    for status in [404, 500] {
        let stub = HTTPStub { request in
            if request.url!.path.hasSuffix("/modify") { return (status, try json([:])) }
            if request.url!.path.hasSuffix("/labels") { return (200, try json(["labels": labelsResponse])) }
            if request.url!.path.hasSuffix("/history") { return (200, try json(["historyId": "11"])) }
            throw URLError(.unsupportedURL)
        }
        defer { stub.finish() }
        let repository = try await seededRepository()
        try await repository.setSyncCursor("10", accountId: "a")
        try await repository.enqueue(.changeFlags(messageId: "tagged", flags: .starred, enabled: true), accountId: "a")
        let accountSync = sync(repository: repository, session: stub.session)
        if status == 404 { try await accountSync.synchronize() }
        else { await #expect(throws: GmailHTTPError.self) { try await accountSync.synchronize() } }
        #expect((try await repository.nextOutboxAction(accountId: "a") == nil) == (status == 404))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PROJECTMAIL_GMAIL_TEST"] == "1"))
func realAccountListsLabelsUsingStoredTokens() async throws {
    let environment = ProcessInfo.processInfo.environment
    let accountId = try #require(environment["PROJECTMAIL_GMAIL_ACCOUNT_ID"])
    let clientId = try #require(environment["GMAIL_CLIENT_ID"])
    let oauth = OAuthSession(clientId: clientId, tokens: KeychainTokenStore())
    let client = GmailClient(accountId: accountId, oauth: oauth)
    #expect(try await client.labels().contains { $0.id == "INBOX" })
}

private func jmapSession(username: String) throws -> Data {
    try json(["username": username, "apiUrl": "https://api.fastmail.com/jmap/api/",
              "accounts": ["u1": ["name": "Ada Lovelace", "isPersonal": true]],
              "primaryAccounts": ["urn:ietf:params:jmap:mail": "u1"]])
}

@Test func fastmailAppPasswordIsVerifiedAgainstJMAPSessionAndStored() async throws {
    let stub = HTTPStub { request in
        if request.url != FastmailClient.sessionURL { return (503, Data()) }
        #expect(request.url == FastmailClient.sessionURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fmu1-secret")
        return (200, try jmapSession(username: "Ada@Fastmail.com"))
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    let tokens = MemoryTokenStore()
    let store = AccountStore(repository: repository, clientId: "", tokens: tokens, session: stub.session)
    try await store.addFastmailAccount(FastmailCredentials(email: " Ada@fastmail.com ", apiToken: "fmu1-secret\n"))
    let account = try #require(try await repository.accounts().first(where: { $0.id == "fastmail:ada@fastmail.com" }))
    #expect(account.provider == .jmap)
    #expect(account.displayName == "Ada Lovelace")
    #expect(account.email.address == "ada@fastmail.com")
    #expect(await tokens.load(accountId: account.id)?.accessToken == "fmu1-secret")
    try await store.removeAccount(id: account.id)
}

@Test func fastmailRejectedOrMismatchedCredentialsSaveNothing() async throws {
    let stub = HTTPStub { request in
        request.value(forHTTPHeaderField: "Authorization") == "Bearer bad" ? (401, Data()) : (200, try jmapSession(username: "other@fastmail.com"))
    }
    defer { stub.finish() }
    let repository = try await seededRepository()
    let tokens = MemoryTokenStore()
    let store = AccountStore(repository: repository, clientId: "", tokens: tokens, session: stub.session)
    await #expect(throws: FastmailError.unauthorized) {
        try await store.addFastmailAccount(FastmailCredentials(email: "ada@fastmail.com", apiToken: "bad"))
    }
    await #expect(throws: FastmailError.emailMismatch("other@fastmail.com")) {
        try await store.addFastmailAccount(FastmailCredentials(email: "ada@fastmail.com", apiToken: "good"))
    }
    #expect(await tokens.saves == 0)
    #expect(try await repository.accounts().allSatisfy { $0.provider == .gmail })
}
