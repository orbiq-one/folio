import SwiftUI

@MainActor
public struct AvatarView: View {
    let name: String
    let address: String
    var size: CGFloat = 32

    public init(name: String, address: String, size: CGFloat = 32) {
        self.name = name
        self.address = address
        self.size = size
    }

    static func initials(name: String, address: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        if let first = words.first, let last = words.last, words.count > 1 {
            return String(first.prefix(1) + last.prefix(1)).uppercased()
        }
        return String((words.first.map(String.init) ?? address).prefix(1)).uppercased()
    }

    static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo]

    static func colorIndex(address: String) -> Int {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8.reduce(0) { ($0 * 31 + Int($1)) % palette.count }
    }

    public var body: some View {
        Text(Self.initials(name: name, address: address))
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Self.palette[Self.colorIndex(address: address)].opacity(0.22), in: Circle())
            .accessibilityHidden(true)
    }
}
