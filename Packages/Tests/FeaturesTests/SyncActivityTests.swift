import AppKit
import Domain
import SwiftUI
import Testing
@testable import Features

@Test
func syncActivityAggregatesProgressAndKeepsErrorsVisible() {
    #expect(!SyncActivity(status: ["a": .idle]).isVisible)
    let activity = SyncActivity(status: [
        "a": .syncing(SyncProgress(completed: 3, total: 10)),
        "b": .syncing(SyncProgress(completed: 4, total: 20)),
        "c": .error("Offline")
    ])
    #expect(activity.progress == SyncProgress(completed: 7, total: 30))
    #expect(activity.errors == ["Offline"])
    #expect(activity.isVisible && activity.isSyncing)
    let mixed = SyncActivity(status: ["a": .syncing(nil), "b": .syncing(SyncProgress(completed: 4, total: 20))])
    #expect(mixed.progress == nil && mixed.isSyncing)
    #expect(SyncActivity(status: ["a": .syncing(SyncProgress(completed: 0, total: 0))]).progress == nil)
    let error = SyncActivity(status: ["a": .error("Offline")])
    #expect(error.isVisible && !error.isSyncing)
}

