import Domain
import SwiftUI

struct SyncActivity: Equatable {
    var isSyncing = false
    var progress: SyncProgress?
    var errors: [String] = []
    var isVisible: Bool { isSyncing || !errors.isEmpty }

    init(status: [String: SyncStatus]) {
        var completed = 0
        var total = 0
        var isIndeterminate = false
        for id in status.keys.sorted() {
            switch status[id] {
            case .syncing(let progress):
                isSyncing = true
                if let progress, progress.total > 0 {
                    completed += min(max(progress.completed, 0), progress.total)
                    total += progress.total
                } else {
                    isIndeterminate = true
                }
            case .error(let message): errors.append(message)
            default: break
            }
        }
        if isSyncing && !isIndeterminate { progress = SyncProgress(completed: completed, total: total) }
    }
}

@MainActor
struct SyncActivityBar: View {
    let activity: SyncActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if activity.isSyncing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).accessibilityLabel("Checking for Mail")
                    if let progress = activity.progress {
                        Text("Syncing \(progress.completed) of \(progress.total)").monospacedDigit()
                    } else {
                        Text("Checking for Mail…")
                    }
                    Spacer(minLength: 0)
                }
            }
            ForEach(Array(activity.errors.enumerated()), id: \.offset) { _, message in
                Label(message, systemImage: "exclamationmark.triangle")
                    .lineLimit(2).help(message)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
