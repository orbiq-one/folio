import Data
import Domain
import Foundation
import NIO
import NIOIMAP
import Synchronization
import Testing
@testable import Platform

@Test func imapFolderKindsPreferSpecialUseAndFallBackToNames() {
    #expect(IMAPMapping.kind(path: "Custom", attributes: ["\\Sent"]) == .sent)
    #expect(IMAPMapping.kind(path: "Trash", attributes: ["\\Archive"]) == .archive)
    #expect(IMAPMapping.kind(path: "INBOX", attributes: []) == .inbox)
    #expect(IMAPMapping.kind(path: "INBOX.Sent Items", attributes: []) == .sent)
    #expect(IMAPMapping.kind(path: "Junk E-mail", attributes: []) == .spam)
    #expect(IMAPMapping.kind(path: "Drafts", attributes: []) == .drafts)
    #expect(IMAPMapping.kind(path: "Deleted Messages", attributes: []) == .trash)
    #expect(IMAPMapping.kind(path: "Projects", attributes: []) == .folder)
    let mailbox = IMAPMapping.mailbox(IMAPFolder(path: "Projects/&U,BTFw-", attributes: [], separator: "/"), accountId: "a")
    #expect(mailbox.parentId == "Projects")
    #expect(mailbox.name == "台北")
    #expect(IMAPMapping.decodeMailboxName("R&-D") == "R&D")
}

@Test func imapMailboxHierarchyHandlesMissingAndNonSelectableParents() {
    let folders = [IMAPFolder(path: "Parent/Child", attributes: [], separator: "/"),
                   IMAPFolder(path: "Parent", attributes: ["\\NoSelect"], separator: "/"),
                   IMAPFolder(path: "Missing/Child", attributes: [], separator: "/")]
    let mailboxes = IMAPMapping.mailboxes(folders, accountId: "a")
    #expect(mailboxes.first?.id == "Parent")
    #expect(mailboxes.first { $0.id == "Parent/Child" }?.parentId == "Parent")
    #expect(mailboxes.first { $0.id == "Missing/Child" }?.parentId == nil)
    #expect(!folders[1].isSelectable)
}

@Test func imapThreadingUsesAccountScopedFirstReferenceThenReplyThenMessageID() {
    let root = ["message-id": "<first@example.com>", "subject": "Topic"]
    let reply = ["references": "<first@example.com> <second@example.com>", "message-id": "<third@example.com>", "subject": "Re: Topic"]
    #expect(IMAPMapping.threadID(accountId: "a", headers: root) == IMAPMapping.threadID(accountId: "a", headers: reply))
    #expect(IMAPMapping.threadID(accountId: "a", headers: ["in-reply-to": "<first@example.com>"]) == "a:<first@example.com>")
    #expect(IMAPMapping.threadID(accountId: "b", headers: root) != IMAPMapping.threadID(accountId: "a", headers: root))
    #expect(IMAPMapping.threadID(accountId: "a", headers: ["subject": "Re: Fwd: Topic"]) == IMAPMapping.threadID(accountId: "a", headers: ["subject": "Topic"]))
}

@Test func imapMappingPreservesIdentityAddressesBodyAndFlags() throws {
    let message = IMAPFetchedMessage(uid: 23, flags: [.read, .starred], date: .now,
        data: Foundation.Data("From: \"Doe, Jane\" <jane@example.com>\r\nTo: a@example.com\r\nMessage-ID: <m@example.com>\r\nSubject: =?UTF-8?Q?Hello_world?=\r\n\r\nBody".utf8))
    let mapped = IMAPMapping.message(message, folder: "Nested/Folder", accountId: "a")
    #expect(mapped.message.id == "Nested/Folder/23")
    #expect(mapped.message.sender.name == "Doe, Jane")
    #expect(mapped.message.subject == "Hello world")
    #expect(mapped.message.mailboxIds == ["Nested/Folder"])
    #expect(mapped.body.plainText == "Body")
    #expect(mapped.message.flags == [.read, .starred])
    let location = try IMAPMapping.location(mapped.message.id)
    #expect(location.folder == "Nested/Folder")
    #expect(location.uid == 23)
    #expect(throws: IMAPError.self) { try IMAPMapping.location("Folder/0") }
    #expect(IMAPMapping.flags(["\\Seen", "\\Flagged", "\\Answered", "\\Draft"]) == [.read, .starred, .answered, .draft])
}

