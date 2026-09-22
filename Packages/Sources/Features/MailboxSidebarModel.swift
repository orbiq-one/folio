import Data
import Domain
import Foundation
import Observation

public struct MailboxNode: Identifiable, Equatable {
    public let mailbox: Mailbox
    public let title: String
    public let children: [MailboxNode]?
    public var id: String { mailbox.id }
}

@MainActor @Observable
public final class MailboxSidebarModel {
    public var selection: MailboxSelection? = .view(.attention)
    public private(set) var accounts: [AccountMailboxes] = []
    public private(set) var mailboxTrees: [String: [MailboxNode]] = [:]
    public var showsAllAccounts: Bool { true }
    public var title: String {
        switch selection {
        case .view(let view): Self.title(for: view)
        case .unified(let kind):
            switch kind {
            case .inbox: "All Inboxes"
            case .starred: "Flagged"
            case .drafts: "All Drafts"
            case .sent: "All Sent"
            default: kind.rawValue.capitalized
            }
        case .mailbox(let accountId, let mailboxId):
            if let group = accounts.first(where: { $0.account.id == accountId }),
               let mailbox = group.mailboxes.first(where: { $0.id == mailboxId }) {
                "\(mailbox.name) – \(group.account.displayName)"
            } else { "Messages" }
        case nil: "No Mailbox Selected"
        }
    }
    public private(set) var errorMessage: String?
    public private(set) var isLoading = true

    public static func title(for view: ConversationView) -> String {
        switch view {
        case .attention: "Attention"
        case .waiting: "Waiting"
        case .later: "Later"
        case .activity: "Activity"
        case .done: "Done"
        }
    }

    public static func symbol(for view: ConversationView) -> String {
        switch view {
        case .attention: "circle.inset.filled"
        case .waiting: "hourglass"
        case .later: "clock"
        case .activity: "bell.badge"
        case .done: "checkmark.circle"
        }
    }
    public private(set) var unreadCounts: [MailboxSelection: Int] = [:]

    public func observeUnreadCounts() async {
        do {
            for try await counts in repository.observeUnreadCounts() {
                guard !Task.isCancelled else { return }
                unreadCounts = counts
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
    private let repository: SQLiteMailRepository

    public init(repository: SQLiteMailRepository) { self.repository = repository }

    public func observe() async {
        do {
            for try await accounts in repository.observeAccounts() {
                guard !Task.isCancelled else { return }
                self.accounts = accounts
                mailboxTrees = Dictionary(uniqueKeysWithValues: accounts.map { ($0.account.id, Self.tree($0.mailboxes)) })
                isLoading = false
                errorMessage = nil
                if case .mailbox(let accountId, let mailboxId) = selection,
                   !accounts.contains(where: { $0.account.id == accountId && $0.mailboxes.contains(where: { $0.id == mailboxId && !$0.isHidden }) }) {
                    if accounts.count == 1, let group = accounts.first {
                        selection = mailboxTrees[group.account.id]?.first.map { .mailbox(accountId: group.account.id, mailboxId: $0.id) }
                    } else { selection = .view(.attention) }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private static func tree(_ mailboxes: [Mailbox]) -> [MailboxNode] {
        let visible = mailboxes.filter { !$0.isHidden }.sorted { left, right in
            let leftRank = rank(left), rightRank = rank(right)
            if leftRank != rightRank { return leftRank < rightRank }
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
        let visibleIds = Set(visible.map(\.id))
        let children = Dictionary(grouping: visible.filter { $0.parentId != nil }, by: { $0.parentId! })
        func node(_ mailbox: Mailbox, nested: Bool) -> MailboxNode {
            let descendants = (children[mailbox.id] ?? []).map { node($0, nested: true) }
            return MailboxNode(mailbox: mailbox, title: nested ? mailbox.name.components(separatedBy: "/").last ?? mailbox.name : mailbox.name,
                               children: descendants.isEmpty ? nil : descendants)
        }
        return visible.filter { $0.parentId == nil || !visibleIds.contains($0.parentId!) }.map { node($0, nested: false) }
    }

    private static func rank(_ mailbox: Mailbox) -> Int {
        switch mailbox.kind {
        case .inbox: 0
        case .starred: 1
        case .drafts: 2
        case .sent: 3
        case .spam: 4
        case .trash: 5
        default: mailbox.isSystem ? 6 : 7
        }
    }
}
