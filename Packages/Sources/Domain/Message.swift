import Foundation

public struct MessageFlags: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let read = Self(rawValue: 1 << 0)
    public static let starred = Self(rawValue: 1 << 1)
    public static let draft = Self(rawValue: 1 << 2)
    public static let answered = Self(rawValue: 1 << 3)
}

public struct Message: Codable, Equatable, Sendable {
    public var id: String
    public var accountId: String
    public var threadId: String
    public var subject: String
    public var sender: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var date: Date
    public var internetMessageId: String?
    public var inReplyTo: String?
    public var references: [String]
    public var flags: MessageFlags
    public var mailboxIds: Set<String>
    public var bodyId: String?
    public var attachmentIds: [String]
    /// Lowercased subset of headers used by `TrafficClassifier`.
    public var automationHeaders: [String: String]
    public var activityCategory: ActivityCategory?

    public init(id: String, accountId: String, threadId: String, subject: String,
                sender: EmailAddress, to: [EmailAddress] = [], cc: [EmailAddress] = [],
                bcc: [EmailAddress] = [], replyTo: [EmailAddress] = [], date: Date,
                internetMessageId: String? = nil, inReplyTo: String? = nil,
                references: [String] = [], flags: MessageFlags = [],
                mailboxIds: Set<String> = [], bodyId: String? = nil, attachmentIds: [String] = [],
                automationHeaders: [String: String] = [:], activityCategory: ActivityCategory? = nil) {
        self.id = id
        self.accountId = accountId
        self.threadId = threadId
        self.subject = subject
        self.sender = sender
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.date = date
        self.internetMessageId = internetMessageId
        self.inReplyTo = inReplyTo
        self.references = references
        self.flags = flags
        self.mailboxIds = mailboxIds
        self.bodyId = bodyId
        self.attachmentIds = attachmentIds
        self.automationHeaders = automationHeaders
        self.activityCategory = activityCategory
    }
}

public struct MessageBody: Codable, Equatable, Sendable {
    public var id: String
    public var plainText: String?
    public var html: String?

    public init(id: String, plainText: String? = nil, html: String? = nil) {
        self.id = id
        self.plainText = plainText
        self.html = html
    }
}
