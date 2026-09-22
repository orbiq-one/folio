import Data
import Domain
import Foundation
import FoundationModels

public struct AssistantResult: Identifiable, Equatable, Sendable {
    public let message: Message
    public let excerpt: String
    public var id: String { message.accountId + ":" + message.id }
}

public enum ReplyStatus: Equatable, Sendable {
    case notReplied
    case replied(Date)

    /// Nil when the message is the user's own; otherwise whether the user wrote in the thread afterwards.
    static func of(_ message: Message, in thread: MailThread, accountEmail: String) -> ReplyStatus? {
        let accountEmail = accountEmail.lowercased()
        guard !StateInference.isSent(message, by: accountEmail) else { return nil }
        let reply = StateInference.firstReply(to: message, in: thread.messages, accountEmail: accountEmail)
        return reply.map { .replied($0.date) } ?? .notReplied
    }
}

public struct AssistantAnswer: Equatable, Sendable {
    public var summary: String?
    public var best: AssistantResult?
    public var replyStatus: ReplyStatus?
    public var conversationLength = 1
    public var results: [AssistantResult]
}

@Generable
struct MailSearchPlan {
    @Guide(description: "3 to 8 single-word search terms likely to appear in the matching email: nouns, names, and close synonyms or word forms. No stopwords, no question words.")
    var terms: [String]
}

@Generable
struct MailSearchReply {
    @Guide(description: "One or two short sentences answering the question from the emails, naming the sender. If no email answers it, say so plainly.")
    var answer: String
    @Guide(description: "Number of the single email that best answers the question, or 0 if none does.")
    var best: Int
    @Guide(description: "Numbers of the other emails related to the question, most relevant first. Empty if none are.")
    var relevant: [Int]
}

actor MailAssistant {
    private let repository: SQLiteMailRepository

    init(repository: SQLiteMailRepository) {
        self.repository = repository
    }

    nonisolated static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { true } else { false }
    }

    func ask(_ question: String) async throws -> AssistantAnswer {
        let usesModel = Self.isModelAvailable
        var terms = Self.keywords(in: question)
        if usesModel, let planned = try? await plan(question) {
            terms = Self.unique(planned.flatMap { Self.keywords(in: $0) } + terms)
        }
        let hits = try await repository.rankedSearch(anyOf: terms, limit: 12)
        var results = hits.map { AssistantResult(message: $0.message, excerpt: Self.excerpt($0.text)) }
        guard usesModel, !results.isEmpty, let reply = try? await answer(question, results: Array(results.prefix(8))) else {
            return AssistantAnswer(summary: nil, results: results)
        }
        func result(_ number: Int) -> AssistantResult? { results.indices.contains(number - 1) ? results[number - 1] : nil }
        let best = Self.bestResult(numbered: result(reply.best), answer: reply.answer, results: results)
        let relevant = reply.relevant.compactMap(result)
        let leading = Self.unique((best.map { [$0] } ?? []) + relevant, by: \.id)
        let ids = Set(leading.map(\.id))
        results = leading + results.filter { !ids.contains($0.id) }
        var answer = AssistantAnswer(summary: reply.answer, best: best, results: results.filter { $0.id != best?.id })
        if let best {
            async let loadedThread = repository.thread(accountId: best.message.accountId, threadId: best.message.threadId)
            async let accounts = repository.accounts()
            guard let thread = try await loadedThread else { return answer }
            let accountEmail = try await accounts.first { $0.id == best.message.accountId }?.email.address
            answer.replyStatus = best.message.activityCategory == nil
                ? accountEmail.flatMap { ReplyStatus.of(best.message, in: thread, accountEmail: $0) } : nil
            answer.conversationLength = thread.messages.filter { !$0.flags.contains(.draft) }.count
        }
        return answer
    }

    /// The model's pick, unless its answer names a different sender; then that sender's top email.
    static func bestResult(numbered: AssistantResult?, answer: String, results: [AssistantResult]) -> AssistantResult? {
        if let numbered, namedSender(in: answer, results: [numbered]) != nil { return numbered }
        return namedSender(in: answer, results: results) ?? numbered
    }

    static func namedSender(in answer: String, results: [AssistantResult]) -> AssistantResult? {
        let text = answer.lowercased()
        return results.first { result in
            guard let name = result.message.sender.name?.lowercased(), !name.isEmpty else { return false }
            return text.contains(name)
        }
    }

    private func plan(_ question: String) async throws -> [String] {
        let session = LanguageModelSession(instructions: """
            You turn a question about the user's email into search terms for a full-text index \
            of subjects, sender names, and message bodies.
            """)
        return try await session.respond(to: question, generating: MailSearchPlan.self).content.terms
    }

    private func answer(_ question: String, results: [AssistantResult]) async throws -> MailSearchReply {
        let emails = results.enumerated().map { index, result in
            let message = result.message
            return """
                [\(index + 1)] From: \(message.sender.name ?? message.sender.address) <\(message.sender.address)>
                Date: \(message.date.formatted(date: .abbreviated, time: .omitted))
                Subject: \(message.subject)
                Text: \(result.excerpt)
                """
        }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: """
            You answer questions about the user's email using only the numbered emails provided. \
            Be brief and factual. Never invent senders, dates, or details.
            """)
        return try await session.respond(to: "Emails:\n\(emails)\n\nQuestion: \(question)", generating: MailSearchReply.self).content
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "who", "what", "when", "where", "which", "why", "how", "did", "does",
        "has", "have", "had", "you", "your", "yours", "me", "my", "mine", "our", "ours", "about", "from", "with", "that",
        "this", "these", "those", "there", "their", "them", "they", "into", "onto", "any", "all", "can", "could", "would",
        "should", "will", "shall", "may", "might", "been", "being", "not", "but", "its", "his", "her", "hers", "him", "she",
        "asked", "ask", "asking", "tell", "told", "said", "say", "sent", "send", "email", "emails", "mail", "message",
        "messages", "someone", "anyone", "somebody", "next", "last", "year", "week", "month", "today", "yesterday",
        "tomorrow", "want", "wanted", "go", "going", "get", "got", "let", "also", "just", "please", "find", "show",
    ]

    static func keywords(in text: String) -> [String] {
        unique(text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) })
    }

    static func excerpt(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 280 ? String(collapsed.prefix(280)) + "…" : collapsed
    }

    private static func unique<Element, Key: Hashable>(_ elements: [Element], by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return elements.filter { seen.insert(key($0)).inserted }
    }

    private static func unique<Element: Hashable>(_ elements: [Element]) -> [Element] { unique(elements) { $0 } }
}

@MainActor @Observable
public final class AssistantModel {
    public var question = ""
    public private(set) var answer: AssistantAnswer?
    public private(set) var askedQuestion = ""
    public private(set) var isAsking = false
    public private(set) var errorMessage: String?
    public let usesModel = MailAssistant.isModelAvailable
    private let assistant: MailAssistant
    private var task: Task<Void, Never>?

    public init(repository: SQLiteMailRepository) {
        assistant = MailAssistant(repository: repository)
    }

    public func ask() {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        task?.cancel()
        askedQuestion = question
        isAsking = true
        errorMessage = nil
        task = Task {
            do {
                let answer = try await assistant.ask(question)
                guard !Task.isCancelled else { return }
                self.answer = answer
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isAsking = false
        }
    }

    public func reset() {
        task?.cancel()
        question = ""
        askedQuestion = ""
        answer = nil
        errorMessage = nil
        isAsking = false
    }
}
