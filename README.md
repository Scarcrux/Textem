# Textem

Textem is a free macOS wrapper for **Google Messages**, so you can text from
your Mac. It puts [Google Messages for web](https://messages.google.com/web) in
a real Mac window, with the things a browser tab can't do: notifications you can
reply to, an unread badge in the Dock and menu bar, keyboard shortcuts,
multiple Google accounts, and one-click verification codes.

**Who it's for:** people with an Android phone who use Google Messages and
want their texts on a Mac without keeping a browser tab open. It's a free,
open alternative to the paid **Texty for Google Messages** and the
no-longer-maintained **android-messages-desktop**, and a few MB instead of a
bundled Chromium.

> Unofficial. Not affiliated with, endorsed by, or sponsored by Google.
> "Google Messages" is a trademark of Google LLC.

**Status: alpha.** Textem is used daily but is not yet publicly released.
There is no public download yet; a signed, notarized download is planned for
1.0. Until then you can [build it from source](#building-from-source).

## Requirements

- A Mac with macOS 13 (Ventura) or later, Apple silicon or Intel
- An Android phone with Google Messages, signed in to a Google account
- macOS 14 or later for multiple accounts; macOS 15 or later for AutoFill codes

## Getting started

### 1. Install

Download Textem, open the disk image and drag **Textem** to Applications.
*(Public download coming with 1.0 — see [Building from source](#building-from-source)
in the meantime.)*

### 2. Sign in and pair with your phone

Google Messages for web now pairs through your **Google account**, confirmed
with an emoji on your phone. Textem shows these steps the first time it opens
(and any time under **Help → Sign-in Help…**):

1. On your phone, open Google Messages → **account menu (top right) →
   Device pairing**.
2. In Textem, sign in with the same Google account and choose
   **"Enter your password."**
3. For the second step, choose a **non-passkey** option: a Google prompt
   ("Tap Yes"), an SMS/email code, or an authenticator.
4. Your phone shows three emoji. Tap the one that matches Textem.

> **Don't use a passkey.** Passkeys can't work inside an app like Textem — an
> Apple restriction for sites the app doesn't own, not something Textem can fix.

You only do this once; Textem stays signed in across restarts. Google allows
**one active computer at a time**: if you open Messages for web in a browser,
that becomes the active one. Press **⇧⌘R** in Textem to switch back.
(Steps checked against Google's
[pairing instructions](https://support.google.com/messages/answer/7611075).)

## Using Textem

### Notifications and replies

New texts show a macOS notification with the sender and message. Click it to
open that exact conversation, or **Reply** right from the notification; the
reply goes to the conversation it came from, and Textem tells you if it can't
send. The Dock icon and menu-bar icon show your unread count.

### Verification codes

When a text with a verification code arrives, its notification gets a
**Copy Code** button — one click, then paste where you need it. The code stays
available for 3 minutes, is kept only in memory, and is copied marked as
private so clipboard managers that respect that don't save it. **⇧⌘C** copies
the latest code from the inbox.

**AutoFill (experimental, macOS 15+, signed builds):** turn on *Textem Codes*
in System Settings → General → AutoFill & Passwords and *AutoFill verification
codes* in Textem's Settings. In a code field, open AutoFill and choose
**Textem Codes** to pick a code from the last 3 minutes. If the text ends in
the form `@example.com #123456`, macOS can also suggest it directly on that
site. This has been tested in simulation; macOS presenting Textem Codes in a
real Safari field has not been confirmed yet.

Apple's own "From Messages" suggestions only read Apple's Messages and Mail
apps, so Textem uses Apple's AutoFill provider system instead. Detection is
deliberately cautious: it needs verification wording and exactly one 4–8
digit code (Google's `G-123456` style included), and ignores your own sent
messages, promo codes, phone numbers and amounts. Codes already in your inbox
when Textem opens are never offered.

### Menu bar, background and launch

Textem has a menu-bar icon with your unread count, account switcher and
quick toggles. In **Settings (⌘,)** you can launch at login, start hidden,
hide the Dock icon (menu bar only), and choose whether closing the window quits.

### Shortcuts

| Action | Shortcut |
|---|---|
| Show or hide Textem from anywhere | ⌥⌘M |
| New conversation | ⌘N |
| Copy latest verification code | ⇧⌘C |
| Find on page | ⌘F, then ⌘G / ⇧⌘G |
| Zoom in / out / actual size | ⌘+ / ⌘− / ⌘0 |
| Reload / reload and reconnect | ⌘R / ⇧⌘R |
| Settings | ⌘, |

**Window → Always on Top** keeps Textem above other windows.

### Multiple accounts (macOS 14+)

Use the **Accounts** menu or the menu-bar icon to add, rename, switch and
remove Google accounts. Each account has its own separate, persistent session.

### Privacy options

In **Settings → Privacy** you can blur message previews (hover to read) and
hide avatars; in **Settings → Notifications** you can hide the sender and text
from notifications. These change only what's shown on your Mac.

### Offline Mode (experimental)

**View → Offline Mode** pauses Google Messages and shows what Textem has saved
on this Mac. Today that means phone history and pictures saved through the
experimental Android companion (turn on **Settings → Advanced → Show phone
companion tools**; see [DEVELOPING.md](DEVELOPING.md)); without the companion
it is empty. Ordinary conversations are not stored offline.
Choose **Go Online** to return; the mode is remembered across restarts.

## Troubleshooting

- **"Can't reach Google Messages."** If the page fails to load (offline,
  after sleep, a network blip), Textem retries automatically at 1, 2, 4, 8 and
  16 seconds and shows the reason. Press **Try Again** or **⇧⌘R**.
- **"Trying to reach your phone."** Google Messages on your phone needs to be
  on and connected. Opening the Messages app on your phone usually fixes it.
- **A message says "View on your phone."** Google sends some messages —
  usually business messages with rich cards, images or buttons — only to
  your phone, so Google Messages for web (and therefore Textem) never
  receives their content. Open them on your phone. This is a Google
  limitation that Textem can't work around.
- **Disconnected after using Messages in a browser.** Only one computer can
  be active. Press **⇧⌘R** in Textem to make it active again.
- **Sign-in verification fails.** You probably chose a passkey. Choose
  "Enter your password" and a non-passkey second step.
- **No notifications.** Check System Settings → Notifications → Textem, and
  that **Mute notifications** is off in Textem's Settings. **Help →
  Diagnostics → Send Test Notification** tests delivery on its own.

## Privacy

Textem shows Google's own Messages for web client and talks only to Google;
it adds no analytics, telemetry, accounts or relay servers. Your session is
stored locally on your Mac. To keep Google's sign-in working inside an app,
Textem turns off WebKit's cross-site tracking prevention for its own Google
session (this doesn't affect Safari). Links open in your default browser.

## Building from source

Requires Xcode with a Swift 6 toolchain.

```sh
make run      # build, wrap into Textem.app, and launch it
```

Developer documentation — building, releasing, updates, how Textem works, and
the experimental Android companion, phone-recovery and AutoFill research — is
in [DEVELOPING.md](DEVELOPING.md). The roadmap lives in
[`commandem.toml`](commandem.toml).

## License

Textem is [MIT](LICENSE) © 2026 Scarcrux. It includes
[Sparkle](https://sparkle-project.org) for updates (MIT).
