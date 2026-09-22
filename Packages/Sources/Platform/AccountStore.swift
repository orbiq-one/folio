import Data
import Domain
import Foundation

public actor AccountStore: AccountService {
    private let repository: SQLiteMailRepository
    private let tokens: any TokenStore
    private let oauth: OAuthSession
    private let session: URLSession
    private var syncs: [String: any AccountSync] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]
    private var currentStatus: [String: SyncStatus] = [:]
    private var subscribers: [UUID: AsyncStream<[String: SyncStatus]>.Continuation] = [:]
    private var started = false
    private var adding = false
    private var removing: Set<String> = []

    public init(repository: SQLiteMailRepository, clientId: String, tokens: any TokenStore = KeychainTokenStore(),
                session: URLSession = URLSession(configuration: .ephemeral)) {
        self.repository = repository
        self.tokens = tokens
        self.session = session
        oauth = OAuthSession(clientId: clientId, tokens: tokens, session: session)
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        do {
            for account in try await repository.accounts() { await installSync(accountId: account.id) }
        } catch { started = false; throw error }
    }

    public func addMockAccount() async throws {
        guard !adding, removing.isEmpty else { throw AccountStoreError.busy }
        adding = true
        defer { adding = false }
        guard try await !repository.accounts().contains(where: { $0.id == MockAccount.id }) else { return }
        do {
            try await MockAccount.populate(repository: repository)
        } catch {
            try await repository.removeAccount(id: MockAccount.id)
            throw error
        }
    }

    public func addAccount() async throws {
        guard !adding, removing.isEmpty else { throw AccountStoreError.busy }
        adding = true
        defer { adding = false }
        let credentials = try await oauth.signIn()
        let profile = try await GmailClient.profile(accessToken: credentials.accessToken, session: session)
        guard !profile.emailAddress.isEmpty else { throw URLError(.cannotParseResponse) }
        let id = "gmail:\(profile.emailAddress.lowercased())"
        guard !removing.contains(id) else { throw CancellationError() }
        let hadSync = syncs[id] != nil
        // Finish any old refresh before replacing credentials for a signed-in account.
        await stopSync(accountId: id)
        do {
            let previous = try await tokens.load(accountId: id)
            try await tokens.save(credentials, accountId: id)
            do {
                try Task.checkCancellation()
                try await repository.upsert(Account(id: id, provider: .gmail, displayName: profile.emailAddress,
                                                     email: EmailAddress(address: profile.emailAddress), capabilities: GmailMapping.capabilities))
            } catch {
                if let previous { try await tokens.save(previous, accountId: id) }
                else { try await tokens.delete(accountId: id) }
                throw error
            }
        } catch {
            if hadSync { await installSync(accountId: id) }
            throw error
        }
        await installSync(accountId: id)
    }

    public func addFastmailAccount(_ credentials: FastmailCredentials) async throws {
        guard !adding, removing.isEmpty else { throw AccountStoreError.busy }
        adding = true
        defer { adding = false }
        let jmap = try await FastmailClient.session(token: credentials.apiToken, session: session)
        let username = jmap.username.lowercased()
        guard username == credentials.email else { throw FastmailError.emailMismatch(jmap.username) }
        let id = "fastmail:\(username)"
        guard !removing.contains(id) else { throw CancellationError() }
        let hadSync = syncs[id] != nil
        await stopSync(accountId: id)
        do {
            let previous = try await tokens.load(accountId: id)
            try await tokens.save(OAuthTokens(accessToken: credentials.apiToken, refreshToken: "", expiresAt: .distantFuture), accountId: id)
            do {
                try Task.checkCancellation()
                let name = jmap.accounts[jmap.mailAccountId ?? ""]?.name ?? username
                try await repository.upsert(Account(id: id, provider: .jmap, displayName: name.isEmpty ? username : name,
                                                     email: EmailAddress(address: username), capabilities: FastmailClient.capabilities))
            } catch {
                if let previous { try await tokens.save(previous, accountId: id) }
                else { try await tokens.delete(accountId: id) }
                throw error
            }
        } catch {
            if hadSync { await installSync(accountId: id) }
            throw error
        }
        await installSync(accountId: id)
    }

    public func addIMAPAccount(_ credentials: IMAPCredentials) async throws {
        guard !adding, removing.isEmpty else { throw AccountStoreError.busy }
        guard credentials.isComplete else { throw IMAPError.invalidCredentials }
        adding = true
        defer { adding = false }
        let client = IMAPClient(credentials: credentials)
        do { try await client.connect(); await client.close() }
        catch { await client.close(); throw error }
        try Task.checkCancellation()
        let id = "imap:\(credentials.host.lowercased()):\(credentials.email)"
        let hadSync = syncs[id] != nil
        await stopSync(accountId: id)
        do {
            let previous = try await tokens.load(accountId: id)
            let encoded = String(decoding: try JSONEncoder().encode(credentials), as: UTF8.self)
            try await tokens.save(OAuthTokens(accessToken: encoded, refreshToken: "", expiresAt: .distantFuture), accountId: id)
            do {
                try Task.checkCancellation()
                try await repository.upsert(Account(id: id, provider: .imap, displayName: credentials.email,
                                                     email: EmailAddress(address: credentials.email, name: credentials.senderName), capabilities: [.serverSearch]))
            } catch {
                if let previous { try await tokens.save(previous, accountId: id) }
                else { try await tokens.delete(accountId: id) }
                throw error
            }
        } catch {
            if hadSync { await installSync(accountId: id) }
            throw error
        }
        await installSync(accountId: id)
    }

    public func setSenderName(_ name: String?, accountId: String) async throws {
        try await repository.setSenderName(name, accountId: accountId)
    }

    public func removeAccount(id: String) async throws {
        guard !adding, removing.insert(id).inserted else { throw AccountStoreError.busy }
        defer { removing.remove(id) }
        await stopSync(accountId: id)
        do {
            if id != MockAccount.id { try await tokens.delete(accountId: id) }
            try await repository.removeAccount(id: id)
            currentStatus[id] = nil
            publish()
        } catch {
            removing.remove(id)
            await installSync(accountId: id)
            throw error
        }
    }

    public func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for sync in syncs.values { group.addTask { try? await sync.synchronize() } }
        }
    }

    public func statuses() -> AsyncStream<[String: SyncStatus]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[String: SyncStatus]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(currentStatus)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    private func stopSync(accountId: String) async {
        watchers.removeValue(forKey: accountId)?.cancel()
        if let sync = syncs.removeValue(forKey: accountId) { await sync.stop() }
        currentStatus[accountId] = nil
        publish()
    }

    private func installSync(accountId: String) async {
        guard syncs[accountId] == nil,
              let account = try? await repository.accounts().first(where: { $0.id == accountId }),
              syncs[accountId] == nil, !removing.contains(accountId) else { return }
        let sync: any AccountSync
        switch account.provider {
        case .gmail:
            sync = GmailAccountSync(accountId: accountId, client: GmailClient(accountId: accountId, oauth: oauth, session: session),
                                    repository: repository)
        case .jmap:
            sync = JMAPAccountSync(accountId: accountId, client: JMAPClient(accountId: accountId, tokens: tokens, session: session),
                                  repository: repository)
        case .imap:
            guard let saved = try? await tokens.load(accountId: accountId),
                  let credentials = try? JSONDecoder().decode(IMAPCredentials.self, from: Foundation.Data(saved.accessToken.utf8)),
                  syncs[accountId] == nil, !removing.contains(accountId) else { return }
            sync = IMAPAccountSync(accountId: accountId, client: IMAPClient(credentials: credentials), repository: repository)
        default: return
        }
        syncs[accountId] = sync
        watchers[accountId] = Task { [weak self] in
            for await status in sync.status {
                guard !Task.isCancelled else { return }
                await self?.updateStatus(status, accountId: accountId)
            }
        }
        await sync.start()
    }

    private func updateStatus(_ status: SyncStatus, accountId: String) {
        guard syncs[accountId] != nil else { return }
        currentStatus[accountId] = status
        publish()
    }

    private func publish() { for continuation in subscribers.values { continuation.yield(currentStatus) } }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}

private enum AccountStoreError: LocalizedError {
    case busy
    var errorDescription: String? { "An account change is already in progress. Please wait for it to finish." }
}
