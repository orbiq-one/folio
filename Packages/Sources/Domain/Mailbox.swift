import Foundation

public enum MailboxKind: String, Codable, Sendable {
    case inbox, sent, drafts, trash, spam, archive, starred, folder, label, virtual
}

public struct Mailbox: Codable, Equatable, Sendable {
    public var id: String
    public var accountId: String
    public var kind: MailboxKind
    public var name: String
    public var parentId: String?
    public var isHidden: Bool
    public var isSystem: Bool

    public init(id: String, accountId: String, kind: MailboxKind, name: String, parentId: String? = nil,
                isHidden: Bool = false, isSystem: Bool = false) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.name = name
        self.parentId = parentId
        self.isHidden = isHidden
        self.isSystem = isSystem
    }
}
