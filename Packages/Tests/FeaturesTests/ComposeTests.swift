import AppKit
import Data
import Domain
import Foundation
import Testing
@testable import Features

private func composeRepository() async throws -> SQLiteMailRepository {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    try await repository.upsert(Account(id: "a", provider: .jmap, displayName: "A", email: EmailAddress(address: "self@example.com")))
    return repository
}

@Test func replyAllExcludesSelfAndDeduplicatesCaseInsensitiveRecipients() {
    let original = Message(id: "m", accountId: "a", threadId: "t", subject: "Topic", sender: EmailAddress(address: "author@example.com"),
        to: [EmailAddress(address: "SELF@example.com"), EmailAddress(address: "other@example.com")],
        cc: [EmailAddress(address: "Other@example.com"), EmailAddress(address: "cc@example.com")],
        bcc: [EmailAddress(address: "private@example.com")], replyTo: [EmailAddress(address: "reply@example.com")], date: .now)
    let values = ComposeAddressing.replyRecipients(message: original, selfAddresses: ["self@example.com"], all: true)
    #expect(values.to.map(\.address) == ["reply@example.com", "other@example.com"])
    #expect(values.cc.map(\.address) == ["cc@example.com"])
    #expect(!ComposeAddressing.valid(EmailAddress(address: "a@example.com\r\nBcc:x")))
    #expect(!ComposeAddressing.valid(EmailAddress(address: "not-an-address")))
}

@Test func outgoingMessageMatchesConfiguredAccountAddressesCaseInsensitively() {
    let message = Message(id: "m", accountId: "a", threadId: "t", subject: "Topic",
                          sender: EmailAddress(address: "SELF@example.com"), date: .now)
    #expect(ThreadDetailModel.isOutgoing(message, selfAddresses: ["self@example.com"]))
    #expect(!ThreadDetailModel.isOutgoing(message, selfAddresses: ["other@example.com"]))
}

@Test @MainActor func composeQueuesSendWithFifteenSecondWindowAndUndoDequeues() async throws {
    let repository = try await composeRepository()
    let undo = UndoSendModel()
    let model = ComposeModel(request: ComposeRequest(), repository: repository, undo: undo)
    await model.load()
    model.to = "to@example.com"; model.subject = "Hello"; model.text = NSAttributedString(string: "Body")
    #expect(model.canSend)
    let before = Date()
    #expect(await model.send())
    #expect(try await repository.nextOutboxAction(accountId: "a", now: before.addingTimeInterval(4)) == nil)
    let queued = try #require(try await repository.nextOutboxAction(accountId: "a", now: before.addingTimeInterval(6)))
    #expect(queued.notBefore.timeIntervalSince(before) >= 5)
    guard case .send(let message, let body, _) = queued.action else { Issue.record("Expected send"); return }
    #expect(message.to.map(\.address) == ["to@example.com"])
    #expect(body.plainText == "Body")
    let request = try #require(await undo.undo(queued.id))
    #expect(request.draftId == message.id)
    #expect(try await repository.nextOutboxAction(accountId: "a", now: .distantFuture) == nil)
    let reopened = ComposeModel(request: request, repository: repository, undo: undo)
    await reopened.load()
    #expect(reopened.subject == "Hello")
    #expect(reopened.text.string == "Body")
}

