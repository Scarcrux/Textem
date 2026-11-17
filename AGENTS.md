# Textem — notes for contributors and coding agents

Textem is a macOS wrapper (Swift 6, AppKit, `WKWebView`) around
[Google Messages for web](https://messages.google.com/web). It adds Mac
features around Google's own web client; it does not implement the Messages
protocol. User documentation is in [README.md](README.md); developer
documentation is in [DEVELOPING.md](DEVELOPING.md).

## Build and test

- `make run` — build, wrap into `Textem.app`, and launch. `WKWebView` needs a
  real app bundle (Info.plist, icon, notifications, signing), so
  `swift build` alone produces a binary you can't usefully launch.
- `make bundle` — build the universal app without launching it.
- `xcrun --toolchain XcodeDefault swift test` — the full test suite
  (XCTest and Swift Testing). The pre-commit hook runs it.
- `.build` is a symlink to `.build.nosync` (keeps build output out of iCloud
  sync); the Makefile recreates it if it goes missing.

## How the web client must be hosted

- `WKWebView.customUserAgent` must present as desktop Safari, or Google serves
  a degraded page or refuses.
- Sessions use a persistent `WKWebsiteDataStore` so pairing survives
  relaunches (one isolated store per account).
- Intelligent Tracking Prevention is turned off for Textem's own data store,
  otherwise Google's cookies are split between `accounts.google.com` and
  `messages.google.com` and sign-in loops.

## Sign-in and pairing constraints

- **Passkeys cannot work in `WKWebView`.** Apple only allows WebAuthn in an
  embedded web view for domains the app owns (Associated Domains) or with a
  browser-only entitlement. `ASWebAuthenticationSession` supports passkeys but
  its cookies never reach the app's data store. Steer users to **"Enter your
  password"** and a non-passkey second step; never rely on passkeys.
- Pairing is account-based: on the phone, Google Messages → account menu →
  **Device pairing**, then match the emoji. QR pairing is gone in the US.
- Google allows one active computer per account; opening Messages for web
  elsewhere disconnects Textem (⇧⌘R reconnects).
- Don't force-quit Textem in the middle of signing in: a half-written cookie
  state can loop.

## Code style

- Swift 6 with strict concurrency. Delegate method signatures must match the
  protocol exactly (including `@MainActor @Sendable`), or the method is
  silently never called.
- One type per file; `final class` by default.
- Never put real messages, contacts, phone numbers or screenshots of a real
  inbox in code, tests, fixtures or docs. Use clearly synthetic data.

## Commits

[Conventional Commits 1.0](https://www.conventionalcommits.org/en/v1.0.0/):
`<type>(<scope>): <subject>`, subject in the imperative mood. Explain why in
the body: what prompted the change and how it was verified.
