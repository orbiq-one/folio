import Domain
import Foundation
import NIO
import NIOIMAP
import NIOSSL

public enum IMAPError: LocalizedError {
    case invalidCredentials, disconnected, rejected, unsupportedAction, busy, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Enter a valid IMAP host, port, username, and password."
        case .disconnected: "The IMAP connection closed or timed out."
        case .rejected: "The IMAP server rejected the request. Check your account settings and permissions."
        case .unsupportedAction: "This operation is not supported by this IMAP account."
        case .busy: "An IMAP request is already in progress."
        case .invalidResponse: "The IMAP server returned an invalid response."
        }
    }
}

struct IMAPFolder: Sendable {
    var path: String
    var attributes: [String]
    var separator: String?
    var isSelectable: Bool { !attributes.contains { ["\\noselect", "\\nonexistent"].contains($0.lowercased()) } }
}

struct IMAPFolderState: Codable, Equatable, Sendable {
    var uidValidity: UInt32 = 0
    var uidNext: UInt32 = 0
    var highestModSequence: UInt64?
}

struct IMAPFetchedMessage: Sendable {
    var uid: UInt32 = 0
    var flags: MessageFlags = []
    var date: Date = .distantPast
    var data = Foundation.Data()
}

struct IMAPResponseDecoder: ByteToMessageDecoder {
    typealias InboundOut = Response
    var parser = ResponseParser()
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // The parser accepts lone CR; wait for LF before it can enter literal mode.
        if buffer.readableBytes > 0, buffer.getInteger(at: buffer.writerIndex - 1, as: UInt8.self) == 13 { return .needMoreData }
        guard let value = try parser.parseResponseStream(buffer: &buffer) else { return .needMoreData }
        switch value {
        case .response(let response): context.fireChannelRead(wrapInboundOut(response))
        case .continuationRequest: context.fireChannelRead(wrapInboundOut(.authenticationChallenge(ByteBuffer())))
        }
        return .continue
    }
}

// All mutable state is confined to the channel's event loop.
private final class IMAPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response
    let greeting: EventLoopPromise<Void>
    var pending: EventLoopPromise<[Response]>?
    var tag: String?
    var responses: [Response] = []
    var literal: Foundation.Data?
    var receivedGreeting = false
    var timeout: Scheduled<Void>?
    init(eventLoop: any EventLoop) { greeting = eventLoop.makePromise() }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        if !receivedGreeting {
            receivedGreeting = true
            if case .untagged(.conditionalState(.ok)) = response { greeting.succeed(()) }
            else { greeting.fail(IMAPError.rejected); context.close(promise: nil) }
            return
        }
        if case .fatal = response { fail(IMAPError.disconnected); context.close(promise: nil); return }
        guard let pending else { return }
        if case .authenticationChallenge = response {
            guard let literal else { fail(IMAPError.invalidResponse); context.close(promise: nil); return }
            self.literal = nil
            var buffer = ByteBuffer(bytes: literal); buffer.writeString("\r\n")
            context.channel.writeAndFlush(buffer).whenFailure { error in self.fail(error) }
            return
        }
        responses.append(response)
        if case .tagged(let completion) = response, completion.tag == tag {
            self.pending = nil
            timeout?.cancel()
            if case .ok = completion.state { pending.succeed(responses) }
            else { pending.fail(IMAPError.rejected) }
            responses = []
        }
    }
    func fail(_ error: any Error) {
        if !receivedGreeting { receivedGreeting = true; greeting.fail(error) }
        pending?.fail(error); pending = nil; responses = []; timeout?.cancel()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { fail(IMAPError.disconnected); context.fireChannelInactive() }

    func request(_ command: String, tag: String, channel: any Channel, literal: Foundation.Data? = nil) -> EventLoopFuture<[Response]> {
        guard pending == nil else { return channel.eventLoop.makeFailedFuture(IMAPError.busy) }
        let promise = channel.eventLoop.makePromise(of: [Response].self)
        pending = promise; self.tag = tag; responses = []; self.literal = literal
        timeout = channel.eventLoop.scheduleTask(in: .seconds(60)) { self.fail(IMAPError.disconnected); channel.close(promise: nil) }
        channel.writeAndFlush(ByteBuffer(string: "\(tag) \(command)\r\n")).whenFailure { error in
            self.fail(error); channel.close(promise: nil)
        }
        return promise.futureResult
    }
}

protocol IMAPSession: Actor {
    func connect() async throws
    func close() async
    func folders() async throws -> [IMAPFolder]
    func select(_ folder: String, readOnly: Bool) async throws -> IMAPFolderState
    func search(since: Date) async throws -> [UInt32]
    func fetch(_ uid: UInt32, full: Bool) async throws -> IMAPFetchedMessage?
    func changedFlags(since: UInt64) async throws -> [UInt32: MessageFlags]
    func store(uid: UInt32, flags: MessageFlags, enabled: Bool) async throws
    func move(uid: UInt32, to folder: String) async throws
    func append(_ data: Foundation.Data, folder: String, draft: Bool) async throws
    func uids(messageID: String) async throws -> [UInt32]
    func delete(uid: UInt32) async throws
    func sendSMTP(message: Message, data: Foundation.Data) async throws
}

