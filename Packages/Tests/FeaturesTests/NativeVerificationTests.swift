import AppKit
import Data
import Foundation
import SwiftUI
import Testing
@testable import Features

@Test @MainActor func listShortcutsNeverConsumeTextEditingOrCommandCombinations() {
    let shortcuts: [(String, MailListShortcut)] = [("j", .next), ("k", .previous), ("e", .done), ("l", .later), ("s", .flag), ("r", .reply), ("c", .compose)]
    for (key, expected) in shortcuts {
        #expect(MailListShortcut.resolve(key, modifiers: [], isEditingText: false) == expected)
        #expect(MailListShortcut.resolve(key, modifiers: [], isEditingText: true) == nil)
        for modifiers in [EventModifiers.command, .option, .control, .shift] where !(modifiers == .shift && key == "r") {
            #expect(MailListShortcut.resolve(key, modifiers: modifiers, isEditingText: false) == nil)
        }
    }
    for key in ["U", "u", "I", "i"] {
        #expect(MailListShortcut.resolve(key, modifiers: .shift, isEditingText: false) == (key.lowercased() == "u" ? .unread : .read))
        #expect(MailListShortcut.resolve(key, modifiers: .shift, isEditingText: true) == nil)
    }
    #expect(MailListShortcut.isEditingText(NSTextView()))
    #expect(MailListShortcut.isEditingText(NSSearchField()))
    #expect(MailListShortcut.isEditingText(NSTextField()))
    #expect(!MailListShortcut.isEditingText(NSButton()))
}

@Test @MainActor func selectedSidebarRowsUseSemiboldEmphasisWithoutChangingNativeSelection() {
    let selection = MailboxSelection.view(.attention)
    #expect(MailboxSidebarView.rowFontWeight(selection: selection, current: selection) == .semibold)
    #expect(MailboxSidebarView.rowFontWeight(selection: .view(.waiting), current: selection) == .regular)
    #expect(MailboxSidebarView.rowFontWeight(selection: nil, current: nil) == .regular)
}

@Test @MainActor func rowAccessibilityIncludesUnreadAttachmentAndSubjectState() {
    let row = ThreadListRow(id: .init(accountId: "a", threadId: "t"), sender: "Ada", senderAddress: "ada@example.com", hasAttachments: true, isStarred: true, subject: "Meeting", snippet: "Tomorrow", date: .now, isUnread: true, messageCount: 2)
    let label = row.accessibilityDescription
    for value in ["Ada", "Meeting", "Unread", "Has attachments", "Starred", "2 messages", "Tomorrow"] { #expect(label.contains(value)) }
}

@Test func datesUseCalendarDaysAcrossDSTAndWeekBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let locale = Locale(identifier: "en_US_POSIX")
    func date(_ day: Int, hour: Int = 12) -> Date { calendar.date(from: .init(year: 2026, month: 3, day: day, hour: hour))! }
    #expect(ThreadDateFormat.string(for: date(7), now: date(8), calendar: calendar, locale: locale) == "Yesterday")
    #expect(ThreadDateFormat.string(for: date(6), now: date(8), calendar: calendar, locale: locale) == "Friday")
    #expect(ThreadDateFormat.string(for: date(2), now: date(8), calendar: calendar, locale: locale) == "Monday")
    #expect(ThreadDateFormat.string(for: date(1), now: date(8), calendar: calendar, locale: locale) == "3/1/2026")
    let time = date(8, hour: 10).formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    #expect(ThreadDateFormat.absoluteString(for: date(8, hour: 10), now: date(8), calendar: calendar, locale: locale) == "Today \(time)")
}

@Test @MainActor func HTMLUsesSemanticColorsWithoutOverridingDarkLinks() {
    let document = HTMLMessageView.document("<a href='https://example.com'>Link</a>", dark: true)
    #expect(document.contains("color: CanvasText !important"))
    #expect(document.contains("body a, body a * { color: LinkText !important; }"))
    #expect(document.contains("border-left: 2px solid GrayText"))
    #expect(!document.contains("#eeeeee"))
    #expect(document.contains("script-src 'none'"))
}
