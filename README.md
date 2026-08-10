# Textem

A lightweight, **native** macOS client for [Google Messages for web](https://messages.google.com/web) —
free and open-source. Textem hosts the Google Messages web client in a
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
- **Native notifications** on new messages (click to focus)
- **Menu-bar presence**, run-in-background, **launch at login**, start-hidden,
  menu-bar-only (hide Dock) modes
- **Zoom** (⌘+ / ⌘− / ⌘0), **find in page** (⌘F), **always-on-top**
- **New conversation** (⌘N / Dock), **copy latest 2FA code** (⇧⌘C)
- **Global show/hide hotkey** (⌥⌘M), single condensed app menu
- **Settings** window (⌘,)
- External links open in your default browser

**Planned** — inline reply, copy-2FA, Dock-compose, find-in-page, multiple
Google accounts, opt-in privacy tweaks, notarized `.dmg` + auto-update.

## Requirements

- macOS 13 (Ventura) or later
- Swift 6 toolchain (Xcode 16+) to build

## Build & run

```sh
make run      # build release, wrap into Textem.app, and launch it
make bundle   # just build + produce Textem.app
```

`swift build` alone only compiles the bare binary — a `WKWebView` app needs a
real bundle (Info.plist for the user-agent, icon, notifications), which
`make bundle` assembles.

### Releasing

```sh
make dmg                                                   # unsigned .dmg (~850 KB)
make release CODESIGN_IDENTITY="Developer ID Application: You (TEAMID)"
make notarize NOTARY_PROFILE=<notarytool-profile>          # submit + staple
```

`sign`/`release` apply a hardened runtime (required for notarization); the app
runs under it with no extra entitlements.

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
  `data-e2e-is-unread` conversation items) to native code for the badge and
  notifications

## License

[MIT](LICENSE) © 2026 Scarcrux
