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
- A local **Shared Phone Images** panel for graphics explicitly shared to the
  experimental Android companion (requires Android platform-tools and pairing)
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

### Explicitly shared phone graphics

The experimental Android companion can save one graphic from Google Messages'
media viewer: **Share → Textem Share Probe → Save image for Mac**. Use a fresh
share and choose Save directly; **Inspect** remains diagnostics-only. On the Mac,
choose **Textem → Shared Phone Images… → Import from phone**. Install companion
v0.7 or newer using the [probe build instructions](Experiments/AndroidProbe/README.md).

This developer prototype requires locally installed Android platform-tools and
an authorized USB or Android **Wireless debugging** connection. For wireless,
enter the current private IPv4 **IP address & port** from the main Wireless
debugging screen, not the temporary pairing-code screen. The port can change.
An empty address requires exactly one authorized USB/TLS-discovered phone.
Textem runs its own loopback-only adb server and does not stop other adb sessions
or change Google Messages pairing. Legacy plaintext `adb tcpip` is refused.
If a vendor hides the TLS port property, Textem checks an exact matching
authorized TLS-connect service. If discovery is unavailable, it checks the
explicit endpoint's bounded start-TLS protocol reply before transferring through
adb; a mere open port or legacy plaintext listener is not accepted.

The image is re-encoded as a metadata-free PNG, at most 2048 pixels per side and
6 MiB. The Mac checks its manifest, digest and decoder before saving it privately
under `~/Library/Application Support/Textem/PhoneImages` (25 images/100 MiB max).
Duplicates are not imported twice. **Remove Mac copy** affects only that library;
the phone's **Remove saved Mac image** clears its pending export, not the original
message. The latest phone export remains until replaced or removed and must be
imported within 24 hours (share/save again if expired).

This is explicit, individual-image recovery: no background/history sync, cloud
upload, guessed conversation association, full interactive cards, or guarantee
that every business preview exposes a shareable image. Synthetic controls are
refused by the shipping importer. A real Google Messages promotional graphic was
shared through companion v0.7, imported and visually verified in the Mac panel
on the owner's test phone. This validates that sample, not every business preview.

#### Show saved graphics with a conversation

Select a phone-only conversation in the inbox, open **Shared Phone Images…**,
choose the correct saved graphic and click **Link image to this conversation**.
Check that the displayed conversation and graphic belong together: Android's
share payload does not identify the source thread. Textem rechecks the live page
route before linking. Without a verified selected route, linking is unavailable.

After that explicit link, opening the same phone-only thread in the same account
shows its saved graphics automatically, without a phone connection or another
share. A same-name thread or another account does not match. **Manage shared
images** returns to the full library; **Unlink image** removes only the mapping.
An image must be unlinked before assigning it elsewhere. Deleting a Mac image
also clears its mapping, leaving the original phone content unchanged.

Bindings are stored privately in a separate bounded `bindings.json` sidecar
containing image UUIDs and account-scoped route hashes, not conversation names or
raw routes. Existing unlinked imports are preserved. This organizes explicitly
recovered graphics; it does not retrieve missing text/history or infer message
ordering. The original phone export format and permissions are unchanged.

## Missing notification banners

Choose **Textem → Send Test Notification** to test macOS delivery independently
of incoming messages. Textem keeps bounded, owner-only diagnostics at
`~/Library/Logs/Textem/notifications.jsonl`.
They contain counts, fixed event labels and settings, without message content,
names, conversation IDs or credentials.

A snapshot's `events` count records detected unread message changes;
`active=1` or `muted=1` explains app-side suppression. `domRows` counts
all conversation elements, while `rows` counts those with usable thread IDs.
`request_message` confirms submission, and `accepted_message` confirms
macOS accepted the request. Acceptance does not prove a visible banner:
notification style, Focus and other system presentation rules still apply.
Settings use Apple's enum values: authorization 2 means authorized; alerts 2
means enabled; style 0 means none, 1 banner, and 2 alert.

## License

[MIT](LICENSE) © 2026 Scarcrux