@Test @MainActor func savedReplyReloadsSendsAndUndoReopensDraft() async throws {
    let repository = try await composeRepository()
    let original = Message(id: "original", accountId: "a", threadId: "thread", subject: "Topic",
                           sender: EmailAddress(address: "author@example.com"), date: .now,
                           internetMessageId: "<original@example.com>", bodyId: "original")
    try await repository.upsert(original, body: MessageBody(id: "original", plainText: "Original"))
    let undo = UndoSendModel()
    let reply = ComposeModel(request: ComposeRequest(kind: .reply,
                                                     source: ThreadSelection(accountId: "a", threadId: "thread"),
                                                     messageId: "original"), repository: repository, undo: undo)
    await reply.load()
    reply.plainText = "Reply"
    #expect(await reply.save())
    let draft = try #require(try await repository.nextOutboxAction(accountId: "a"))
    guard case .saveDraft(let draftMessage, _, _) = draft.action else { Issue.record("Expected draft"); return }

    let reopened = ComposeModel(request: ComposeRequest(source: ThreadSelection(accountId: "a", threadId: draftMessage.threadId),
                                                        messageId: draftMessage.id, draftId: draftMessage.id),
                                repository: repository, undo: undo)
    await reopened.load()
    #expect(reopened.plainText == "Reply")
    #expect(await reopened.send())

    let pendingSave = try #require(try await repository.nextOutboxAction(accountId: "a", now: .now.addingTimeInterval(6)))
    guard case .saveDraft = pendingSave.action else { Issue.record("Expected saved draft before send"); return }
    try await repository.dequeueOutboxAction(id: pendingSave.id, accountId: "a")
    let send = try #require(try await repository.nextOutboxAction(accountId: "a", now: .now.addingTimeInterval(6)))
    guard case .send(let sentMessage, let sentBody, _) = send.action else { Issue.record("Expected send"); return }
    #expect(sentMessage.inReplyTo == "<original@example.com>")
    #expect(sentBody.plainText?.contains("Reply") == true)
    let undoRequest = try #require(await undo.undo(send.id))
    #expect(undoRequest.draftId == draftMessage.id)
    let reopenedAfterUndo = ComposeModel(request: undoRequest, repository: repository, undo: undo)
    await reopenedAfterUndo.load()
    #expect(reopenedAfterUndo.to == "author@example.com")
    #expect(reopenedAfterUndo.subject == "Re: Topic")
    #expect(reopenedAfterUndo.plainText == "Reply")
    #expect(try await repository.nextOutboxAction(accountId: "a", now: .distantFuture) == nil)
}

