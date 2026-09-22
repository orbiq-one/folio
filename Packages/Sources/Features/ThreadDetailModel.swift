import AppKit
import Data
import Domain
import Foundation
import Observation

public enum InlineReplyMode: String, CaseIterable, Sendable {
    case reply = "Reply"
    case replyAll = "Reply All"
}

@MainActor @Observable
public final class ThreadDetailModel {
    public private(set) var thread: MailThread?
    public var expandedMessageIds: Set<String> = []
    public var inlineReplyText = ""
    public var inlineReplyMode: InlineReplyMode = .reply
    public private(set) var inlineComposeModel: ComposeModel?
    public let composeOriginId = UUID()
    public private(set) var isSendingInlineReply = false
    public private(set) var inlineReplyErrorMessage: String?
    public private(set) var allowsRemoteImages = false
    public private(set) var selfAddresses: Set<String> = []
    public private(set) var activityMessageId: String?
    public private(set) var isActivity = false

    public var newsletterMessage: Message? {
        guard isActivity, let thread,
              let message = thread.messages.first(where: { $0.id == activityMessageId }) ?? thread.messages.last,
              message.activityCategory == .newsletters,
              let bodyId = message.bodyId,
              let html = thread.bodies[bodyId]?.html, !html.isEmpty else { return nil }
        return message
    }

    public var unsubscribeURL: URL? {
        newsletterMessage.flatMap { NewsletterLink.unsubscribeURL(in: $0.automationHeaders["list-unsubscribe"]) }
    }

    public func unsubscribe() {
        guard let url = unsubscribeURL else { return }
        if !NSWorkspace.shared.open(url) { errorMessage = "Unable to open the unsubscribe link." }
    }

    public var hasRemoteImages: Bool {
        thread?.bodies.values.contains { Self.referencesRemoteImages($0.html ?? "") } ?? false
    }

