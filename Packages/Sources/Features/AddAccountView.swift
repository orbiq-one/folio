import Domain
import SwiftUI

@MainActor
public struct AddAccountView: View {
    enum Provider: String, CaseIterable, Identifiable {
        case google, fastmail, imap
        var id: Self { self }
        var title: String { switch self { case .google: "Google"; case .fastmail: "Fastmail"; case .imap: "IMAP" } }
    }

    @Bindable var model: AccountModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider = .google
    @State private var email = ""
    @State private var apiToken = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var username = ""
    @State private var senderName = ""
    @State private var security: IMAPCredentials.Security = .tls
    @State private var signIn: Task<Void, Never>?

    public init(model: AccountModel) { self.model = model }

    private var fastmailCredentials: FastmailCredentials { FastmailCredentials(email: email, apiToken: apiToken) }
    private var imapCredentials: IMAPCredentials {
        IMAPCredentials(email: email, host: host, port: Int(port) ?? 0, username: username, password: password, security: security, senderName: senderName)
    }
    private var canSubmit: Bool {
        !model.isAdding && (provider == .google || (provider == .fastmail ? fastmailCredentials.isComplete : imapCredentials.isComplete))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add an Account").font(.title2)
            Picker("Provider", selection: $provider) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().disabled(model.isAdding)
            switch provider {
            case .google:
                Text("Sign in securely with Google to sync your mail. Your password is never shared with Folio.")
                    .foregroundStyle(.secondary)
            case .imap:
                Form {
                    TextField("Name", text: $senderName, prompt: Text("Shown to recipients")).textContentType(.name)
                    TextField("Email", text: $email).textContentType(.username).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(.password)
                    TextField("Host", text: $host).autocorrectionDisabled()
                    TextField("Port", text: $port)
                    Picker("Security", selection: $security) {
                        Text("TLS").tag(IMAPCredentials.Security.tls)
                        Text("STARTTLS").tag(IMAPCredentials.Security.startTLS)
                    }
                    TextField("Username", text: $username, prompt: Text(email)).autocorrectionDisabled()
                }
                .formStyle(.grouped).frame(height: 310).disabled(model.isAdding)
                Text("Receiving mail only. Sending via SMTP is not yet supported.").font(.callout).foregroundStyle(.secondary)
            case .fastmail:
                Form {
                    TextField("Email", text: $email, prompt: Text("you@fastmail.com"))
                        .textContentType(.username).autocorrectionDisabled()
                    SecureField("API Token", text: $apiToken, prompt: Text("fmu1-…"))
                        .textContentType(.password)
                }
                .formStyle(.columns).disabled(model.isAdding)
                Text("Use an API token, not your account or app password. Create one at fastmail.com under Settings › Privacy & Security › Connected apps & API tokens › Manage API tokens, with Mail read/write access.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button("Show Mock Data", systemImage: "tray.full") {
                    signIn = Task {
                        if await model.addMockAccount() { dismiss() }
                    }
                }
                .disabled(model.isAdding)
                Text("Explore sample emails and folders in a local mock account. No sign-in required; no mail is sent. Remove it anytime in Settings › Accounts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if model.isAdding { ProgressView().controlSize(.small).accessibilityLabel("Adding Account") }
                Spacer()
                Button("Cancel") { signIn?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(provider == .google ? "Sign in with Google" : provider == .fastmail ? "Add Fastmail Account" : "Add IMAP Account") { submit() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: provider) { model.errorMessage = nil }
        .onDisappear { signIn?.cancel() }
    }

    private func submit() {
        let credentials = fastmailCredentials
        signIn = Task {
            let added = switch provider {
            case .google: await model.addAccount()
            case .fastmail: await model.addFastmailAccount(credentials)
            case .imap: await model.addIMAPAccount(imapCredentials)
            }
            if added { dismiss() }
        }
    }
}
