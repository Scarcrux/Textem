# Textem

A lightweight, **native** macOS client for [Google Messages for web](https://messages.google.com/web) —
free and MIT-licensed. Textem hosts the Google Messages web client in a
`WKWebView` and wraps it in real macOS chrome: dock unread badge, native
notifications, menu-bar presence, launch-at-login, zoom, and more.

It's a free/open alternative to the paid **Texty for Google Messages** and the
no-longer-maintained Electron app **android-messages-desktop** — but native
(Swift 6 / AppKit / system WebKit), so it's a few MB instead of a bundled
Chromium.

> Unofficial. Not affiliated with, endorsed by, or sponsored by Google.
> "Google Messages" is a trademark of Google LLC.

## Status

Early but usable. See [`commandem.toml`](commandem.toml) for the live roadmap
(milestones M1–M3, phases 0–7).

**Working today**
- Loads Google Messages for web with a persistent session (pair once, stay
  paired across relaunches)
- Dock **unread badge** and **menu-bar item** with unread count
- **Native notifications** on new messages (click to restore the exact account/thread)
- Fail-closed **inline reply** routed to the notification's exact account and conversation
- **Menu-bar presence**, run-in-background, **launch at login**, start-hidden,
  menu-bar-only (hide Dock) modes
- **Zoom** (⌘+ / ⌘− / ⌘0), **find in page** (⌘F), **always-on-top**
- **New conversation** (⌘N / Dock), **copy latest 2FA code** (⇧⌘C)
- **Global show/hide hotkey** (⌥⌘M), single condensed app menu
- **Settings** window (⌘,)
- Multiple Google accounts with isolated persistent sessions (macOS 14+)
- Opt-in message-preview blur, avatar hiding, and notification-preview privacy
- An owner-local **phone-only fallback** that surfaces recovered link previews
  inside the matching conversation when Google withholds it from the web client
- External links open in your default browser; untrusted redirects are blocked

**Distribution status** — the repository and alpha release are currently
private/draft. A public, Developer ID-signed and notarized universal `.dmg` is
planned for 1.0; there is no public download yet.

## Requirements

- macOS 13 (Ventura) or later
- Xcode with a Swift 6 toolchain to build

## Build & run

```sh
make run      # build release, wrap into Textem.app, and launch it
make bundle   # just build + produce Textem.app
```

The Makefile selects Xcode's compiler explicitly and builds a universal
Apple-silicon + Intel executable. `swift build` alone only compiles the bare binary — a `WKWebView` app needs a
real bundle (Info.plist for the user-agent, icon, notifications), which
`make bundle` assembles.

### Releasing

```sh
make dmg VERSION=0.1.0 BUILD_NUMBER=1                      # unsigned test .dmg
make release CODESIGN_IDENTITY="Developer ID Application: …" VERSION=0.1.0
make notarize NOTARY_PROFILE=<notarytool-profile>          # notarize app + final DMG
```

`release` refuses the ad-hoc default and requires a Developer ID identity.
`notarize` submits and staples the signed app, packages that exact app, then
submits and staples the final DMG. The app runs under the hardened runtime with
no extra entitlements.

## Signing in (important)

Google is removing QR-code pairing in the US in favor of **Google-account
sign-in inside the page**. In an embedded web view this has one hard
constraint:

- ❌ **Passkeys do not work** inside `WKWebView` (an Apple platform limitation
  for sites you don't own — not a bug we can fix). If you pick "Use your
  passkey," the verification will fail.
- ✅ Instead choose **"Enter your password"**, then a **non-passkey** second
  step — a **Google prompt ("Tap Yes")**, **SMS/email code**, or authenticator.
- ✅ Finish pairing with the **emoji match**. Your phone's Messages app needs
  **Settings → Device pairing → "Switch to Google Account pairing"** available.

You only do this once; the session persists.

## How it works

Google Messages has no public API, so Textem embeds the official web client and
adds native integration around it:

- Desktop-Safari user-agent so Google serves the full client
- Persistent `WKWebsiteDataStore` for the session
- A small injected JS bridge reports the unread count (read from
  `data-e2e-is-unread` conversation items) and per-thread content fingerprints
  to native code for the badge and notifications

Textem adds no analytics, telemetry endpoint, account service, or relay.
Google's web client still communicates with Google under Google's own policies.

The phone-only fallback reads an owner-only local export produced by the
separate AGPL Experiments/LibGMProbe helper. The helper is not linked or bundled
into the MIT app. Textem matches the export to the selected conversation before
displaying it, and keeps the Google view when no exact local match exists.

## License

[MIT](LICENSE) © 2026 Scarcrux
