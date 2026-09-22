import AppKit
import Data
import SwiftUI
import Testing
@testable import Features

@Test @MainActor func inlineReplyFillsResizedPaneWithoutGrowingControls() throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    let model = ThreadDetailModel(repository: repository)
    let host = NSHostingController(rootView: InlineReplyView(model: model, expandsToFill: true))
    for height in [240.0, 360.0, 500.0] {
        let size = host.sizeThatFits(in: CGSize(width: 600, height: height))
        #expect(abs(size.height - height) < 1)
        #expect(size.width <= 600)
    }
}

@Test @MainActor func inlineReplyKeepsCompactHeightInLargePanes() throws {
    let repository = SQLiteMailRepository(writer: try AppDatabase().writer)
    let model = ThreadDetailModel(repository: repository)
    let host = NSHostingController(rootView: InlineReplyView(model: model))
    for width in [360.0, 800.0, 1600.0] {
        let size = host.sizeThatFits(in: CGSize(width: width, height: 900))
        #expect(size.height >= 180)
        #expect(size.height <= 260)
        #expect(size.width <= width)
    }
}
