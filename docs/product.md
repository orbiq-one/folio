# Product

Folio is a native macOS email client. It keeps each provider's own model (Gmail labels, IMAP folders, JMAP mailboxes) instead of reducing everything to generic IMAP, and it sorts mail by what it needs from you rather than by folder.

## Principles

- **Local first.** Mail syncs into a local SQLite database. The app reads from that database, so browsing and search work offline.
- **People before machines.** Mail from people goes to conversation views. Receipts, alerts, notifications, and newsletters go to Activity.
- **State from facts.** Whether a conversation needs you is inferred from Inbox membership and who wrote last. You only set state by hand when it can't be inferred.
- **No hosted backend.** Folio talks only to your mail providers. AI features run on-device and are never required.
- **Native Mac app.** It follows the Apple macOS Human Interface Guidelines, and every action has a menu item and a keyboard shortcut.

## Supported

- Gmail (OAuth), Fastmail (JMAP with an API token), and generic IMAP with SMTP
- A local demo account with sample mail that needs no sign-in
- Multiple accounts, unified Inbox, Drafts, Sent, and Flagged
- Conversation views: Attention, Waiting, and Later
- Activity feed with Orders, Money, Security, Notifications, and Newsletters
- Threads, full-text search, compose, reply, reply all, forward, and undo send
- Ask Mail: questions about your mail answered with on-device Apple Foundation Models, with a keyword search fallback

## Planned

- Microsoft 365 and Outlook through Microsoft Graph
- Inbox notifications
- Send later, Gmail send-as aliases, and spam actions

## Out of scope

- Calendar
- Mobile apps
- Team collaboration
- PGP and S/MIME
- Merging threads across accounts
- Any server run by the project
