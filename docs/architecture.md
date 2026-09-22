# Architecture

Folio is a modular monolith: one app target and a local Swift package, `Packages/`, whose modules have a compiler-enforced dependency direction.

```
App ─▶ Features ─▶ Domain
 │        │          ▲
 │        └─▶ Data ──┤
 └─▶ Platform ───────┘
```

| Module     | Responsibility                                                         | Depends on             |
|------------|------------------------------------------------------------------------|------------------------|
| `Domain`   | Models and rules. No UI, network, or database imports.                 | Nothing                |
| `Data`     | GRDB/SQLite schema, migrations, repository, and outbox.                | `Domain`               |
| `Platform` | Provider clients and sync, OAuth, Keychain, and MIME.                  | `Domain`, `Data`       |
| `Features` | SwiftUI and AppKit views with their models.                            | `Domain`, `Data`       |
| App        | Composition root: wires `Platform` into `Features`, owns scenes and menus. | All modules        |

## Data flow

1. A sync actor fetches changes from the provider and writes them to SQLite.
2. Views observe the database through GRDB `ValueObservation` and update when rows change.
3. A user action writes to SQLite first, so the UI updates immediately, and adds a row to the outbox.
4. The outbox replays each row to the provider, with retry and backoff.

Views never call a provider, and `Features` never imports `Platform`.

## Domain

- `Account`, `Mailbox`, `Message`, and `MailThread` are `Sendable` structs. Provider IDs are opaque strings.
- `Mailbox` covers Gmail labels, IMAP folders, and JMAP mailboxes. `ProviderCapabilities` (`labels`, `serverSearch`, `push`, `drafts`, `sendAs`, `spamActions`) tells the UI what a provider supports, so the UI never fakes a feature.
- Threads come from the provider (Gmail thread ID, JMAP thread ID, IMAP `References` and `In-Reply-To`). Threads never merge across accounts.
- `TrafficClassifier` sorts each message into `human` or `activity` from its headers and sender. A user `SenderRule` always wins.
- `StateInference` computes `ConversationState` (`attention`, `needsReply`, `waiting`, `later`, `done`) from Inbox membership and authorship. A `ConversationOverride` stores only what can't be inferred: Later with a date, Needs Reply, and Move to Attention.
- `BodyCleaner` and `HTMLText` turn a raw body into `displayText` without quotes, signatures, footers, or hidden HTML.

## Data

- One GRDB database for all accounts. Tables are keyed by account.
- Headers and bodies live in separate tables, so the message list never loads bodies.
- An FTS5 index covers subject, sender, and cleaned body text.
- Derived columns (`message.trafficKind`, `message.activityCategory`, `message_body.displayText`) are written in the same transaction as the raw row. `rebuildDerivedData()` recomputes them, so rules can change without a migration.
- Conversation state is never stored. The repository infers it on every read, both for list views and for a single thread.
- `conversation_override` and `sender_rule` are the only user state that isn't on the server.
- Attachments are stored in the app container, keyed by content hash.
- The `outbox` table holds every user change (flags, moves, labels, sends, and draft saves). Undo send is an outbox row with a 5-second delay. Later is an outbox row that re-adds the newest message to Inbox on the due date.

## Platform

- One `AccountSync` actor per account owns the provider client, the sync cursor, and the polling loop.
- Gmail and JMAP poll every 60 seconds and refresh when the app becomes active. There is no push, because it would need a hosted endpoint.
- Sync covers the last 90 days.
- Conflicts: the server wins on flags and mailbox membership; the local copy wins on unsent drafts.
- Gmail uses `ASWebAuthenticationSession` with PKCE and a hand-written token exchange. Fastmail uses an API token. IMAP uses a password. Secrets are stored in the Keychain.
- IMAP and SMTP use SwiftNIO, swift-nio-imap, and swift-nio-ssl. MIME parsing and generation are hand-written.

## Platform constraints

- The deployment target is macOS 27. Use macOS 27 APIs directly, with no `#available` checks.
- Swift 6 language mode with strict concurrency.
- App Sandbox with network client access and user-selected file access for attachments.
- No database encryption; the sandbox container and FileVault protect data at rest.
- Log with `os.Logger` only.
