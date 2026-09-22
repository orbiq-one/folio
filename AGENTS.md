# Folio
Folio is a native macOS email client written in Swift.

## Stack
- Swift 6
- AppKit for performance-critical UI, SwiftUI for the rest (see docs/conventions.md, "UI performance")
- Swift Concurrency
- GRDB / SQLite
- Gmail API
- JMAP (Fastmail)
- IMAP/SMTP
- Microsoft Graph (planned)

## Architecture
- Feature-first UI
- Domain layer has no UI/network/database dependencies
- SQLite is the local source of truth
- Providers sync into the database
- Views never call providers directly

## Rules
- Prefer async/await
- UI state is @MainActor
- Stateful background components should be actors
- No global singletons
- Keep provider-specific types out of Domain
- Good UI/UX is the highest priority
- Follow the Apple macOS Human Interface Guidelines (use the `macos-design-guidelines` skill if you have it installed)
- Unit tests should only test critical business logic, no UI/UX behaviour.

## Commands
- Tests: `swift test` in `Packages/`
- App build: `xcodebuild -scheme Folio -destination 'platform=macOS' build`

## Important docs
- Product: docs/product.md
- Architecture: docs/architecture.md
- Conventions: docs/conventions.md
- Decisions: docs/decisions.md
- UI behavior: docs/ui.md
