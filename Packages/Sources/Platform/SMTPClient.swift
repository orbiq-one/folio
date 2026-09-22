import Domain
import Foundation
import NIO
import NIOSSL

public enum SMTPError: LocalizedError {
    case rejected(Int), disconnected, invalidAddress, unsupportedAuthentication, deliveryUncertain
    public var errorDescription: String? {
        switch self {
        case .rejected(let code): "The SMTP server rejected the message (\(code))."
        case .disconnected: "The SMTP connection closed or timed out."
        case .invalidAddress: "A sender or recipient address is invalid."
        case .unsupportedAuthentication: "The SMTP server does not support password authentication."
        case .deliveryUncertain: "Delivery could not be confirmed. Check Sent before retrying to avoid sending a duplicate."
        }
    }
}

struct SMTPReply: Sendable { var code: Int; var lines: [String] }

// Mutable state is accessed only on the channel's event loop.
final class SMTPReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    var buffer = ByteBuffer()
    var lines: [String] = []
    var replies: [SMTPReply] = []
    var waiting: EventLoopPromise<SMTPReply>?
    var failure: (any Error)?
    var timeout: Scheduled<Void>?
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data); buffer.writeBuffer(&incoming)
        while let end = buffer.readableBytesView.firstIndex(of: 10) {
            guard let line = buffer.readString(length: end - buffer.readerIndex + 1), line.utf8.count >= 4,
                  let code = Int(line.prefix(3)) else { fail(SMTPError.disconnected); context.close(promise: nil); return }
            lines.append(String(line.dropFirst(4)).trimmingCharacters(in: .newlines))
            if line.dropFirst(3).first == " " {
                let reply = SMTPReply(code: code, lines: lines); lines = []
                if let waiting { self.waiting = nil; timeout?.cancel(); waiting.succeed(reply) }
                else { replies.append(reply) }
            }
        }
        if buffer.readableBytes > 65_536 || lines.count > 100 { fail(SMTPError.disconnected); context.close(promise: nil) }
        buffer.discardReadBytes()
    }
    func next(channel: any Channel) -> EventLoopFuture<SMTPReply> {
        if let failure { return channel.eventLoop.makeFailedFuture(failure) }
        if !replies.isEmpty { return channel.eventLoop.makeSucceededFuture(replies.removeFirst()) }
        guard waiting == nil else { return channel.eventLoop.makeFailedFuture(SMTPError.disconnected) }
        let promise = channel.eventLoop.makePromise(of: SMTPReply.self); waiting = promise
        timeout = channel.eventLoop.scheduleTask(in: .seconds(60)) { self.fail(SMTPError.disconnected); channel.close(promise: nil) }
        return promise.futureResult
    }
    func fail(_ error: any Error) { failure = error; waiting?.fail(error); waiting = nil; timeout?.cancel() }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { fail(SMTPError.disconnected); context.fireChannelInactive() }
}

struct SMTPConnection: Sendable {
    let channel: any Channel
    let handler: SMTPReplyHandler
    func reply(_ expected: Int) async throws -> SMTPReply {
        let result = try await withTaskCancellationHandler {
            try await channel.eventLoop.flatSubmit { handler.next(channel: channel) }.get()
        } onCancel: { channel.close(promise: nil) }
        guard result.code == expected else { throw SMTPError.rejected(result.code) }
        return result
    }
    @discardableResult func command(_ value: String, expecting: Int) async throws -> SMTPReply {
        try Task.checkCancellation()
        try await channel.writeAndFlush(ByteBuffer(string: value + "\r\n")).get()
        return try await reply(expecting)
    }
}

public actor SMTPClient {
    private let credentials: IMAPCredentials
    private var sending = false
    public init(credentials: IMAPCredentials) { self.credentials = credentials }

    public func send(message: Message, data: Data) async throws {
        guard !sending else { throw SMTPError.disconnected }
        sending = true
        defer { sending = false }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var channel: (any Channel)?
        do {
            let context = try NIOSSLContext(configuration: .makeClientConfiguration())
            let credentials = credentials
            let handler = SMTPReplyHandler()
            let connected = try await ClientBootstrap(group: group).connectTimeout(.seconds(30)).channelInitializer { channel in
                do {
                    if credentials.resolvedSMTPSecurity == .tls {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: credentials.resolvedSMTPHost))
                    }
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }.connect(host: credentials.resolvedSMTPHost, port: credentials.resolvedSMTPPort).get()
            channel = connected
            let connection = SMTPConnection(channel: connected, handler: handler)
            _ = try await connection.reply(220)
            if credentials.resolvedSMTPSecurity == .startTLS {
                let hello = try await connection.command("EHLO projectmail.local", expecting: 250)
                guard hello.lines.contains(where: { $0.uppercased() == "STARTTLS" }) else { throw SMTPError.rejected(454) }
                try await connection.command("STARTTLS", expecting: 220)
                try await connected.eventLoop.submit {
                    try connected.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: credentials.resolvedSMTPHost), position: .first)
                }.get()
            }
            try await Self.deliver(over: connection, credentials: credentials, message: message, data: data)
            try? await connected.close().get()
            try? await group.shutdownGracefully()
        } catch {
            try? await channel?.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    static func deliver(over connection: SMTPConnection, credentials: IMAPCredentials, message: Message, data: Data) async throws {
        func address(_ value: String) throws -> String {
            guard value.contains("@"), value.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![60, 62].contains($0) }) else { throw SMTPError.invalidAddress }
            return value
        }
        let sender = try address(message.sender.address)
        var seen: Set<String> = []
        let recipients = try (message.to + message.cc + message.bcc).map { try address($0.address) }.filter { seen.insert($0.lowercased()).inserted }
        guard !recipients.isEmpty else { throw SMTPError.invalidAddress }
        let hello = try await connection.command("EHLO projectmail.local", expecting: 250)
        let auth = hello.lines.first { $0.uppercased().hasPrefix("AUTH ") }?.uppercased().split(separator: " ").map(String.init) ?? []
        if auth.contains("PLAIN") {
            let token = Data(("\0" + credentials.username + "\0" + credentials.password).utf8).base64EncodedString()
            try await connection.command("AUTH PLAIN " + token, expecting: 235)
        } else if auth.contains("LOGIN") {
            try await connection.command("AUTH LOGIN", expecting: 334)
            try await connection.command(Data(credentials.username.utf8).base64EncodedString(), expecting: 334)
            try await connection.command(Data(credentials.password.utf8).base64EncodedString(), expecting: 235)
        } else { throw SMTPError.unsupportedAuthentication }
        try await connection.command("MAIL FROM:<\(sender)>", expecting: 250)
        for recipient in recipients { try await connection.command("RCPT TO:<\(recipient)>", expecting: 250) }
        try await connection.command("DATA", expecting: 354)
        do {
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
            try await connection.channel.writeAndFlush(ByteBuffer(string: text + (text.hasSuffix("\r\n") ? "" : "\r\n") + ".\r\n")).get()
            _ = try await connection.reply(250)
        } catch SMTPError.rejected(let code) { throw SMTPError.rejected(code) }
        catch { throw SMTPError.deliveryUncertain }
    }
}