@Test @MainActor func composeSaveKeepsRichTextAndDraftOutboxAction() async throws {
    let repository = try await composeRepository()
    let model = ComposeModel(request: ComposeRequest(), repository: repository, undo: UndoSendModel())
    await model.load()
    model.subject = "Draft"; model.to = "to@example.com"
    model.text = NSAttributedString(string: "Bold text", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
    #expect(await model.save())
    let row = try #require(try await repository.nextOutboxAction(accountId: "a"))
    guard case .saveDraft(let message, let body, _) = row.action else { Issue.record("Expected draft"); return }
    #expect(body.html?.contains("Bold text") == true)
    let request = ComposeRequest(source: ThreadSelection(accountId: "a", threadId: message.threadId), messageId: message.id, draftId: message.id)
    let reopened = ComposeModel(request: request, repository: repository, undo: UndoSendModel())
    await reopened.load()
    let font = try #require(reopened.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
}

@Test @MainActor func composeReplyQuotesOriginalAndKeepsThreadingHeaders() async throws {
    let repository = try await composeRepository()
    let original = Message(id: "m", accountId: "a", threadId: "t", subject: "Topic", sender: EmailAddress(address: "author@example.com"), date: .now, internetMessageId: "<m@example.com>", references: ["<root@example.com>"], bodyId: "m")
    try await repository.upsert(original, body: MessageBody(id: "m", plainText: "Original text"))
    let model = ComposeModel(request: ComposeRequest(kind: .reply, source: ThreadSelection(accountId: "a", threadId: "t")), repository: repository, undo: UndoSendModel())
    await model.load()
    #expect(model.to == "author@example.com")
    #expect(model.subject == "Re: Topic")
    #expect(model.text.string.isEmpty)
    #expect(await model.save())
    let row = try #require(try await repository.nextOutboxAction(accountId: "a"))
    guard case .saveDraft(let message, let body, _) = row.action else { Issue.record("Expected draft"); return }
    #expect(body.plainText?.contains("> Original text") == true)
    #expect(message.inReplyTo == "<m@example.com>")
    #expect(message.references == ["<root@example.com>", "<m@example.com>"])
}

@Test @MainActor func poppedOutReplyRetainsOriginalThreadingWhenSavedAgain() async throws {
    let repository = try await composeRepository()
    let original = Message(id: "m", accountId: "a", threadId: "t", subject: "Topic",
                           sender: EmailAddress(address: "author@example.com"), date: .now,
                           internetMessageId: "<m@example.com>", references: ["<root@example.com>"], bodyId: "m")
    try await repository.upsert(original, body: MessageBody(id: "m", plainText: "Original text"))
    let model = ComposeModel(request: ComposeRequest(kind: .reply, source: ThreadSelection(accountId: "a", threadId: "t")),
                             repository: repository, undo: UndoSendModel())
    await model.load()
    model.plainText = "Inline reply"
    let request = try #require(await model.openInWindow())
    let window = ComposeModel(request: request, repository: repository, undo: UndoSendModel())
    await window.load()
    window.plainText = "Edited in window"
    #expect(await window.save())
    let source = try #require(request.source)
    let thread = try #require(try await repository.thread(accountId: source.accountId, threadId: source.threadId))
    let saved = try #require(thread.messages.first)
    #expect(saved.inReplyTo == "<m@example.com>")
    #expect(saved.references == ["<root@example.com>", "<m@example.com>"])
}

@Test @MainActor func composeRoundTripPreservesDraftAndRichEdits() async throws {
    let repository = try await composeRepository()
    let detail = ThreadDetailModel(repository: repository)
    detail.beginInlineCompose(ComposeRequest())
    let inline = try #require(detail.inlineComposeModel)
    await inline.load()
    inline.to = "to@example.com"
    inline.cc = "cc@example.com"
    inline.bcc = "bcc@example.com"
    inline.subject = "Round trip"
    inline.plainText = "Started inline"
    let request = try #require(await inline.openInWindow())
    #expect(request.inlineOrigin == detail.composeOriginId)
    detail.dismissInlineCompose()

    let window = ComposeModel(request: request, repository: repository, undo: UndoSendModel())
    await window.load()
    #expect(window.plainText == "Started inline")
    window.text = NSAttributedString(string: "Edited in window", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
    let observer = NotificationCenter.default.addObserver(forName: InlineComposeTransfer.notification, object: nil, queue: nil) { notification in
        guard let transfer = notification.object as? InlineComposeTransfer else { return }
        MainActor.assumeIsolated { detail.receiveInlineTransfer(transfer) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    #expect(await window.returnToInline())
    let returned = try #require(detail.inlineComposeModel)
    await returned.load()
    #expect(returned.request.id == request.id)
    #expect(returned.request.draftId == request.draftId)
    #expect(!returned.request.forceWindow)
    #expect(returned.to == "to@example.com")
    #expect(returned.cc == "cc@example.com")
    #expect(returned.bcc == "bcc@example.com")
    #expect(returned.subject == "Round trip")
    #expect(returned.plainText == "Edited in window")
    let font = try #require(returned.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    let secondPopout = try #require(await returned.openInWindow())
    #expect(secondPopout.draftId == request.draftId)
    #expect(secondPopout.inlineOrigin == detail.composeOriginId)
}

@Test @MainActor func inlineTransferRejectsWrongWindowAndOccupiedComposer() async throws {
    let repository = try await composeRepository()
    let detail = ThreadDetailModel(repository: repository)
    let wrong = InlineComposeTransfer(request: ComposeRequest(inlineOrigin: UUID()))
    detail.receiveInlineTransfer(wrong)
    #expect(!wrong.accepted)
    #expect(detail.inlineComposeModel == nil)

    detail.inlineReplyText = "Keep my other reply"
    let occupied = InlineComposeTransfer(request: ComposeRequest(inlineOrigin: detail.composeOriginId))
    detail.receiveInlineTransfer(occupied)
    #expect(!occupied.accepted)
    #expect(detail.inlineReplyText == "Keep my other reply")

    detail.inlineReplyText = ""
    detail.beginInlineCompose(ComposeRequest())
    let existing = detail.inlineComposeModel
    detail.receiveInlineTransfer(occupied)
    #expect(!occupied.accepted)
    #expect(detail.inlineComposeModel === existing)
}

@Test @MainActor func returnWithoutOriginalWindowKeepsSavedDraftOpen() async throws {
    let repository = try await composeRepository()
    let model = ComposeModel(request: ComposeRequest(inlineOrigin: UUID()), repository: repository, undo: UndoSendModel())
    await model.load()
    model.to = "to@example.com"
    model.plainText = "Keep this draft"
    #expect(await model.returnToInline() == false)
    #expect(model.errorMessage != nil)
    #expect(model.savedAt != nil)
    #expect(model.plainText == "Keep this draft")
    #expect(!model.isQueued)
}

@Test @MainActor func inlineReplyQueuesThreadedReplyAllWithHiddenQuotedHistory() async throws {
    let repository = try await composeRepository()
    let original = Message(
        id: "m", accountId: "a", threadId: "t", subject: "Topic",
        sender: EmailAddress(address: "author@example.com"),
        to: [EmailAddress(address: "self@example.com"), EmailAddress(address: "first@example.com")],
        cc: [EmailAddress(address: "second@example.com")], date: .now,
        internetMessageId: "<m@example.com>", references: ["<root@example.com>"], bodyId: "m"
    )
    try await repository.upsert(original, body: MessageBody(id: "m", plainText: "Original text"))
    let undo = UndoSendModel()
    let model = ThreadDetailModel(repository: repository, undo: undo)
    let observation = Task { await model.observe(ThreadSelection(accountId: "a", threadId: "t")) }
    defer { observation.cancel() }
    for _ in 0..<200 {
        if model.thread != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(model.inlineReplyMode == .replyAll)
    model.inlineReplyText = "My reply"
    #expect(await model.sendInlineReply())
    let queued = try #require(try await repository.nextOutboxAction(accountId: "a", now: .now.addingTimeInterval(16)))
    guard case .send(let message, let body, _) = queued.action else { Issue.record("Expected send"); return }
    #expect(message.to.map(\.address) == ["author@example.com", "first@example.com"])
    #expect(message.cc.map(\.address) == ["second@example.com"])
    #expect(message.inReplyTo == "<m@example.com>")
    #expect(message.references == ["<root@example.com>", "<m@example.com>"])
    #expect(body.plainText?.hasPrefix("My reply\n\nOn ") == true)
    #expect(body.plainText?.contains("> Original text") == true)
    #expect(model.inlineReplyText.isEmpty)
    #expect(undo.pending.map(\.id) == [queued.id])
}

@Test @MainActor func undoExpiredDeadlineCannotCancelAReadySend() async throws {
    let repository = try await composeRepository()
    let undo = UndoSendModel()
    let row = try await repository.enqueue(.deleteDraft(messageId: "local-draft:test"), accountId: "a")
    undo.track(row: row, accountId: "a", deadline: .now.addingTimeInterval(15), request: ComposeRequest(), repository: repository)
    #expect(await undo.undo(row, now: .now.addingTimeInterval(16)) == nil)
    #expect(try await repository.nextOutboxAction(accountId: "a") != nil)
    _ = await undo.undo(row)
}

@Test @MainActor func composeUsesAccountSenderName() async throws {
    let repository = try await composeRepository()
    try await repository.setSenderName("Ada Example", accountId: "a")
    let model = ComposeModel(request: ComposeRequest(), repository: repository, undo: UndoSendModel())
    await model.load()
    model.to = "to@example.com"; model.subject = "Hello"; model.text = NSAttributedString(string: "Body")
    #expect(await model.send())
    let queued = try #require(try await repository.nextOutboxAction(accountId: "a", now: .now.addingTimeInterval(6)))
    guard case .send(let message, _, _) = queued.action else { Issue.record("Expected send"); return }
    #expect(message.sender.name == "Ada Example")
}

@Test @MainActor func inlineDraftSurvivesNavigationAndAnotherComposeRequest() async throws {
    let repository = try await composeRepository()
    let detail = ThreadDetailModel(repository: repository)
    let request = ComposeRequest()
    #expect(detail.beginInlineCompose(request))
    weak var draft = detail.inlineComposeModel
    await draft?.load()
    draft?.to = "to@example.com"
    draft?.plainText = "Keep the edits before autosave"
    draft?.changed()

    await detail.observe(nil)
    #expect(draft != nil)
    #expect(detail.inlineComposeModel === draft)
    #expect(!detail.beginInlineCompose(ComposeRequest()))
    #expect(detail.inlineComposeModel?.plainText == "Keep the edits before autosave")
    #expect(await draft?.save() == true)
    let id = "local-draft:\(request.id.uuidString)"
    let stored = try #require(try await repository.thread(accountId: "a", threadId: id))
    #expect(stored.bodies[id]?.plainText == "Keep the edits before autosave")
}

@Test @MainActor func composeRequestsBelongToOnlyTheirOriginatingWindow() throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    let first = ThreadDetailModel(repository: repository)
    let second = ThreadDetailModel(repository: repository)
    let list = ThreadListModel(repository: repository, composeOriginId: first.composeOriginId)
    let observer = NotificationCenter.default.addObserver(forName: ComposeRequest.notification, object: nil, queue: nil) { notification in
        guard let request = notification.object as? ComposeRequest else { return }
        MainActor.assumeIsolated {
            first.beginInlineCompose(request)
            second.beginInlineCompose(request)
        }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    list.composeMessage(.newMessage)
    #expect(first.inlineComposeModel?.request.inlineOrigin == first.composeOriginId)
    #expect(second.inlineComposeModel == nil)
    first.dismissInlineCompose()
    let message = Message(id: "m", accountId: "a", threadId: "t", subject: "Hello",
                          sender: EmailAddress(address: "sender@example.com"), date: .now)
    first.reply(to: message)
    #expect(first.inlineComposeModel?.request.inlineOrigin == first.composeOriginId)
    #expect(second.inlineComposeModel == nil)
}
