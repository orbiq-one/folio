import Data
import Domain
import Foundation
import Testing
@testable import Features

@Test(arguments: [
    ("<https://example.com/unsubscribe>", "https://example.com/unsubscribe"),
    ("<https://example.com/unsubscribe?list=one,two>", "https://example.com/unsubscribe?list=one,two"),
    ("<mailto:leave@example.com?subject=unsubscribe>, <https://example.com/leave>", "mailto:leave@example.com?subject=unsubscribe"),
    ("<http://example.com/leave>, <https://example.com/leave>", "https://example.com/leave"),
    ("<javascript:alert(1)>", nil),
    ("<file:///tmp/private>", nil),
    ("<https://>", nil),
    ("<https://user:password@example.com/leave>", nil),
    ("<mailto:>", nil),
] as [(String, String?)])
func newsletterUnsubscribeOnlyOpensSupportedLinks(header: String, expected: String?) {
    #expect(NewsletterLink.unsubscribeURL(in: header)?.absoluteString == expected)
}

@Test @MainActor func activityOpensOnlySelectedItemAsSeenImmediately() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "me@example.com")))
    for (index, id) in ["older", "newer"].enumerated() {
        let message = Message(id: id, accountId: "a", threadId: "t", subject: "Weekly newsletter",
                              sender: EmailAddress(address: "newsletter@example.com"),
                              date: Date(timeIntervalSince1970: Double(index)), bodyId: id,
                              automationHeaders: ["list-unsubscribe": "<https://example.com/leave>", "list-id": "weekly.example.com"])
        try await repository.upsert(message, body: MessageBody(id: id, html: "<p>Weekly news</p>"))
    }
    let model = ThreadDetailModel(repository: repository, markReadDelay: .seconds(60))
    let observation = Task {
        await model.observe(ThreadSelection(accountId: "a", threadId: "t", messageId: "older"), activity: true)
    }
    defer { observation.cancel() }
    for _ in 0..<100 {
        if model.thread?.messages.first?.flags.contains(.read) == true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.thread?.messages.first?.flags.contains(.read) == true)
    #expect(model.thread?.messages.last?.flags.contains(.read) == false)
    #expect(model.expandedMessageIds == ["older"])
    #expect(model.newsletterMessage?.id == "older")
    #expect(model.unsubscribeURL?.absoluteString == "https://example.com/leave")
    #expect(model.thread?.state == nil)
}

@Test @MainActor func humanNewsletterDoesNotUseActivityReaderOrImmediateSeen() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .gmail, displayName: "A", email: EmailAddress(address: "me@example.com")))
    try await repository.upsert(Message(id: "m", accountId: "a", threadId: "t", subject: "Newsletter",
                                       sender: EmailAddress(address: "newsletter@example.com"), date: .now, bodyId: "b"),
                                body: MessageBody(id: "b", html: "<p>News</p>"))
    let model = ThreadDetailModel(repository: repository, markReadDelay: .seconds(60))
    let observation = Task { await model.observe(ThreadSelection(accountId: "a", threadId: "t")) }
    defer { observation.cancel() }
    for _ in 0..<100 {
        if model.thread != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.thread != nil)
    #expect(model.thread?.messages.first?.flags.contains(.read) == false)
    #expect(model.newsletterMessage == nil)
    #expect(model.unsubscribeURL == nil)
}
