# Decisions

Settled decisions. Change the line here before you change the behavior.

## Product

- Direct distribution, notarized, with App Sandbox on.
- Deployment target macOS 27, with no support for older systems.
- AI runs on-device with Apple Foundation Models and is never required for any view.
- No backend run by the project. If sync between Macs is added, it uses the user's own iCloud private database, is opt-in, and covers only workflow state and sender rules, never mail content.
- English only for now. All strings go through the String Catalog.

## Architecture

- Local SwiftPM modules `Domain`, `Data`, `Platform`, and `Features`; the app target is the composition root.
- SQLite through GRDB is the source of truth, and views observe the database.
- Every user action goes through the outbox.
- One sync actor per account. Polling every 60 seconds, no push.
- A 90-day sync window per account.
- The server wins on flags and membership; the local copy wins on unsent drafts.
- Derived data (traffic kind, activity category, cleaned text) is local only and can be rebuilt from the raw store.
- Conversation state is inferred from server facts. Only Later, Needs Reply, and Move to Attention are stored as overrides.

## Dependencies

- Allowed: GRDB, SwiftNIO, swift-nio-imap, and swift-nio-ssl.
- Hand-written: MIME, OAuth, and PKCE.
- A new dependency needs a concrete reason and an entry here.

## UX

- Sidebar: Attention, Waiting, Later, and Activity, then Sent and Drafts, then per-account mailboxes under Accounts.
- AppKit for large or continuously animating views, SwiftUI for the rest.
- Gmail gets label toggles, IMAP gets move; capability flags decide.
- `⌫` moves to Trash, and `e` marks Done (archives on the server). The single-key shortcuts are on by default.
- Conversations are marked read 2 seconds after you open them.
- The Dock badge shows the Attention count and can be turned off.
- Remote images are blocked until you load them for a message.

## Testing

- Unit tests cover business logic, not UI behavior.
- Providers are faked in tests. Default test runs make no network calls and need no credentials.
