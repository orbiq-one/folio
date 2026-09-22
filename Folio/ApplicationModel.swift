import Data
import Features
import Foundation
import Observation
import Platform

@MainActor @Observable
final class ApplicationModel {
    private(set) var repository: SQLiteMailRepository?
    private(set) var accounts: AccountModel?
    private(set) var errorMessage: String?
    private var store: AccountStore?

    init() { openDatabase() }

    func openDatabase() {
        do {
            // Pre-rename folder name; changing it would orphan the existing mail database.
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true).appending(path: "ProjectMail", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let database = try AppDatabase(path: support.appending(path: "mail.sqlite").path)
            let repository = SQLiteMailRepository(writer: database.writer)
            let store = AccountStore(repository: repository, clientId: Bundle.main.object(forInfoDictionaryKey: "GmailClientID") as? String ?? "")
            self.repository = repository
            self.store = store
            accounts = AccountModel(service: store)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func run() async {
        do { try await store?.start() }
        catch { errorMessage = error.localizedDescription }
        // [DEBUG-a4f2] temporary repro hook
        if CommandLine.arguments.contains("--debug-sign-in") {
            Task { _ = await accounts?.addAccount(); print("[DEBUG-a4f2] addAccount error: \(accounts?.errorMessage ?? "none")") }
        }
        await accounts?.observeStatus()
    }
}
