import Data
import Domain
import SwiftUI

public struct ThreadWindowRequest: Hashable, Codable, Sendable {
    public let selection: ThreadSelection
    public let isActivity: Bool
    public let showsState: Bool

    public init(selection: ThreadSelection, isActivity: Bool, showsState: Bool) {
        self.selection = selection
        self.isActivity = isActivity
        self.showsState = showsState
    }
}

@MainActor
public struct ThreadWindowView: View {
    let request: ThreadWindowRequest
    @State private var detail: ThreadDetailModel
    @Environment(\.openWindow) private var openWindow

    public init(request: ThreadWindowRequest, repository: SQLiteMailRepository, undoSend: UndoSendModel) {
        self.request = request
        _detail = State(initialValue: ThreadDetailModel(repository: repository, undo: undoSend))
    }

    private var latestMessage: Message? { detail.thread?.messages.last }

    public var body: some View {
        ThreadDetailView(model: detail)
            .frame(minWidth: 480, minHeight: 360)
            .navigationTitle(latestMessage?.subject ?? "")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { latestMessage.map(detail.reply(to:)) } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Reply")
                    .disabled(latestMessage == nil)
                    Button { latestMessage.map(detail.replyAll(to:)) } label: {
                        Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
                    }
                    .help("Reply All")
                    .disabled(latestMessage == nil)
                    Button { latestMessage.map(detail.forward) } label: {
                        Label("Forward", systemImage: "arrowshape.turn.up.right")
                    }
                    .help("Forward")
                    .disabled(latestMessage == nil)
                }
            }
            .focusedSceneValue(\.threadDetail, detail)
            .onReceive(NotificationCenter.default.publisher(for: ComposeRequest.notification)) { notification in
                guard let compose = notification.object as? ComposeRequest,
                      compose.inlineOrigin == detail.composeOriginId else { return }
                openWindow(value: compose)
            }
            .task {
                await detail.observe(request.selection, activity: request.isActivity, showsState: request.showsState)
            }
    }
}
