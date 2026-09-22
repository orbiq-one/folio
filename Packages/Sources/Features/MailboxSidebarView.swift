import Data
import Domain
import SwiftUI

@MainActor
public struct MailboxSidebarView: View {
    @Bindable var model: MailboxSidebarModel
    let status: [String: SyncStatus]
    @AppStorage("mail.accountsExpanded") private var accountsExpanded = false

    public var body: some View {
        List(selection: $model.selection) {
            Section {
                ForEach([ConversationView.attention, .waiting, .later, .activity], id: \.self) { view in
                    viewRow(view)
                }
            }
            Section {
                mailboxLabel("Sent", symbol: symbol(.sent), count: 0, selection: .unified(.sent))
                    .tag(MailboxSelection.unified(.sent))
                mailboxLabel("Drafts", symbol: symbol(.drafts), count: model.unreadCounts[.unified(.drafts), default: 0], selection: .unified(.drafts))
                    .tag(MailboxSelection.unified(.drafts))
            }
            Section("Accounts", isExpanded: $accountsExpanded) {
                unifiedRow("All Inboxes", kind: .inbox)
                unifiedRow("Flagged", kind: .starred)
                ForEach(model.accounts, id: \.account.id) { group in
                    AccountMailboxGroup(account: group.account, unreadCount: group.mailboxes.filter { $0.kind == .inbox }.reduce(0) { $0 + model.unreadCounts[.mailbox(accountId: group.account.id, mailboxId: $1.id), default: 0] }) {
                        OutlineGroup(model.mailboxTrees[group.account.id] ?? [], children: \.children) { node in
                            mailboxLabel(node.title, symbol: symbol(node.mailbox.kind), count: model.unreadCounts[.mailbox(accountId: group.account.id, mailboxId: node.id), default: 0],
                                             selection: .mailbox(accountId: group.account.id, mailboxId: node.id))
                                .help(node.title)
                                .tag(MailboxSelection.mailbox(accountId: group.account.id, mailboxId: node.id))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .font(.system(size: 13))
        .toolbar(removing: .title)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary).padding() }
                if SyncActivity(status: status).isVisible { SyncActivityBar(activity: SyncActivity(status: status)) }
            }
        }
    }

    private func viewRow(_ view: ConversationView) -> some View {
        mailboxLabel(MailboxSidebarModel.title(for: view), symbol: MailboxSidebarModel.symbol(for: view),
                     count: view == .activity ? 0 : model.unreadCounts[.view(view), default: 0], selection: .view(view))
            .tag(MailboxSelection.view(view))
            .accessibilityLabel(accessibilityLabel(view))
    }

    private func accessibilityLabel(_ view: ConversationView) -> String {
        let count = model.unreadCounts[.view(view), default: 0]
        return count > 0 ? "\(MailboxSidebarModel.title(for: view)), \(count) conversations" : MailboxSidebarModel.title(for: view)
    }

    private func unifiedRow(_ title: String, kind: MailboxKind) -> some View {
        DisclosureGroup {
            ForEach(model.accounts, id: \.account.id) { group in
                ForEach(group.mailboxes.filter { $0.kind == kind && !$0.isHidden }, id: \.id) { mailbox in
                    mailboxLabel(group.account.displayName, symbol: symbol(kind), count: model.unreadCounts[.mailbox(accountId: group.account.id, mailboxId: mailbox.id), default: 0],
                                 selection: .mailbox(accountId: group.account.id, mailboxId: mailbox.id))
                        .tag(MailboxSelection.mailbox(accountId: group.account.id, mailboxId: mailbox.id))
                }
            }
        } label: {
            mailboxLabel(title, symbol: symbol(kind), count: model.unreadCounts[.unified(kind), default: 0], selection: .unified(kind))
                .tag(MailboxSelection.unified(kind))
        }
        .tag(MailboxSelection.unified(kind))
    }

    private func mailboxLabel(_ title: String, symbol: String, count: Int, selection: MailboxSelection? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .font(.system(size: 16))
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
                .fontWeight(Self.rowFontWeight(selection: selection, current: model.selection))
            Spacer(minLength: 2)
            if count > 0 {
                Text(count, format: .number)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func rowFontWeight(selection: MailboxSelection?, current: MailboxSelection?) -> Font.Weight {
        selection != nil && selection == current ? .semibold : .regular
    }

    private func symbol(_ kind: MailboxKind) -> String {
        switch kind {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .trash: "trash"
        case .spam: "xmark.bin"
        case .starred: "flag"
        case .archive: "archivebox"
        case .label: "tag"
        default: "folder"
        }
    }
}

private struct AccountMailboxGroup<Content: View>: View {
    let account: Account
    let unreadCount: Int
    @ViewBuilder let content: () -> Content
    @AppStorage private var isExpanded: Bool

    init(account: Account, unreadCount: Int, @ViewBuilder content: @escaping () -> Content) {
        self.account = account
        self.unreadCount = unreadCount
        self.content = content
        _isExpanded = AppStorage(wrappedValue: true, "mail.accountExpanded.\(account.id)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle").font(.system(size: 16)).foregroundStyle(.blue).frame(width: 18)
                Text(account.displayName).lineLimit(1)
                Spacer(minLength: 4)
                if !isExpanded && unreadCount > 0 { Text(unreadCount, format: .number).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .help(account.email.address)
        }
    }
}
