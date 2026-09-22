import Data
import Domain
import SwiftUI

@MainActor
public struct AccountsSettingsView: View {
    @State private var sidebar: MailboxSidebarModel
    @Bindable private var model: AccountModel
    @State private var showingAddAccount = false
    @State private var removal: Account?

    public init(repository: SQLiteMailRepository, model: AccountModel) {
        _sidebar = State(initialValue: MailboxSidebarModel(repository: repository))
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(sidebar.accounts, id: \.account.id) { group in
                    AccountSettingsRow(account: group.account, model: model, remove: { removal = group.account })
                }
            }
            .overlay { if sidebar.accounts.isEmpty { ContentUnavailableView("No Accounts", systemImage: "person.crop.circle") } }
            if let error = model.errorMessage ?? sidebar.errorMessage { Text(error).font(.callout).foregroundStyle(.secondary) }
            Button("Add Account…") { model.errorMessage = nil; showingAddAccount = true }
        }
        .padding(20)
        .frame(width: 560, height: 360)
        .task { await sidebar.observe() }
        .sheet(isPresented: $showingAddAccount) { AddAccountView(model: model) }
        .confirmationDialog("Remove this account?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { account in
            Button("Remove Account", role: .destructive) { Task { await model.removeAccount(id: account.id) }; removal = nil }
        } message: { _ in
            Text("Cached mail and sign-in tokens will be removed from this Mac. Mail on the server will not be deleted.")
        }
    }
}

@MainActor
private struct AccountSettingsRow: View {
    let account: Account
    @Bindable var model: AccountModel
    let remove: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                Text(account.email.address).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Sender name", text: $name, prompt: Text("Your name"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit(commit)
                .help("Shown as the From name on mail you send")
                .accessibilityLabel("Sender name for \(account.email.address)")
            Button("Remove…", role: .destructive, action: remove)
                .disabled(model.removing.contains(account.id))
        }
        .padding(.vertical, 4)
        .onAppear { name = account.email.name ?? "" }
        .onChange(of: account.email.name) { _, value in name = value ?? "" }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (account.email.name ?? "") else { return }
        Task { await model.setSenderName(trimmed, accountId: account.id) }
    }
}
