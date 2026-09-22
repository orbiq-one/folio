import AppKit
import Data
import Domain
import Foundation
import Observation

public struct ComposeRequest: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case newMessage, reply, replyAll, forward }
    public var id: UUID
    public var kind: Kind
    public var source: ThreadSelection?
    public var messageId: String?
    public var draftId: String?
    public var prefilledText: String?
    public var forceWindow: Bool
    public var inlineOrigin: UUID?
    public init(id: UUID = UUID(), kind: Kind = .newMessage, source: ThreadSelection? = nil, messageId: String? = nil,
                draftId: String? = nil, prefilledText: String? = nil, forceWindow: Bool = false, inlineOrigin: UUID? = nil) {
        self.id = id; self.kind = kind; self.source = source; self.messageId = messageId
        self.draftId = draftId; self.prefilledText = prefilledText; self.forceWindow = forceWindow
        self.inlineOrigin = inlineOrigin
    }
    public static let notification = Notification.Name("Folio.composeRequest")
    @MainActor public static func open(_ request: ComposeRequest) { NotificationCenter.default.post(name: notification, object: request) }
}

@MainActor
public final class InlineComposeTransfer {
    public static let notification = Notification.Name("Folio.returnComposeInline")
    public let request: ComposeRequest
    public private(set) var accepted = false

    public init(request: ComposeRequest) { self.request = request }
    public func accept() { accepted = true }
}

public enum ComposeAddressing {
    public static func parse(_ text: String) -> [EmailAddress] {
        text.split(separator: ",", omittingEmptySubsequences: true).map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            if let start = value.firstIndex(of: "<"), let end = value.lastIndex(of: ">"), start < end {
                return EmailAddress(address: String(value[value.index(after: start)..<end]), name: String(value[..<start]).trimmingCharacters(in: CharacterSet(charactersIn: " \"")))
            }
            return EmailAddress(address: value)
        }
    }
    public static func valid(_ address: EmailAddress) -> Bool {
        address.address.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }
    public static func replyRecipients(message: Message, selfAddresses: Set<String>, all: Bool) -> (to: [EmailAddress], cc: [EmailAddress]) {
        var used = Set(selfAddresses.map { $0.lowercased() })
        func unique(_ values: [EmailAddress]) -> [EmailAddress] { values.filter { used.insert($0.address.lowercased()).inserted } }
        let primary = message.replyTo.isEmpty ? [message.sender] : message.replyTo
        var to = unique(primary)
        if all { to += unique(message.to) }
        if to.isEmpty { to = unique(message.to) }
        let cc = all ? unique(message.cc) : []
        return (to, cc)
    }
}