extension IMAPSession {
    func append(_ data: Foundation.Data, folder: String, draft: Bool) async throws { throw IMAPError.unsupportedAction }
    func uids(messageID: String) async throws -> [UInt32] { throw IMAPError.unsupportedAction }
    func delete(uid: UInt32) async throws { throw IMAPError.unsupportedAction }
    func sendSMTP(message: Message, data: Foundation.Data) async throws { throw IMAPError.unsupportedAction }
}

public actor IMAPClient: IMAPSession {
    private let credentials: IMAPCredentials
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: (any Channel)?
    private var handler: IMAPResponseHandler?
    private var counter = 0
    private var connecting = false
    private var closed = false
    private(set) var capabilities: Set<String> = []

    public init(credentials: IMAPCredentials) { self.credentials = credentials }

    public func connect() async throws {
        guard !closed else { throw IMAPError.disconnected }
        if channel?.isActive == true { return }
        guard !connecting else { throw IMAPError.busy }
        guard credentials.isComplete else { throw IMAPError.invalidCredentials }
        connecting = true
        defer { connecting = false }
        let ssl = try NIOSSLContext(configuration: .makeClientConfiguration())
        let credentials = credentials
        let loop = group.next()
        let handler = IMAPResponseHandler(eventLoop: loop)
        do {
            let channel = try await ClientBootstrap(group: loop).connectTimeout(.seconds(30))
                .channelInitializer { channel in
                    do {
                        if credentials.security == .tls {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ssl, serverHostname: credentials.host))
                        }
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(IMAPResponseDecoder()))
                        try channel.pipeline.syncOperations.addHandler(handler)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }.connect(host: credentials.host, port: credentials.port).get()
            guard !closed, !Task.isCancelled else { try? await channel.close().get(); throw CancellationError() }
            self.channel = channel; self.handler = handler
            let timeout = loop.scheduleTask(in: .seconds(30)) { handler.fail(IMAPError.disconnected); channel.close(promise: nil) }
            defer { timeout.cancel() }
            try await handler.greeting.futureResult.get()
            if credentials.security == .startTLS {
                _ = try await command("STARTTLS")
                try await channel.eventLoop.submit {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ssl, serverHostname: credentials.host), position: .first)
                }.get()
            }
            _ = try await command("LOGIN \(Self.quote(credentials.username)) \(Self.quote(credentials.password))")
            capabilities = Set(try await command("CAPABILITY").flatMap { response -> [String] in
                if case .untagged(.capabilityData(let values)) = response { return values.map { String($0).uppercased() } }
                return []
            })
        } catch { try? await channel?.close().get(); self.channel = nil; self.handler = nil; throw error }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await channel?.close().get()
        channel = nil; handler = nil
        try? await group.shutdownGracefully()
    }

    private func command(_ command: String, literal: Foundation.Data? = nil) async throws -> [Response] {
        try Task.checkCancellation()
        guard let channel, let handler, channel.isActive else { throw IMAPError.disconnected }
        counter += 1
        let tag = "P\(counter)"
        return try await withTaskCancellationHandler {
            try await channel.eventLoop.flatSubmit { handler.request(command, tag: tag, channel: channel, literal: literal) }.get()
        } onCancel: { channel.close(promise: nil) }
    }

    static func quote(_ value: String) throws -> String {
        guard !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw IMAPError.invalidCredentials }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func folders() async throws -> [IMAPFolder] {
        let suffix = capabilities.contains("LIST-EXTENDED") && capabilities.contains("SPECIAL-USE") ? " RETURN (SPECIAL-USE)" : ""
        return try await command("LIST \"\" \"*\"" + suffix).compactMap { response in
            guard case .untagged(.mailboxData(.list(let info))) = response else { return nil }
            return IMAPFolder(path: String(decoding: info.path.name.bytes, as: UTF8.self), attributes: info.attributes.map { String($0) }, separator: info.path.pathSeparator.map(String.init))
        }
    }

    func select(_ folder: String, readOnly: Bool = false) async throws -> IMAPFolderState {
        var state = IMAPFolderState()
        let responses = try await command("\(readOnly ? "EXAMINE" : "SELECT") \(Self.quote(folder))" + (capabilities.contains("CONDSTORE") ? " (CONDSTORE)" : ""))
        for response in responses {
            let text: ResponseText?
            switch response {
            case .untagged(.conditionalState(.ok(let value))): text = value
            case .tagged(let tagged): if case .ok(let value) = tagged.state { text = value } else { text = nil }
            default: text = nil
            }
            switch text?.code {
            case .uidValidity(let value): state.uidValidity = UInt32(value)
            case .uidNext(let value): state.uidNext = value.rawValue
            case .highestModificationSequence(let value): state.highestModSequence = UInt64(value)
            default: break
            }
        }
        guard state.uidValidity != 0 else { throw IMAPError.invalidResponse }
        return state
    }

    func search(since: Date) async throws -> [UInt32] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "d-MMM-yyyy"
        return try await command("UID SEARCH SINCE \(formatter.string(from: since))").flatMap { response in
            if case .untagged(.mailboxData(.search(let ids, _))) = response { return ids.map(\.rawValue) }
            return []
        }
    }

    func search(text: String) async throws -> [UInt32] {
        try await command("UID SEARCH TEXT \(Self.quote(text))").flatMap { response in
            if case .untagged(.mailboxData(.search(let ids, _))) = response { return ids.map(\.rawValue) }
            return []
        }
    }

    func fetch(_ uid: UInt32, full: Bool = true) async throws -> IMAPFetchedMessage? {
        let fields = full ? "UID FLAGS INTERNALDATE BODY.PEEK[]" : "UID FLAGS ENVELOPE BODYSTRUCTURE INTERNALDATE BODY.PEEK[HEADER.FIELDS (Message-ID In-Reply-To References)]"
        let responses = try await command("UID FETCH \(uid) (\(fields))")
        var result = IMAPFetchedMessage()
        var matched: IMAPFetchedMessage?
        for response in responses {
            switch response {
            case .fetch(.start), .fetch(.startUID): result = IMAPFetchedMessage()
            case .fetch(.simpleAttribute(.uid(let value))): result.uid = value.rawValue
            case .fetch(.simpleAttribute(.flags(let flags))): result.flags = IMAPMapping.flags(flags.map { String($0) })
            case .fetch(.simpleAttribute(.internalDate(let date))):
                let c = date.components
                result.date = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: c.zoneMinutes * 60), year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second)) ?? .distantPast
            case .fetch(.streamingBytes(let bytes)): result.data.append(contentsOf: bytes.readableBytesView)
            case .fetch(.finish): if result.uid == uid { matched = result }
            default: break
            }
        }
        return matched
    }

    func changedFlags(since: UInt64) async throws -> [UInt32: MessageFlags] {
        let responses = try await command("UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE \(since))")
        var uid: UInt32?
        var flags: MessageFlags = []
        var result: [UInt32: MessageFlags] = [:]
        for response in responses {
            switch response {
            case .fetch(.start), .fetch(.startUID): uid = nil; flags = []
            case .fetch(.simpleAttribute(.uid(let value))): uid = value.rawValue
            case .fetch(.simpleAttribute(.flags(let values))): flags = IMAPMapping.flags(values.map { String($0) })
            case .fetch(.finish): if let uid { result[uid] = flags }
            default: break
            }
        }
        return result
    }

    func store(uid: UInt32, flags: MessageFlags, enabled: Bool) async throws {
        var values: [String] = []
        if flags.contains(.read) { values.append("\\Seen") }
        if flags.contains(.starred) { values.append("\\Flagged") }
        guard !values.isEmpty else { throw IMAPError.unsupportedAction }
        _ = try await command("UID STORE \(uid) \(enabled ? "+" : "-")FLAGS.SILENT (\(values.joined(separator: " ")))")
    }

    func append(_ data: Foundation.Data, folder: String, draft: Bool) async throws {
        _ = try await command("APPEND \(Self.quote(folder)) (\(draft ? "\\Draft" : "\\Seen")) {\(data.count)}", literal: data)
    }

    func uids(messageID: String) async throws -> [UInt32] {
        try await command("UID SEARCH HEADER Message-ID \(Self.quote(messageID))").flatMap { response in
            if case .untagged(.mailboxData(.search(let ids, _))) = response { return ids.map(\.rawValue) }
            return []
        }
    }

    func delete(uid: UInt32) async throws {
        guard capabilities.contains("UIDPLUS") else { throw IMAPError.unsupportedAction }
        _ = try await command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        _ = try await command("UID EXPUNGE \(uid)")
    }

    func sendSMTP(message: Message, data: Foundation.Data) async throws {
        try await SMTPClient(credentials: credentials).send(message: message, data: data)
    }

    func move(uid: UInt32, to folder: String) async throws {
        if capabilities.contains("MOVE") { _ = try await command("UID MOVE \(uid) \(Self.quote(folder))") }
        else {
            // UID EXPUNGE avoids deleting unrelated messages marked by another client.
            guard capabilities.contains("UIDPLUS") else { throw IMAPError.unsupportedAction }
            _ = try await command("UID COPY \(uid) \(Self.quote(folder))")
            _ = try await command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            _ = try await command("UID EXPUNGE \(uid)")
        }
    }
}