@Test func imapCredentialsAndCommandQuotingRejectInjection() throws {
    let credentials = IMAPCredentials(email: " A@EXAMPLE.com ", host: " imap.example.com ", password: "secret")
    #expect(credentials.username == "a@example.com")
    #expect(credentials.isComplete)
    #expect(!IMAPCredentials(email: "a@example.com", host: "host", port: 0, password: "secret").isComplete)
    #expect(try IMAPClient.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
    #expect(throws: IMAPError.self) { try IMAPClient.quote("x\r\nEXPUNGE") }
    #expect(throws: IMAPError.self) { try IMAPClient.quote("x\0") }
}

@Test(arguments: [1, 2, 7, 1024]) func imapDecoderPreservesFragmentedLiteralBytesAndCommandBoundaries(chunkSize: Int) throws {
    let channel = EmbeddedChannel(handler: ByteToMessageHandler(IMAPResponseDecoder()))
    defer { _ = try? channel.finish() }
    let literal = "Subject: Test\r\n\r\nP1 OK not-a-tag\r\nBody"
    let response = "* 1 FETCH (UID 7 FLAGS (\\Seen) INTERNALDATE \"21-Sep-2026 10:00:00 +0000\" BODY[] {\(literal.utf8.count)}\r\n\(literal))\r\nP1 OK done\r\n"
    let input = Array(response.utf8)
    for offset in stride(from: 0, to: input.count, by: chunkSize) {
        try channel.writeInbound(ByteBuffer(bytes: input[offset..<min(offset + chunkSize, input.count)]))
    }
    var bytes: [UInt8] = []
    var tags: [String] = []
    var uid: UInt32?
    while let value = try channel.readInbound(as: Response.self) {
        switch value {
        case .fetch(.streamingBytes(let buffer)): bytes += buffer.readableBytesView
        case .fetch(.simpleAttribute(.uid(let value))): uid = value.rawValue
        case .tagged(let value): tags.append(value.tag)
        default: break
        }
    }
    #expect(bytes == Array(literal.utf8))
    #expect(uid == 7)
    #expect(tags == ["P1"])
}

private final class RejectSTARTTLSServer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let record: @Sendable (String) -> Void
    var pending = ""
    init(record: @escaping @Sendable (String) -> Void) { self.record = record }
    func channelActive(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "* OK Test server ready\r\n")), promise: nil)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        guard let end = pending.range(of: "\r\n") else { return }
        let line = String(pending[..<end.lowerBound])
        pending.removeSubrange(..<end.upperBound)
        record(line)
        let tag = line.split(separator: " ").first ?? "P1"
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "\(tag) NO TLS unavailable\r\n")), promise: nil)
    }
}

@Test func imapSTARTTLSRejectionNeverSendsPasswordInCleartext() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let commands = Mutex<[String]>([])
    let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
        do {
            try channel.pipeline.syncOperations.addHandler(RejectSTARTTLSServer { line in commands.withLock { $0.append(line) } })
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch { return channel.eventLoop.makeFailedFuture(error) }
    }.bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)
    let client = IMAPClient(credentials: IMAPCredentials(email: "a@example.com", host: "127.0.0.1", port: port, password: "must-not-be-sent", security: .startTLS))
    await #expect(throws: IMAPError.self) { try await client.connect() }
    await client.close()
    try await server.close().get()
    try await group.shutdownGracefully()
    #expect(commands.withLock { $0.count } == 1)
    #expect(commands.withLock { $0.first?.hasSuffix(" STARTTLS") } == true)
    #expect(commands.withLock { $0.allSatisfy { !$0.contains("must-not-be-sent") && !$0.contains("LOGIN") } })
}

