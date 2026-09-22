import Data
import Domain
import Foundation
import Testing
@testable import Features

private func replyToRepository() async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .jmap, displayName: "A", email: EmailAddress(address: "self@example.com")))
    return repository
}

@Test @MainActor func draftReplyToPersistsAndReloads() async throws {
    let repository = try await replyToRepository()
    let model = ComposeModel(request: ComposeRequest(), repository: repository, undo: UndoSendModel())
    await model.load()
    model.to = "to@example.com"
    model.replyTo = "reply@example.com"
    #expect(await model.save())

    let row = try #require(try await repository.nextOutboxAction(accountId: "a"))
    guard case .saveDraft(let message, _, _) = row.action else { Issue.record("Expected draft"); return }
    #expect(message.replyTo.map(\.address) == ["reply@example.com"])

    let reopened = ComposeModel(request: ComposeRequest(source: ThreadSelection(accountId: "a", threadId: message.threadId), messageId: message.id, draftId: message.id), repository: repository, undo: UndoSendModel())
    await reopened.load()
    #expect(reopened.replyTo == "reply@example.com")
}

@Test @MainActor func malformedReplyToBlocksSend() async throws {
    let repository = try await replyToRepository()
    let model = ComposeModel(request: ComposeRequest(), repository: repository, undo: UndoSendModel())
    await model.load()
    model.to = "to@example.com"
    model.replyTo = "bad-address"
    #expect(!model.canSend)
    #expect(!(await model.send()))
}
