# Contributing

Thanks for your interest in Folio. Bug reports, fixes, and focused improvements are welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach before you write the code.
- Read [`AGENTS.md`](AGENTS.md) for the architecture rules and [`docs/conventions.md`](docs/conventions.md) for code conventions. They apply to human and AI-assisted contributions alike.

## Setup

Follow [Getting started](README.md#getting-started) in the README. You need macOS 27 and Xcode 27. A Gmail OAuth client is only needed to work on Gmail sync; the demo account covers most UI work.

## Making changes

- Keep changes focused. One topic per pull request; no unrelated refactors or formatting changes.
- Follow the layering: `Domain` has no UI, network, or database dependencies, SQLite is the source of truth, and views never call providers directly.
- UI state is `@MainActor`; stateful background components are actors. Prefer async/await.
- Follow the Apple macOS Human Interface Guidelines. Use AppKit where SwiftUI is too slow (see "UI performance" in the conventions).
- Tests cover critical business logic, not UI behaviour. A bug fix comes with a test that fails without the fix. Tests must not hit the network or need real credentials.
- Update the docs in `docs/` when you change behaviour or conventions.
- Never commit `Config/Local.xcconfig`, tokens, or personal data.

## Checks

Run these before opening a pull request; CI runs the same:

```sh
cd Packages && swift test
xcodebuild -scheme Folio -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

## Pull requests

- Describe what changed and why, and how you tested it. Include screenshots for UI changes.
- Keep commits readable; they may be squashed on merge.

## License

By contributing, you agree that your contributions are licensed under the [GNU Affero General Public License v3.0](LICENSE).