private actor FakeIMAPSession: IMAPSession {
    var state = IMAPFolderState(uidValidity: 1, uidNext: 3, highestModSequence: 7)
    var selected = ""
    var messages: [String: [UInt32: IMAPFetchedMessage]] = ["INBOX": [1: FakeIMAPSession.message(1), 2: FakeIMAPSession.message(2)], "Archive": [:]]
    var downloads: [(UInt32, Bool)] = []
    var stores: [UInt32] = []
    var changed: [UInt32: MessageFlags] = [:]
    var searchedDates: [Date] = []
    var modSequences: [UInt64] = []
    var rejectFetch = false
    static func message(_ uid: UInt32, subject: String = "Topic") -> IMAPFetchedMessage {
        IMAPFetchedMessage(uid: uid, date: .now, data: Foundation.Data("Message-ID: <\(uid)@test>\r\nSubject: \(subject)\r\n\r\nBody".utf8))
    }
    func connect() {}
    func close() {}
    func folders() -> [IMAPFolder] { [IMAPFolder(path: "INBOX", attributes: [], separator: "/"), IMAPFolder(path: "Archive", attributes: ["\\Archive"], separator: "/")] }
    func select(_ folder: String, readOnly: Bool) -> IMAPFolderState { selected = folder; return state }
    func search(since: Date) -> [UInt32] { searchedDates.append(since); return Array(messages[selected, default: [:]].keys).sorted() }
    func fetch(_ uid: UInt32, full: Bool) throws -> IMAPFetchedMessage? {
        if rejectFetch { throw IMAPError.disconnected }
        downloads.append((uid, full)); return messages[selected]?[uid]
    }
    func changedFlags(since: UInt64) -> [UInt32: MessageFlags] { modSequences.append(since); return changed }
    func store(uid: UInt32, flags: MessageFlags, enabled: Bool) {
        stores.append(uid)
        if enabled { messages[selected]?[uid]?.flags.formUnion(flags) }
        else { messages[selected]?[uid]?.flags.subtract(flags) }
        changed[uid] = messages[selected]?[uid]?.flags
    }
    func move(uid: UInt32, to folder: String) {
        guard var message = messages[selected]?.removeValue(forKey: uid) else { return }
        message.uid += 100
        messages[folder, default: [:]][message.uid] = message
    }
    func reset() { state.uidValidity = 2; messages["INBOX"] = [1: Self.message(1, subject: "Replacement")]; downloads = [] }
    func deleteFirstAndChangeSecond() { messages["INBOX"]?[1] = nil; changed = [2: [.read]]; state.highestModSequence = 8; downloads = [] }
    func failFetch() { rejectFetch = true }
}

private func imapRepository() async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .imap, displayName: "A", email: EmailAddress(address: "a@test")))
    return repository
}

@Test func imapSyncPersistsPerFolderCursorsAndUsesCondstore() async throws {
    let repository = try await imapRepository()
    let session = FakeIMAPSession()
    let sync = IMAPAccountSync(accountId: "a", session: session, repository: repository)
    try await sync.synchronize()
    #expect(try await repository.messageIds(accountId: "a") == ["INBOX/1", "INBOX/2"])
    let cursor = try #require(try await repository.syncCursor(accountId: "a", scope: "INBOX"))
    #expect(try JSONDecoder().decode(IMAPFolderState.self, from: Foundation.Data(cursor.utf8)).uidValidity == 1)
    #expect(try await repository.syncCursor(accountId: "a", scope: "Archive") != nil)
    #expect(try await repository.syncCursor(accountId: "a") == nil)
    #expect(await session.searchedDates.allSatisfy { abs($0.timeIntervalSinceNow + 90 * 86_400) < 10 })
    await session.deleteFirstAndChangeSecond()
    try await sync.synchronize()
    #expect(try await repository.messageIds(accountId: "a") == ["INBOX/2"])
    #expect(await session.downloads.isEmpty)
    #expect(await session.modSequences == [7, 7])
    #expect(try await repository.thread(accountId: "a", threadId: "a:<2@test>")?.messages.first?.flags == [.read])
    await sync.stop()
}

