import Domain
import SwiftUI

extension ConversationState {
    var tint: Color {
        switch self {
        case .attention: .red
        case .needsReply: .orange
        case .waiting: .blue
        case .later: .purple
        case .done: .green
        }
    }
}
