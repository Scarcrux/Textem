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
- An owner-local **phone-only preview library** for previously recovered text and
  links; automatic native refresh is disabled while its separate Google relay
  cannot coexist safely with the main web inbox
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
make install-helper # locally build/install the separate AGPL read helper
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

QR-code pairing is no longer available in the US; Google Messages for web now
pairs through your **Google account**, confirmed with an emoji on your phone.
In an embedded web view this has one hard constraint:

- ❌ **Passkeys do not work** inside `WKWebView` (an Apple platform limitation
  for sites you don't own — not a bug we can fix). If you pick "Use your
  passkey," the verification will fail.
- ✅ Instead choose **"Enter your password"**, then a **non-passkey** second
  step — a **Google prompt ("Tap Yes")**, **SMS/email code**, or authenticator.
- ✅ On your phone, open Google Messages → **account menu (top right) →
  Device pairing**. When it shows three emoji, tap the one that matches Textem.
- ⚠️ Google allows **one active computer** at a time. Opening Messages for web
  in a browser makes that the active one and disconnects Textem; reload Textem
  (⇧⌘R) to switch back.

You only do this once; the session persists. (Steps checked against Google's
[pairing instructions](https://support.google.com/messages/answer/7611075) on
2026-10-13 — the older "Switch to Google Account pairing" toggle no longer
exists.)

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

The phone-only research helper is the separate AGPL
`Experiments/LibGMProbe` executable; it is not linked or bundled into the MIT app.
Live testing established that Google permits the helper and the embedded web inbox
to pair, but rejects the inactive relay with HTTP 401 when the active computer
changes. Normal Textem launches therefore never start the helper or request phone
pairing merely because a phone-only conversation was selected. The automatic path
is developer-only behind `TEXTEM_EXPERIMENTAL_AUTOMATIC_RECOVERY=1` until a design
can preserve the primary inbox.

Readable fallback messages and link previews remain in an owner-only local
store. Textem matches the stable web route first and otherwise accepts only an
exact or unique label match. Ambiguous matches and cross-account cookie/session
mismatches fail closed. Direct helper use is read-only and does not run as a
permanent background service.

## License

[MIT](LICENSE) © 2026 Scarcrux
