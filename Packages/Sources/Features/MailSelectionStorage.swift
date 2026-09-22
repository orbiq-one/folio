import Data
import Domain
import Foundation

extension MailboxSelection {
    var storageValue: String {
        let parts: [String]
        switch self {
        case .unified(let kind): parts = ["unified", kind.rawValue]
        case .mailbox(let account, let mailbox): parts = ["mailbox", account, mailbox]
        case .view(let view): parts = ["view", view.rawValue]
        }
        return String(decoding: (try? JSONEncoder().encode(parts)) ?? Foundation.Data(), as: UTF8.self)
    }

    init?(storageValue: String) {
        guard let parts = try? JSONDecoder().decode([String].self, from: Foundation.Data(storageValue.utf8)) else { return nil }
        if parts.count == 2, parts[0] == "unified", let kind = MailboxKind(rawValue: parts[1]),
           [.inbox, .starred, .drafts, .sent].contains(kind) {
            self = .unified(kind)
        } else if parts.count == 2, parts[0] == "view", let view = ConversationView(rawValue: parts[1]) {
            self = .view(view)
        } else if parts.count == 3, parts[0] == "mailbox" {
            self = .mailbox(accountId: parts[1], mailboxId: parts[2])
        } else { return nil }
    }
}
