import Data
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
public final class UndoSendModel {
    public struct Pending: Identifiable {
        public let id: Int64
        public let accountId: String
        public let deadline: Date
        public let request: ComposeRequest
        let repository: SQLiteMailRepository
    }
    public private(set) var pending: [Pending] = []
    public var errorMessage: String?
    public var refresh: @MainActor () async -> Void = {}
    private var timers: [Int64: Task<Void, Never>] = [:]
    public init() {}

    public func track(row: Int64, accountId: String, deadline: Date, request: ComposeRequest, repository: SQLiteMailRepository) {
        pending.append(Pending(id: row, accountId: accountId, deadline: deadline, request: request, repository: repository))
        timers[row] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard let self else { return }
            pending.removeAll { $0.id == row }; timers[row] = nil
            await refresh()
        }
    }

    public func undo(_ id: Int64, now: Date = .now) async -> ComposeRequest? {
        guard let value = pending.first(where: { $0.id == id }), now < value.deadline else { return nil }
        do {
            guard try await value.repository.cancelScheduledOutboxAction(id: id, accountId: value.accountId) else {
                errorMessage = "The undo window has expired. The message may already be sending."
                return nil
            }
            timers.removeValue(forKey: id)?.cancel()
            pending.removeAll { $0.id == id }
            return value.request
        } catch { errorMessage = error.localizedDescription; return nil }
    }
}

public struct UndoSendBanner: View {
    @Bindable private var model: UndoSendModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(model: UndoSendModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(model.pending) { value in
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(ceil(value.deadline.timeIntervalSince(context.date))))
                    HStack(spacing: 14) {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(.secondary)
                        Text("Sending in \(remaining)s")
                            .monospacedDigit()
                        Button("Undo") { Task { if let request = await model.undo(value.id) { openWindow(value: request) } } }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .disabled(context.date >= value.deadline)
                            .keyboardShortcut("z", modifiers: .command)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
            }
        }
        .padding(.top, 12)
        .animation(reduceMotion ? nil : .snappy, value: model.pending.map(\.id))
    }
}
