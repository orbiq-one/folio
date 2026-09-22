import Domain
import Foundation

public struct ActivityFeedSection: Identifiable, Equatable, Sendable {
    public let category: ActivityCategory
    public let groups: [ActivityFeedGroup]
    public var id: ActivityCategory { category }

    public static func group(_ rows: [ThreadListRow]) -> [Self] {
        let order: [ActivityCategory] = [.orders, .money, .security, .notifications, .newsletters]
        return order.compactMap { category in
            let items = rows.filter { $0.activityCategory == category }.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return ($0.id.accountId, $0.id.messageId ?? $0.id.threadId) < ($1.id.accountId, $1.id.messageId ?? $1.id.threadId)
            }
            guard !items.isEmpty else { return nil }
            let grouped = Dictionary(grouping: items) { ActivityFeedGroup.ID(accountId: $0.id.accountId, address: $0.senderAddress.lowercased(), category: category) }
            var emitted = Set<ActivityFeedGroup.ID>()
            let groups = items.compactMap { row -> ActivityFeedGroup? in
                let key = ActivityFeedGroup.ID(accountId: row.id.accountId, address: row.senderAddress.lowercased(), category: category)
                guard emitted.insert(key).inserted, let senderRows = grouped[key] else { return nil }
                return ActivityFeedGroup(id: key, rows: senderRows)
            }
            return Self(category: category, groups: groups)
        }
    }
}

public struct ActivityFeedGroup: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let accountId: String
        public let address: String
        public let category: ActivityCategory
    }
    public let id: ID
    public let rows: [ThreadListRow]
    public var unseenCount: Int { rows.filter(\.isUnread).count }
    public var isCollapsedGroup: Bool { unseenCount > 3 }
}

public extension ActivityCategory {
    var title: String {
        switch self {
        case .orders: String(localized: "Orders")
        case .money: String(localized: "Money")
        case .security: String(localized: "Security")
        case .notifications: String(localized: "Notifications")
        case .newsletters: String(localized: "Newsletters")
        }
    }

    var symbol: String {
        switch self {
        case .orders: "shippingbox"
        case .money: "creditcard"
        case .security: "lock.shield"
        case .notifications: "bell"
        case .newsletters: "newspaper"
        }
    }
}
