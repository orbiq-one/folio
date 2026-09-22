import Foundation

public struct EmailAddress: Codable, Hashable, Sendable {
    public var address: String
    public var name: String?

    public init(address: String, name: String? = nil) {
        self.address = address
        self.name = name
    }
}
