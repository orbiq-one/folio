import Domain
import Observation

@MainActor @Observable
public final class AccountModel {
    public private(set) var status: [String: SyncStatus] = [:]
    public private(set) var isAdding = false
    public private(set) var removing: Set<String> = []
    public var errorMessage: String?
    private let service: any AccountService

    public var isSyncing: Bool { status.values.contains(where: \.isSyncing) }

    public init(service: any AccountService) { self.service = service }

    public func observeStatus() async {
        for await status in await service.statuses() {
            guard !Task.isCancelled else { return }
            self.status = status
        }
    }

    public func addMockAccount() async -> Bool {
        guard !isAdding else { return false }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do { try await service.addMockAccount(); return true }
        catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }

    public func addAccount() async -> Bool {
        guard !isAdding else { return false }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do { try await service.addAccount(); return true }
        catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }

    public func addFastmailAccount(_ credentials: FastmailCredentials) async -> Bool {
        guard !isAdding else { return false }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do { try await service.addFastmailAccount(credentials); return true }
        catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }

    public func addIMAPAccount(_ credentials: IMAPCredentials) async -> Bool {
        guard !isAdding else { return false }
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }
        do { try await service.addIMAPAccount(credentials); return true }
        catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }

    public func removeAccount(id: String) async {
        guard removing.insert(id).inserted else { return }
        defer { removing.remove(id) }
        do { try await service.removeAccount(id: id) }
        catch { errorMessage = error.localizedDescription }
    }

    public func setSenderName(_ name: String, accountId: String) async {
        do { try await service.setSenderName(name, accountId: accountId) }
        catch { errorMessage = error.localizedDescription }
    }

    public func refresh() async { await service.refresh() }
}