@MainActor @Observable
public final class ComposeModel {
    public let request: ComposeRequest
    public private(set) var accounts: [Account] = []
    public var accountId = ""
    public var to = ""
    public var cc = ""
    public var bcc = ""
    public var replyTo = ""
    public var subject = ""
    public var text = NSAttributedString(string: "")
    public var plainText: String {
        get { text.string }
        set { text = NSAttributedString(string: newValue, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]) }
    }
    public var attachments: [Attachment] = []
    public private(set) var isLoaded = false
    public private(set) var isBusy = false
    public private(set) var isQueued = false
    public var errorMessage: String?
    public private(set) var savedAt: Date?
    public var hasUnsavedChanges: Bool { revision != savedRevision }
    public var canSend: Bool {
        let recipients = ComposeAddressing.parse(to) + ComposeAddressing.parse(cc) + ComposeAddressing.parse(bcc)
        let replyToRecipients = ComposeAddressing.parse(replyTo)
        return isLoaded && !isBusy && !isQueued && accounts.contains { $0.id == accountId && $0.provider != .mock }
            && !recipients.isEmpty
            && recipients.allSatisfy(ComposeAddressing.valid)
            && replyToRecipients.allSatisfy(ComposeAddressing.valid)
            && attachments.isEmpty
    }
    private let repository: SQLiteMailRepository
    private let undo: UndoSendModel
    private var original: Message?
    private var draftId: String
    private var revision = 0
    private var savedRevision = 0
    private var debounce: Task<Void, Never>?
    private var persistence: Task<Void, Error>?
    private var internetMessageId: String
    private var quotedHistory = ""

    public init(request: ComposeRequest, repository: SQLiteMailRepository, undo: UndoSendModel) {
        self.request = request; self.repository = repository; self.undo = undo
        draftId = request.draftId ?? "local-draft:\(request.id.uuidString)"
        internetMessageId = "<\(request.id.uuidString)@projectmail.local>"
    }

    public func load() async {
        guard !isLoaded else { return }
        do {
            let allAccounts = try await repository.accounts()
            let isMockSource = allAccounts.contains { $0.id == request.source?.accountId && $0.provider == .mock }
            accounts = allAccounts.filter {
                isMockSource ? $0.provider == .mock : ($0.provider == .imap || $0.provider == .jmap || $0.provider == .mock)
            }
            accountId = accounts.first { $0.id == request.source?.accountId }?.id ?? accounts.first?.id ?? ""
            if let source = request.source, let thread = try await repository.thread(accountId: source.accountId, threadId: source.threadId),
               let message = request.messageId.flatMap({ id in thread.messages.first { $0.id == id } }) ?? thread.messages.max(by: { $0.date < $1.date }) {
                let body = message.bodyId.flatMap { thread.bodies[$0] }
                if request.draftId != nil {
                    to = message.to.map(\.address).joined(separator: ", "); cc = message.cc.map(\.address).joined(separator: ", "); bcc = message.bcc.map(\.address).joined(separator: ", "); replyTo = message.replyTo.map(\.address).joined(separator: ", ")
                    subject = message.subject; internetMessageId = message.internetMessageId ?? internetMessageId
                    if let encoded = try await repository.syncCursor(accountId: accountId, scope: "compose-rich:\(draftId)"),
                       let data = Foundation.Data(base64Encoded: encoded),
                       let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                        text = rich
                    } else { text = Self.attributed(html: body?.html, fallback: body?.plainText ?? "") }
                    if let encoded = try await repository.syncCursor(accountId: accountId, scope: "compose-quote:\(draftId)"),
                       let data = Foundation.Data(base64Encoded: encoded) {
                        quotedHistory = String(decoding: data, as: UTF8.self)
                    }
                    original = message
                } else {
                    original = message
                    let recipients = ComposeAddressing.replyRecipients(message: message, selfAddresses: Set(allAccounts.map { $0.email.address }), all: request.kind == .replyAll)
                    if request.kind != .forward {
                        to = recipients.to.map(\.address).joined(separator: ", "); cc = recipients.cc.map(\.address).joined(separator: ", ")
                    }
                    let prefix = request.kind == .forward ? "Fwd:" : "Re:"
                    subject = message.subject.lowercased().hasPrefix(prefix.lowercased()) ? message.subject : "\(prefix) \(message.subject)"
                    let quote = body?.plainText ?? Self.attributed(html: body?.html, fallback: "").string
                    let lead = request.kind == .forward ? "Forwarded message from \(message.sender.address):" : "On \(message.date.formatted()), \(message.sender.address) wrote:"
                    let quoted = "\n\n\(lead)\n" + quote.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n")
                    if request.kind == .forward {
                        text = NSAttributedString(string: quoted, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
                    } else {
                        text = NSAttributedString(string: request.prefilledText ?? "", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
                        quotedHistory = quoted
                    }
                }
                if request.kind == .forward || request.draftId != nil { attachments = message.attachmentIds.compactMap { thread.attachments[$0] } }
            }
            isLoaded = true
            if accounts.isEmpty { errorMessage = "Add an IMAP or JMAP account to send messages." }
            if accounts.first(where: { $0.id == accountId })?.provider == .mock {
                errorMessage = "Mock account: drafts stay on this Mac and sending is disabled."
            }
        } catch { errorMessage = error.localizedDescription }
    }

    static func attributed(html: String?, fallback: String) -> NSAttributedString {
        // Import only local text; HTML import can otherwise retrieve remote resources.
        NSAttributedString(string: fallback.isEmpty ? (html ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) : fallback,
                           attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
    }

    public func changed() {
        guard isLoaded, !isQueued else { return }
        if revision == 0, to.isEmpty, cc.isEmpty, bcc.isEmpty, replyTo.isEmpty, subject.isEmpty, text.string.isEmpty { return }
        revision += 1; errorMessage = nil
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)); try Task.checkCancellation() } catch { return }
            _ = await self?.save()
        }
    }

    private func snapshot() throws -> (Message, MessageBody, Foundation.Data) {
        guard let account = accounts.first(where: { $0.id == accountId }) else { throw ComposeFailure.noAccount }
        let wireText = NSMutableAttributedString(attributedString: text)
        if !quotedHistory.isEmpty {
            wireText.append(NSAttributedString(string: quotedHistory, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]))
        }
        let htmlData = try wireText.data(from: NSRange(location: 0, length: wireText.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        let body = MessageBody(id: draftId, plainText: wireText.string, html: String(data: htmlData, encoding: .utf8))
        let reply = request.draftId == nil && (request.kind == .reply || request.kind == .replyAll)
        let references = reply ? (original?.references ?? []) + (original?.internetMessageId.map { [$0] } ?? []) : (request.draftId != nil ? original?.references ?? [] : [])
        let message = Message(id: draftId, accountId: account.id, threadId: draftId, subject: subject, sender: account.email,
            to: ComposeAddressing.parse(to), cc: ComposeAddressing.parse(cc), bcc: ComposeAddressing.parse(bcc), replyTo: ComposeAddressing.parse(replyTo), date: .now,
            internetMessageId: internetMessageId, inReplyTo: reply ? original?.internetMessageId : (request.draftId != nil ? original?.inReplyTo : nil),
            references: references, flags: [.draft], mailboxIds: ["local-drafts"], bodyId: draftId, attachmentIds: attachments.map(\.id))
        let rich = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return (message, body, rich)
    }

    private func store(_ message: Message, body: MessageBody, rich: Foundation.Data, attachments: [Attachment]) async throws {
        try await repository.upsert(Mailbox(id: "local-drafts", accountId: message.accountId, kind: .drafts, name: "Local Drafts"))
        try await repository.upsert(message, body: body, attachments: attachments)
        try await repository.setSyncCursor(rich.base64EncodedString(), accountId: message.accountId, scope: "compose-rich:\(message.id)")
        let quote = Foundation.Data(quotedHistory.utf8).base64EncodedString()
        try await repository.setSyncCursor(quote, accountId: message.accountId, scope: "compose-quote:\(message.id)")
    }

    public func save() async -> Bool {
        guard !isQueued else { return true }
        debounce?.cancel()
        while let inFlight = persistence {
            _ = try? await inFlight.value
            if persistence == inFlight { persistence = nil }
        }
        guard !isQueued else { return true }
        let currentRevision = revision
        do {
            let (message, body, rich) = try snapshot()
            let attachments = attachments
            let task = Task {
                try await self.store(message, body: body, rich: rich, attachments: attachments)
                if (message.to + message.cc + message.bcc + message.replyTo).allSatisfy(ComposeAddressing.valid), attachments.isEmpty {
                    try await self.repository.enqueue(.saveDraft(message: message, body: body, attachments: attachments), accountId: message.accountId)
                }
            }
            persistence = task; isBusy = true
            defer { if persistence == task { persistence = nil; isBusy = false } }
            try await task.value
            savedRevision = currentRevision; savedAt = .now; errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    public static let undoSendDelay: TimeInterval = 5

    public func send() async -> Bool {
        guard canSend else { errorMessage = "Check recipients and remove unavailable attachments before sending."; return false }
        debounce?.cancel()
        if let inFlight = persistence { _ = try? await inFlight.value; if persistence == inFlight { persistence = nil } }
        isBusy = true
        defer { isBusy = false }
        do {
            let (message, body, rich) = try snapshot()
            try await store(message, body: body, rich: rich, attachments: attachments)
            let deadline = Date().addingTimeInterval(ComposeModel.undoSendDelay)
            let row = try await repository.enqueue(.send(message: message, body: body, attachments: attachments), accountId: accountId, notBefore: deadline)
            let reopen = ComposeRequest(id: request.id, source: ThreadSelection(accountId: accountId, threadId: draftId), messageId: draftId, draftId: draftId)
            undo.track(row: row, accountId: accountId, deadline: deadline, request: reopen, repository: repository)
            isQueued = true; savedRevision = revision
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    public func openInWindow() async -> ComposeRequest? {
        await transferRequest(forceWindow: true)
    }

    public func returnToInline() async -> Bool {
        guard request.inlineOrigin != nil, let request = await transferRequest(forceWindow: false) else { return false }
        let transfer = InlineComposeTransfer(request: request)
        NotificationCenter.default.post(name: InlineComposeTransfer.notification, object: transfer)
        guard transfer.accepted else {
            errorMessage = "Open the original mail window and finish its inline draft before returning this draft."
            return false
        }
        return true
    }

    private func transferRequest(forceWindow: Bool) async -> ComposeRequest? {
        guard isLoaded, !isBusy, !isQueued, await save(),
              let account = accounts.first(where: { $0.id == accountId }) else { return nil }
        return ComposeRequest(id: request.id, kind: request.kind,
                              source: ThreadSelection(accountId: account.id, threadId: draftId),
                              messageId: draftId, draftId: draftId, forceWindow: forceWindow,
                              inlineOrigin: request.inlineOrigin)
    }

    public func discard() async -> Bool {
        debounce?.cancel()
        if let inFlight = persistence { _ = try? await inFlight.value; if persistence == inFlight { persistence = nil } }
        do {
            if savedAt != nil || request.draftId != nil {
                try await repository.enqueue(.deleteDraft(messageId: draftId), accountId: accountId)
                try await repository.deleteMessages(accountId: accountId, ids: [draftId])
            }
            savedRevision = revision
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

private enum ComposeFailure: LocalizedError {
    case noAccount
    var errorDescription: String? { "Select an IMAP or JMAP sending account." }
}
