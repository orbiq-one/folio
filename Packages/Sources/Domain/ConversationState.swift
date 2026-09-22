import Foundation

public enum ConversationState: String, Codable, Sendable, CaseIterable {
    case attention, needsReply, waiting, later, done
}

/// The only state that cannot be inferred from server facts; the only rows that sync.
public struct ConversationOverride: Codable, Equatable, Sendable {
    public var accountId: String
    public var threadId: String
    public var state: ConversationState
    public var until: Date?
    public var setAt: Date

    public init(accountId: String, threadId: String, state: ConversationState, until: Date? = nil, setAt: Date = .now) {
        self.accountId = accountId
        self.threadId = threadId
        self.state = state
        self.until = until
        self.setAt = setAt
    }
}

public enum ConversationView: String, Codable, Sendable, CaseIterable {
    case attention, waiting, later, activity, done
}

public struct Conversation: Equatable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let accountId: String
        public let threadId: String
        public init(accountId: String, threadId: String) { self.accountId = accountId; self.threadId = threadId }
    }

    public var thread: MailThread
    public var kind: TrafficKind
    public var state: ConversationState?
    public var id: ID { ID(accountId: thread.accountId, threadId: thread.id) }

    public init(thread: MailThread, kind: TrafficKind, state: ConversationState?) {
        self.thread = thread
        self.kind = kind
        self.state = state
    }
}

public struct ConversationFacts: Sendable {
    public var accountEmail: String
    public var inboxMailboxIds: Set<String>
    public var hiddenMailboxIds: Set<String>

    public init(accountEmail: String, inboxMailboxIds: Set<String>, hiddenMailboxIds: Set<String>) {
        self.accountEmail = accountEmail.lowercased()
        self.inboxMailboxIds = inboxMailboxIds
        self.hiddenMailboxIds = hiddenMailboxIds
    }
}

public enum StateInference {
    /// `accountEmail` must be lowercased.
    public static func isSent(_ message: Message, by accountEmail: String) -> Bool {
        message.sender.address.lowercased() == accountEmail
    }

    /// The account owner's earliest non-draft message after `message`, if any.
    public static func firstReply(to message: Message, in messages: [Message], accountEmail: String) -> Message? {
        messages.filter { isSent($0, by: accountEmail) && !$0.flags.contains(.draft) && $0.date > message.date }
            .min { $0.date < $1.date }
    }

    /// `messages` in any order. Returns nil when the conversation is hidden or is Activity.
    public static func infer(messages: [Message], kinds: [String: TrafficKind], facts: ConversationFacts,
                             override: ConversationOverride?, now: Date = .now) -> (kind: TrafficKind, state: ConversationState?) {
        // Empty membership is Gmail's "archived", not hidden. Only Trash/Spam-only messages hide.
        let visible = messages.filter { !$0.flags.contains(.draft) }
        func isHidden(_ message: Message) -> Bool { !message.mailboxIds.isEmpty && message.mailboxIds.isSubset(of: facts.hiddenMailboxIds) }
        guard !visible.isEmpty, visible.contains(where: { !isHidden($0) }) else { return (.human, nil) }
        let sorted = visible.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        func isMine(_ message: Message) -> Bool { isSent(message, by: facts.accountEmail) }
        let inbound = sorted.filter { !isMine($0) }
        let kind = inbound.last.flatMap { kinds[$0.id] } ?? .human
        guard kind == .human else { return (.activity, nil) }
        let newest = sorted.last!
        let inInbox = visible.contains { !$0.mailboxIds.isDisjoint(with: facts.inboxMailboxIds) }
        let newestInbound = inbound.last

        if let override {
            let inboundAfterOverride = newestInbound.map { $0.date > override.setAt } ?? false
            let mineAfterOverride = sorted.contains { isMine($0) && $0.date > override.setAt }
            switch override.state {
            case .later:
                if let until = override.until, until > now, !inboundAfterOverride { return (kind, .later) }
            case .needsReply:
                if !mineAfterOverride, inInbox || newestInbound != nil { return (kind, .needsReply) }
            case .attention:
                if !inboundAfterOverride, !mineAfterOverride { return (kind, .attention) }
            case .done:
                if !inboundAfterOverride { return (kind, .done) }
            case .waiting:
                if !inboundAfterOverride { return (kind, .waiting) }
            }
        }
        if !inInbox { return (kind, .done) }
        if isMine(newest) { return (kind, .waiting) }
        return (kind, .attention)
    }

    public static func matches(_ state: ConversationState?, kind: TrafficKind, view: ConversationView) -> Bool {
        switch view {
        case .attention: kind == .human && (state == .attention || state == .needsReply)
        case .waiting: kind == .human && state == .waiting
        case .later: kind == .human && state == .later
        case .done: kind == .human && state == .done
        case .activity: kind == .activity
        }
    }
}
