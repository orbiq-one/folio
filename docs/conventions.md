# Conventions

## Naming

Name files after their main type. Feature views and their models share a prefix:

- Features: `ThreadListView.swift`, `ThreadListModel.swift`
- Domain: `Message.swift`, `MailThread.swift`
- Data and Platform: `SQLiteMailRepository.swift`, `GmailClient.swift`, `GmailAccountSync.swift`

Avoid `Manager` unless the type really coordinates several components.

## Swift

- Use structs for domain models.
- Mark values that cross actors `Sendable`.
- UI state is `@MainActor`; stateful background components are actors. Prefer async/await.
- No global singletons.
- Avoid protocols with a single conformance, and prefer composition over inheritance.
- Keep provider-specific types out of `Domain`.

## Compatibility

The deployment target is macOS 27. Use macOS 27 APIs directly, with no `#available` checks for older systems.

## UI performance

Folio must stay fast with 1,500 or more messages in a mailbox, so AppKit is the default for performance-critical UI. SwiftUI hosts it and owns settings, forms, sheets, and small or static views.

Use AppKit when a view does one of the following:

- Shows a large or unbounded collection, such as the message list or search results. Use `NSTableView` with reusable cells built in code, and no SwiftUI views inside cells.
- Animates continuously, such as glows, spinners, and progress rings. Use Core Animation layers with `CABasicAnimation` so frames run in the render server, not on the main thread. Don't use `TimelineView(.animation)` for decoration.
- Would be torn down and rebuilt on a toggle. Keep it mounted and hide it instead.

The existing AppKit hot path is `ThreadTableView` (the message list with pull-to-refresh). Extend it for new list features instead of adding SwiftUI equivalents. When a SwiftUI view feels slow, measure it with Instruments first, then port it to AppKit.

## Tests

- Test business logic, not UI behavior.
- A bug fix comes with a test that fails without the fix.
- Fake only true external boundaries. Tests make no network calls and use no real credentials.

## Documentation

Update the files in `docs/` in the same change when behavior, commands, or conventions change.
