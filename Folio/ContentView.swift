import Features
import SwiftUI

struct ContentView: View {
    let application: ApplicationModel
    @State private var showingAddAccount = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ListTextSize.storageKey) private var listTextSize = ListTextSize.standard

    var body: some View {
        Group {
            if let repository = application.repository, let accounts = application.accounts {
                MailView(repository: repository, accounts: accounts, showingAddAccount: $showingAddAccount)
                    .task { await application.run() }
            } else {
                ContentUnavailableView {
                    Label("Unable to Open Mail", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(application.errorMessage ?? "The local database could not be opened.")
                } actions: {
                    Button("Try Again") { application.openDatabase() }
                }
                .frame(minWidth: 500, minHeight: 300)
            }
        }
        .background {
            // ⌘= alias for Make Text Bigger, since "+" needs Shift on most layouts.
            Button { listTextSize = ListTextSize.step(listTextSize, by: 1) } label: { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .focusedSceneValue(\.addAccount, { application.accounts?.errorMessage = nil; showingAddAccount = true })
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await application.accounts?.refresh() } }
        }
    }
}

private struct AddAccountKey: FocusedValueKey {
    typealias Value = @MainActor () -> Void
}

extension FocusedValues {
    var addAccount: (@MainActor () -> Void)? {
        get { self[AddAccountKey.self] }
        set { self[AddAccountKey.self] = newValue }
    }
}