    static func referencesRemoteImages(_ html: String) -> Bool {
        html.range(of: #"(?is)<img\b[^>]*\s+src\s*=\s*["']?https?://"#, options: .regularExpression) != nil
    }

    public func loadImages() { allowsRemoteImages = true }
    public var compose: @MainActor (ComposeRequest) -> Void = { ComposeRequest.open($0) }
    public func reply(to message: Message) { openCompose(.reply, message: message) }
    public func replyAll(to message: Message) { openCompose(.replyAll, message: message) }
    public func forward(_ message: Message) { openCompose(.forward, message: message) }
    private func openCompose(_ kind: ComposeRequest.Kind, message: Message, prefilledText: String? = nil) {
        compose(ComposeRequest(kind: kind, source: ThreadSelection(accountId: message.accountId, threadId: message.threadId),
                               messageId: message.id, prefilledText: prefilledText, inlineOrigin: composeOriginId))
    }

    nonisolated public static func isOutgoing(_ message: Message, selfAddresses: Set<String>) -> Bool {
        selfAddresses.contains(message.sender.address.lowercased())
    }

    public func isOutgoing(_ message: Message) -> Bool {
        Self.isOutgoing(message, selfAddresses: selfAddresses)
    }

    public var canSendInlineReply: Bool {
        thread?.messages.last != nil && !inlineReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSendingInlineReply
    }

    @discardableResult
    public func beginInlineCompose(_ request: ComposeRequest) -> Bool {
        guard request.inlineOrigin == nil || request.inlineOrigin == composeOriginId,
              inlineComposeModel == nil, inlineReplyText.isEmpty, !isSendingInlineReply else { return false }
        var request = request
        request.inlineOrigin = composeOriginId
        inlineComposeModel = ComposeModel(request: request, repository: repository, undo: undo)
        return true
    }

    public func receiveInlineTransfer(_ transfer: InlineComposeTransfer) {
        guard transfer.request.inlineOrigin == composeOriginId,
              inlineComposeModel == nil, inlineReplyText.isEmpty, !isSendingInlineReply,
              !isLoading, errorMessage == nil else { return }
        if beginInlineCompose(transfer.request) { transfer.accept() }
    }

    public func dismissInlineCompose() {
        inlineComposeModel = nil
    }

    public func openInlineReplyInCompose() {
        guard let message = thread?.messages.last else { return }
        let request = ComposeRequest(kind: inlineReplyMode == .replyAll ? .replyAll : .reply,
                                     source: ThreadSelection(accountId: message.accountId, threadId: message.threadId),
                                     messageId: message.id, prefilledText: inlineReplyText, forceWindow: true, inlineOrigin: composeOriginId)
        compose(request)
        inlineReplyText = ""
    }

    @discardableResult
    public func sendInlineReply() async -> Bool {
        guard let message = thread?.messages.last, canSendInlineReply else { return false }
        isSendingInlineReply = true
        defer { isSendingInlineReply = false }
        let request = ComposeRequest(kind: inlineReplyMode == .replyAll ? .replyAll : .reply,
                                     source: ThreadSelection(accountId: message.accountId, threadId: message.threadId),
                                     messageId: message.id, prefilledText: inlineReplyText)
        let model = ComposeModel(request: request, repository: repository, undo: undo)
        await model.load()
        guard await model.send() else {
            inlineReplyErrorMessage = model.errorMessage
            return false
        }
        inlineReplyText = ""
        inlineReplyErrorMessage = nil
        return true
    }
    public func star(_ message: Message) async {
        do {
            try await repository.perform(.changeFlags(messageId: message.id, flags: .starred,
                                                      enabled: !message.flags.contains(.starred)), accountId: message.accountId)
        } catch { errorMessage = error.localizedDescription }
    }
    public private(set) var errorMessage: String?
    public private(set) var isLoading = false
    private let repository: SQLiteMailRepository
    private let undo: UndoSendModel
    private let markReadDelay: Duration
    private var generation = UUID()
    private var markReadTask: Task<Void, Never>?

    public init(repository: SQLiteMailRepository, undo: UndoSendModel? = nil, markReadDelay: Duration = .seconds(2)) {
        self.repository = repository
        self.undo = undo ?? UndoSendModel()
        self.markReadDelay = markReadDelay
    }

    static func defaultReplyMode(for message: Message, selfAddresses: Set<String>) -> InlineReplyMode {
        let own = Set(selfAddresses.map { $0.lowercased() })
        let others = Set((message.to + message.cc + message.bcc).map { $0.address.lowercased() }.filter { !own.contains($0) })
        return others.count > 1 ? .replyAll : .reply
    }

    /// `showsState` false hides the conversation state, as mailbox views do.
    public func observe(_ selection: ThreadSelection?, activity: Bool = false, showsState: Bool = true) async {
        let generation = UUID()
        self.generation = generation
        markReadTask?.cancel()
        thread = nil
        isActivity = activity
        activityMessageId = selection?.messageId
        selfAddresses = []
        expandedMessageIds = []
        inlineReplyText = ""
        inlineReplyMode = .reply
        inlineReplyErrorMessage = nil
        allowsRemoteImages = false
        errorMessage = nil
        guard let selection else { isLoading = false; return }
        isLoading = true
        do {
            let selfAddresses = Set(try await repository.accounts().map { $0.email.address.lowercased() })
            self.selfAddresses = selfAddresses
            for try await observedThread in repository.observeThread(accountId: selection.accountId, threadId: selection.threadId) {
                var thread = observedThread
                if activity || !showsState { thread?.state = nil }
                guard !Task.isCancelled, self.generation == generation else { return }
                if let newestMessage = thread?.messages.last, newestMessage.id != self.thread?.messages.last?.id {
                    if let previous = self.thread?.messages.last?.id { expandedMessageIds.remove(previous) }
                    expandedMessageIds.insert(selection.messageId ?? newestMessage.id)
                    inlineReplyMode = Self.defaultReplyMode(for: newestMessage, selfAddresses: selfAddresses)
                }
                self.thread = thread
                isLoading = false
                markReadTask?.cancel()
                let unread = thread?.messages.filter {
                    !$0.flags.contains(.read) && (!activity || $0.id == (selection.messageId ?? thread?.messages.last?.id))
                } ?? []
                if !unread.isEmpty {
                    markReadTask = Task {
                        do {
                            if !activity { try await Task.sleep(for: markReadDelay) }
                            for message in unread {
                                try Task.checkCancellation()
                                try await repository.perform(.changeFlags(messageId: message.id, flags: .read, enabled: true),
                                                             accountId: message.accountId)
                            }
                        } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
