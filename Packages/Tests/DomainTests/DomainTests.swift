import Domain
import Foundation
import Testing

@Test func messageHasValueSemantics() {
    let original = Message(id: "m", accountId: "a", threadId: "t", subject: "Hello",
                           sender: EmailAddress(address: "sender@example.com"), date: Date(timeIntervalSince1970: 100),
                           mailboxIds: ["inbox"], attachmentIds: ["file"])
    var copy = original
    copy.flags.insert(.read)
    copy.mailboxIds.insert("label")
    copy.attachmentIds.append("second")
    copy.sender.name = "Changed"
    #expect(original.flags.isEmpty)
    #expect(original.mailboxIds == ["inbox"])
    #expect(original.attachmentIds == ["file"])
    #expect(original.sender.name == nil)
    #expect(copy != original)
}

@Test func flagsAndCapabilitiesCompose() {
    var flags: MessageFlags = [.read, .starred]
    flags.remove(.read)
    #expect(flags == .starred)
    let capabilities: ProviderCapabilities = [.labels, .drafts, .serverSearch]
    #expect(capabilities.contains(.labels))
    #expect(!capabilities.contains(.push))
    #expect(SyncStatus.syncing(nil).isSyncing)
    #expect(SyncStatus.syncing(SyncProgress(completed: 1, total: 2)).isSyncing)
    #expect(!SyncStatus.idle.isSyncing)
    #expect(!SyncStatus.error("Offline").isSyncing)
}
