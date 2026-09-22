import Foundation

public struct Attachment: Codable, Equatable, Sendable {
    public var id: String
    public var filename: String
    public var mimeType: String
    public var size: Int64
    public var contentHash: String?

    public init(id: String, filename: String, mimeType: String, size: Int64, contentHash: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentHash = contentHash
    }
}