@Test func imapUIDValidityResetRefetchesReusedUIDAndDoesNotReplayStaleAction() async throws {
    let repository = try await imapRepository()
    let session = FakeIMAPSession()
    let sync = IMAPAccountSync(accountId: "a", session: session, repository: repository)
    try await sync.synchronize()
    try await repository.enqueue(.changeFlags(messageId: "INBOX/1", flags: .read, enabled: true), accountId: "a")
    await session.reset()
    try await sync.synchronize()
    #expect(await session.stores.isEmpty)
    #expect(await session.downloads.count == 1)
    #expect(try await repository.messageIds(accountId: "a") == ["INBOX/1"])
    #expect(try await repository.thread(accountId: "a", threadId: "a:<1@test>")?.messages.first?.subject == "Replacement")
    await sync.stop()
}

@Test func imapReplayMovesByDeletingAndReinsertingWithDestinationUID() async throws {
    let repository = try await imapRepository()
    let session = FakeIMAPSession()
    let sync = IMAPAccountSync(accountId: "a", session: session, repository: repository)
    try await sync.synchronize()
    try await repository.enqueue(.move(messageId: "INBOX/1", fromMailboxId: "INBOX", toMailboxId: "Archive"), accountId: "a")
    try await sync.synchronize()
    #expect(try await repository.messageIds(accountId: "a") == ["INBOX/2", "Archive/101"])
    #expect(try await repository.nextOutboxAction(accountId: "a") == nil)
    #expect(try await repository.thread(accountId: "a", threadId: "a:<1@test>")?.messages.first?.mailboxIds == ["Archive"])
    await sync.stop()
}

@Test func imapOutboxFlagsAndSingleFolderRemovalReplay() async throws {
    let repository = try await imapRepository()
    let session = FakeIMAPSession()
    let sync = IMAPAccountSync(accountId: "a", session: session, repository: repository)
    try await sync.synchronize()
    try await repository.enqueue(.changeFlags(messageId: "INBOX/1", flags: [.read, .starred], enabled: true), accountId: "a")
    try await repository.enqueue(.removeMailbox(messageId: "INBOX/2", mailboxId: "INBOX"), accountId: "a")
    try await sync.synchronize()
    #expect(await session.stores == [1])
    #expect(try await repository.thread(accountId: "a", threadId: "a:<1@test>")?.messages.first?.flags == [.read, .starred])
    #expect(try await repository.messageIds(accountId: "a") == ["INBOX/1", "Archive/102"])
    try await repository.enqueue(.deleteDraft(messageId: "INBOX/1"), accountId: "a")
    await #expect(throws: IMAPError.self) { try await sync.synchronize() }
    #expect(try await repository.nextOutboxAction(accountId: "a") != nil)
    await sync.stop()
}

@Test func imapFailedDownloadDoesNotAdvanceCursorOrDeleteExistingMail() async throws {
    let repository = try await imapRepository()
    let session = FakeIMAPSession()
    let sync = IMAPAccountSync(accountId: "a", session: session, repository: repository)
    try await sync.synchronize()
    let cursor = try await repository.syncCursor(accountId: "a", scope: "INBOX")
    await session.reset()
    await session.failFetch()
    await #expect(throws: IMAPError.self) { try await sync.synchronize() }
    #expect(try await repository.syncCursor(accountId: "a", scope: "INBOX") == cursor)
    #expect(try await repository.messageIds(accountId: "a") == ["INBOX/1", "INBOX/2"])
    await sync.stop()
}
