import Data
import Domain
import Foundation
import Testing
@testable import Platform

@Test func mockAccountIsLocalRepeatableAndRemovable() async throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    let tokens = MemoryTokenStore()
    let stub = HTTPStub { _ in
        Issue.record("Mock accounts must not make network requests")
        throw URLError(.notConnectedToInternet)
    }
    defer { stub.finish() }
    let store = AccountStore(repository: repository, clientId: "", tokens: tokens, session: stub.session)
    try await store.addMockAccount()
    let ids = try await repository.messageIds(accountId: MockAccount.id)
    #expect(ids.count >= 15)
    let minimums: [ConversationView: Int] = [.attention: 30, .waiting: 10, .later: 10, .done: 20]
    for (view, minimum) in minimums {
        let count = try await repository.conversations(in: view).count
        #expect(count >= minimum, "\(view): \(count)")
    }
    let activity = try await repository.activityMessages()
    #expect(activity.count >= 50, "activity: \(activity.count)")
    #expect(Set(activity.compactMap { $0.message.activityCategory }) == Set(ActivityCategory.allCases))
    try await store.addMockAccount()
    #expect(try await repository.accounts().count == 1)
    #expect(try await repository.messageIds(accountId: MockAccount.id) == ids)
    try await store.start()
    await store.refresh()
    #expect(await tokens.saves == 0)
    try await store.removeAccount(id: MockAccount.id)
    #expect(try await repository.accounts().isEmpty)
    #expect(try await repository.messageIds(accountId: MockAccount.id).isEmpty)
    #expect(try await repository.mailboxes(accountId: MockAccount.id).isEmpty)
    try await store.addMockAccount()
    #expect(try await repository.messageIds(accountId: MockAccount.id) == ids)
}
