import Domain
import Foundation
import NIO
import Synchronization
import Testing
@testable import Platform

private final class FakeSMTPServer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let login: Bool
    let disconnectAfterData: Bool
    let record: @Sendable (String) -> Void
    var pending = ""
    var dataMode = false
    var loginStep = 0
    init(login: Bool, disconnectAfterData: Bool, record: @escaping @Sendable (String) -> Void) {
        self.login = login; self.disconnectAfterData = disconnectAfterData; self.record = record
    }
    func channelActive(context: ChannelHandlerContext) { respond("220 localhost ready", context) }
    func respond(_ response: String, _ context: ChannelHandlerContext) { context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: response + "\r\n")), promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var value = unwrapInboundIn(data); pending += value.readString(length: value.readableBytes) ?? ""
        while let end = pending.range(of: "\r\n") {
            let line = String(pending[..<end.lowerBound]); pending.removeSubrange(..<end.upperBound)
            record(line)
            if dataMode {
                if line == "." {
                    dataMode = false
                    if disconnectAfterData { context.close(promise: nil) } else { respond("250 queued", context) }
                }
                continue
            }
            if loginStep > 0 { loginStep += 1; respond(loginStep == 2 ? "334 UGFzc3dvcmQ6" : "235 authenticated", context); if loginStep == 3 { loginStep = 0 }; continue }
            if line.hasPrefix("EHLO") { respond("250-localhost\r\n250 AUTH \(login ? "LOGIN" : "PLAIN")", context) }
            else if line == "AUTH LOGIN" { loginStep = 1; respond("334 VXNlcm5hbWU6", context) }
            else if line.hasPrefix("AUTH PLAIN") { respond("235 authenticated", context) }
            else if line.hasPrefix("MAIL FROM") || line.hasPrefix("RCPT TO") { respond("250 OK", context) }
            else if line == "DATA" { dataMode = true; respond("354 send content", context) }
            else { respond("500 unknown", context) }
        }
    }
}

private func smtpFixture(login: Bool, uncertain: Bool) async throws -> [String] {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let recorded = Mutex<[String]>([])
    let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
        do {
            try channel.pipeline.syncOperations.addHandler(FakeSMTPServer(login: login, disconnectAfterData: uncertain) { line in recorded.withLock { $0.append(line) } })
            return channel.eventLoop.makeSucceededVoidFuture()
        } catch { return channel.eventLoop.makeFailedFuture(error) }
    }.bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(server.localAddress?.port)
    let handler = SMTPReplyHandler()
    let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
        do { try channel.pipeline.syncOperations.addHandler(handler); return channel.eventLoop.makeSucceededVoidFuture() }
        catch { return channel.eventLoop.makeFailedFuture(error) }
    }.connect(host: "127.0.0.1", port: port).get()
    let connection = SMTPConnection(channel: channel, handler: handler)
    let message = Message(id: "m", accountId: "a", threadId: "t", subject: "Test", sender: EmailAddress(address: "a@example.com"),
                          to: [EmailAddress(address: "to@example.com")], bcc: [EmailAddress(address: "hidden@example.com")], date: .now)
    let credentials = IMAPCredentials(email: "a@example.com", host: "imap.example.com", password: "test-password")
    _ = try await connection.reply(220)
    if uncertain {
        await #expect(throws: (any Error).self) { try await SMTPClient.deliver(over: connection, credentials: credentials, message: message, data: Data("Subject: Test\r\n\r\n.leading\r\n".utf8)) }
    } else {
        try await SMTPClient.deliver(over: connection, credentials: credentials, message: message, data: Data("Subject: Test\r\n\r\n.leading\r\n".utf8))
    }
    try? await channel.close().get(); try await server.close().get(); try await group.shutdownGracefully()
    return recorded.withLock { $0 }
}

@Test(arguments: [false, true]) func smtpEHLOAuthenticationEnvelopeAndDotStuffing(login: Bool) async throws {
    let commands = try await smtpFixture(login: login, uncertain: false)
    #expect(commands.contains("EHLO projectmail.local"))
    #expect(commands.contains("MAIL FROM:<a@example.com>"))
    #expect(commands.contains("RCPT TO:<hidden@example.com>"))
    #expect(commands.contains("..leading"))
    #expect(commands.contains("."))
    #expect(!commands.contains { $0.hasPrefix("Bcc:") })
}

@Test func smtpDisconnectAfterDATAIsNotConfirmedDelivery() async throws { _ = try await smtpFixture(login: false, uncertain: true) }

@Test func smtpDefaultsDecodeExistingCredentials() throws {
    let old = Data(#"{"email":"a@example.com","host":"imap.example.com","port":993,"username":"a@example.com","password":"test","security":"tls"}"#.utf8)
    let credentials = try JSONDecoder().decode(IMAPCredentials.self, from: old)
    #expect(credentials.resolvedSMTPHost == "smtp.example.com")
    #expect(credentials.resolvedSMTPPort == 587)
    #expect(credentials.resolvedSMTPSecurity == .startTLS)
}

@Test func mimeWriterRoundTripsUnicodeBodiesThreadHeadersAndHidesBCC() throws {
    let message = Message(id: "m", accountId: "a", threadId: "t", subject: "Café – こんにちは", sender: EmailAddress(address: "a@example.com", name: "Åda"),
                          to: [EmailAddress(address: "b@example.com")], bcc: [EmailAddress(address: "hidden@example.com")], replyTo: [EmailAddress(address: "reply@example.com")], date: .now,
                          internetMessageId: "<message@example.com>", inReplyTo: "<parent@example.com>", references: ["<root@example.com>", "<parent@example.com>"])
    let body = MessageBody(id: "m", plainText: "Café\n.trailing space ", html: "<p><b>Café</b> &amp; tea</p>")
    let data = try MIMEWriter.write(message: message, body: body)
    let parsed = MIMEParser.parse(data)
    #expect(parsed.plainText == "Café\r\n.trailing space ")
    #expect(parsed.html == body.html)
    #expect(MIMEParser.decodeHeader(parsed.headers["subject"] ?? "") == message.subject)
    #expect(parsed.headers["in-reply-to"] == message.inReplyTo)
    #expect(parsed.headers["reply-to"] == "reply@example.com")
    #expect(parsed.headers["references"] == "<root@example.com> <parent@example.com>")
    #expect(parsed.headers["bcc"] == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains("hidden@example.com"))
    #expect(MIMEWriter.quotedPrintable(String(repeating: "é", count: 100)).components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
}

@Test func mimeWriterRejectsHeaderInjectionAndUnavailableAttachments() {
    var message = Message(id: "m", accountId: "a", threadId: "t", subject: "Hi\r\nBcc: injected@example.com", sender: EmailAddress(address: "a@example.com"), date: .now)
    #expect(throws: MIMEWriter.Failure.self) { try MIMEWriter.write(message: message, body: MessageBody(id: "m")) }
    message.subject = "Hello"
    #expect(throws: MIMEWriter.Failure.self) {
        try MIMEWriter.write(message: message, body: MessageBody(id: "m"), attachments: [Attachment(id: "file", filename: "file", mimeType: "text/plain", size: 1)])
    }
}
