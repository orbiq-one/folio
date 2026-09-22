import Domain

public protocol AccountSync: Actor, Sendable {
    nonisolated var status: AsyncStream<SyncStatus> { get }
    func start()
    func stop() async
    func synchronize() async throws
}
