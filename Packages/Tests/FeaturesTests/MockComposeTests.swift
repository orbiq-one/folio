import Data
import Domain
import Foundation
import Testing
@testable import Features

@Test @MainActor func mockReplyCannotSendThroughRealAccount() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "real", provider: .jmap, displayName: "Real", email: EmailAddress(address: "real@example.com")))
    try await repository.upsert(Account(id: "mock", provider: .mock, displayName: "Mock", email: EmailAddress(address: "mock@example.com")))
    try await repository.upsert(Message(id: "message", accountId: "mock", threadId: "thread", subject: "Sample",
        sender: EmailAddress(address: "friend@example.com"), date: .now))
    let model = ComposeModel(request: ComposeRequest(kind: .reply, source: ThreadSelection(accountId: "mock", threadId: "thread")),
                             repository: repository, undo: UndoSendModel())
    await model.load()
    #expect(model.accountId == "mock")
    #expect(model.accounts.map(\.id) == ["mock"])
    #expect(!model.canSend)
    model.accountId = "real"
    #expect(await model.send() == false)
    #expect(try await repository.nextOutboxAction(accountId: "real") == nil)
}
