import Foundation
import Synchronization
@testable import Platform

actor MemoryTokenStore: TokenStore {
    var values: [String: OAuthTokens]
    private(set) var saves = 0

    init(_ values: [String: OAuthTokens] = [:]) { self.values = values }
    func load(accountId: String) -> OAuthTokens? { values[accountId] }
    func save(_ tokens: OAuthTokens, accountId: String) { values[accountId] = tokens; saves += 1 }
    func delete(accountId: String) { values[accountId] = nil }
}

struct HTTPStub {
    let session: URLSession
    private let id: String

    init(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        self.init { request async throws in try handler(request) }
    }

    init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) {
        let id = UUID().uuidString
        self.id = id
        StubURLProtocol.handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-ID": id]
        session = URLSession(configuration: configuration)
    }

    func finish() {
        session.invalidateAndCancel()
        StubURLProtocol.handlers.withLock { $0[id] = nil }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlers = Mutex<[String: @Sendable (URLRequest) async throws -> (Int, Data)]>([:])
    private let loading = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        loading.withLock { task in
            task = Task {
                do {
                    guard let id = request.value(forHTTPHeaderField: "X-Test-ID"),
                          let handler = Self.handlers.withLock({ $0[id] }) else { throw URLError(.resourceUnavailable) }
                    let (status, data) = try await handler(request)
                    try Task.checkCancellation()
                    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
                }
            }
        }
    }

    override func stopLoading() { loading.withLock { $0?.cancel(); $0 = nil } }
}

func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

func requestBody(_ request: URLRequest) -> String {
    if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: data, as: UTF8.self)
}
