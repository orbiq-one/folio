import Foundation

public enum ComposePresentationMode: String, CaseIterable, Sendable {
    case auto = "auto"
    case inline = "inline"
    case window = "window"

    public static let storageKey = "mail.composePresentationMode"

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .inline: "Inline"
        case .window: "Window"
        }
    }

    public var description: String {
        switch self {
        case .auto: "Start replies in the compact split composer."
        case .inline: "Keep new messages, replies, and forwards in the main window."
        case .window: "Open every composer in a separate window."
        }
    }

    public static var stored: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .auto
    }
}
