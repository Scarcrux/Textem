# Textem

A lightweight macOS wrapper for [Google Messages for web](https://messages.google.com/web) —
free and MIT-licensed. Textem hosts the Google Messages web client in a
`WKWebView` and wraps it in real macOS chrome: dock unread badge, native
notifications, menu-bar presence, launch-at-login, zoom, and more.

It's a free/open alternative to the paid **Texty for Google Messages** and the
no-longer-maintained Electron app **android-messages-desktop** — built on
Swift 6 / AppKit and the system WebKit, so it's a few MB instead of a bundled
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
- **Verification codes**: a **Copy Code** button on the notification when a text
  with a code arrives, and (signed builds, macOS 15+) **Textem Codes** in AutoFill
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

## App updates

Sparkle provides **Textem → Check for Updates…** and an optional automatic-check
toggle in **Settings → Updates**. Automatic checks default off; installation
requires approval. Signed feed/archive staging is documented in
[the update guide](Experiments/Updates/README.md). The first published update
channel and end-to-end install remain separate release gates.

## Offline Mode

Choose **View → Offline Mode** to browse saved phone history, notification
previews and imported pictures without loading Google Messages or connecting
to your phone. The choice persists across launches; **Go Online** returns to
the existing account session. History and previews remain scoped to the selected
account. Imported pictures use the existing local picture library.

The `--offline` launch argument deliberately enables and saves this same choice.
The read-only `--check-offline-mode` argument reports the current mode without
changing it.

This mode uses content already saved on this Mac. Ordinary web conversations
are not archived offline, and saved phone history may omit RCS-only content.
Live Messages/phone loading and inline replies are paused; this does not disable
the Mac's network or other apps. Explicit external links and software updates
remain separate actions.

## Verification codes

When a text containing a verification code arrives in Textem's Google Messages
window, Textem can offer it the way Messages does for iMessage codes — for 3
minutes, then it is gone:

- **Copy Code** on the notification copies it (marked concealed, so clipboard
  managers that honour that convention don't record it). Turn it off in
  Settings → Verification Codes. Codes are kept in memory only.
- **Textem Codes in AutoFill** (Developer ID builds with the embedded extension,
  macOS 15+; enable *Textem Codes* in System Settings → General → AutoFill &
  Passwords, and *AutoFill verification codes* in Textem's Settings). In a code
  field, open AutoFill and choose Textem Codes to pick from fresh codes.
  A text ending in Apple's domain-bound form (`@example.com #123456`) is also
  registered for that site so macOS can suggest it directly; any other code is
  only offered when you open the list, because macOS needs a domain to suggest
  a third-party code inline.

Apple's own "From Messages" suggestions read only the Messages and Mail apps;
there is no public way for another app to join that pipeline, so this uses
Apple's credential-provider API instead.

Detection is deliberately conservative: it needs verification wording and
exactly one 4–8 digit code (Google-style `G-123456` included), and it ignores
your own sent messages, promo/coupon texts, phone numbers and amounts. Only rows
that change after Textem has loaded the inbox count, so opening the app never
offers old codes. Not yet verified live: macOS actually presenting Textem
Codes in a Safari code field.

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

Companion v0.8 also includes an optional **Automatic recovery setup** readiness
check. It needs separate owner-approved Android notification access and currently
exports only counts/types—not message text or graphics. It does not enable
automatic content sync. See the [probe documentation](Experiments/AndroidProbe/README.md#automatic-recovery-readiness-check-v08)
for its access boundary and remaining live-delivery/identity gates.

#### Native verification-code AutoFill prototype

`Experiments/NativeAutoFill` contains a real macOS 15+ AuthenticationServices
credential-provider extension, separate from the shipping application. This
uses Apple's [public OTP provider API](https://developer.apple.com/documentation/authenticationservices/providing-one-time-passcodes-to-autofill),
not clipboard/key injection or writes into Apple Messages. It does not enroll
Textem in Apple's Messages/Mail delivered-code detection pipeline and does not
guarantee the identical automatic “from Messages” popup.

Run `bash Experiments/NativeAutoFill/build.sh` to compile the universal `.appex`
into `.build.nosync/native-autofill`, and
`bash Experiments/NativeAutoFill/preflight.sh` for a read-only signing-capability
check (counts and booleans only, never decoded profile contents). This standalone
build is ad-hoc signed for local verification, not installation or activation.
Apple requires the AutoFill capability on both the app and extension. The preflight is an early
capability check, not a complete signing/profile validation or installer.
Run `swift test --filter NativeAutoFillTests` for synthetic policy/request/UI
controls; optionally set `TEXTEM_AUTOFILL_FIXTURE` to a local PNG output path.
`swift test --filter NativeCodeVaultTests` exercises the storage/feed/index
controls with injected in-memory storage, not the owner's Keychain. Set
`TEXTEM_AUTOFILL_SETTINGS_FIXTURE` for an offscreen settings screenshot.

The first prototype only accepts fresh, unambiguous numeric codes with a single
explicit domain-binding footer such as `@example.com #004321`. Offers expire
after three minutes, match the exact requested domain and record, and are
rechecked when selected. Password/passkey requests are refused; a fill requires
user interaction. Synthetic tests inject samples in memory into the real native
controller, with completion redirected to a test sink rather than macOS AutoFill.
The provider now reads an explicitly scoped data-protection Keychain item, with
when-unlocked/device-only protection and noninteractive authentication. There is
no file, UserDefaults or unscoped login-Keychain fallback. Missing entitlements,
locked storage, disabled consent and invalid data fail closed. The bounded vault
stores code/domain records and opaque source/account bindings, not message bodies
or sender labels. Disabling/clearing deletes those records and bindings. Account
removal and clearing a linked notification sample revoke its codes as well.

The experimental host has a default-off **Native code AutoFill** setting. In a
properly provisioned build, enable it, then use **Phone Notification Preview… →
Link this code source to an account…** for an explicit binding. Only validated real
`POSTED` notification samples with original message timestamps younger than three
minutes can feed codes on a manual phone import. Unknown timestamps, active scans,
truncated messages, synthetic kinds and unlinked sources are refused. Import time
never resets a code's lifetime. No code is extracted by guessing from a business
name or by rescanning old web snippets. Message direction is still not established
by these notification samples; this is notification-code capture, not proven SMS
inbox ingestion. Continuous/background phone sync is not implemented.

The native suggestion index contains only domain/record metadata, never the code.
Ambiguous domains are suppressed, expiry prunes stale records while the host runs, and publication
is serialized so a late update cannot undo a clear. The provider rechecks ambiguity
and storage on selection, including requests for an old explicit record ID.
If the host exits, expired data can remain in the encrypted Keychain until the
next host startup or explicit clear; it is never eligible for filling after its
deadline. This is not a claim of OS-scheduled physical deletion.

For signing, `bash Experiments/NativeAutoFill/project.sh` generates an experimental
Xcode host+embedded extension project under `.build.nosync/native-autofill-project`.
Both targets declare AutoFill and the shared Keychain group; the extension is
sandboxed. The complete project builds unsigned. An automatic provisioning build
initially failed with **No Accounts**. After the owner added the account and
explicitly approved registering this Mac, the provisioned build/archive succeeded;
both exact target profiles include this Mac and the shared-group capability.
Device identifiers and certificate/account names are never printed by the checker.
Generating the project does not itself install, enable or run the extension.

`BUILD_NUMBER=2026111102 bash Experiments/NativeAutoFill/signed-build.sh` is the
tested local archive/export workflow (choose a number newer than the installed
build). It exports with the pinned stable Developer ID certificate and restores
the installed host's exact designated requirement. This matters: Xcode's default
export synthesized a broader requirement with a Mac App Store alternative, which
the first candidate check correctly refused. Exported entitlements and the nested
extension signature are preserved. Never run the development-signed build over
the stable installation.

The app icon is an explicit `sources` entry with `buildPhase: resources` in the
XcodeGen specification. A former unsupported top-level `resources` key silently
omitted it, producing a valid signed app but a broken Dock icon. The distribution
checker now rejects a missing, corrupt or source-mismatched icon and requires
the declared icon to decode successfully. No icon artwork was changed.

The artifact is under `.build.nosync/native-autofill-release-BUILD/export/Textem.app`.
`verify.sh candidate.app /Applications/Textem.app BUILD` checks strict nested
signatures, pinned leaf certificate, CMS profile signature/trust, profile expiry,
distribution eligibility, exact IDs/group, disabled debug entitlement, extension
sandbox, both architectures, advancing build versions and the installed OS
requirement. It is read-only and prints no profile contents. Negative policy
controls cover wrong certificates, development/expired profiles, extra groups and
debug entitlements. `signed-build.sh` does not notarize, publish, install, register
a new device or enable an OS credential provider. Keep Xcode build logs private.

Notarize and staple this exported candidate separately; normal `make bundle`
still produces the app without an embedded provider. The provisioned universal
build2026111102 passes these checks and Apple notarization. The canonical
requirement text matches the installed host and macOS accepts the candidate
against the actual old requirement; raw requirement-blob bytes are not a reliable
equality check. Owner provider enablement in System Settings remains a separate
consent step, not a preference to bypass.

The genuine containing app writes bounded, private readiness evidence to
`~/Library/Logs/Textem/native-autofill.jsonl`. It records only fixed event names,
integer capture/provider flags, source/eligible counts, numeric failure status,
timestamp and process ID. A `ready` event requires successful protected-vault
reads, an enabled OS credential store and a completed native index update. It is
not evidence that a code was filled. Provider-disabled, locked/refused storage,
publication refusal and unavailable runtime produce distinct events. No code,
domain, sender/body, account/shortcut ID, raw error or UI snapshot is logged.
Injected test dependencies disable the live sink by default; synthetic controls
use private sinks and never populate the owner's readiness history or code vault.

Remaining live gates: actual shared-Keychain access, owner enablement as an AutoFill provider, a fresh
real phone code transfer, and an OS-launched extension plus actual target-field
fill. These are not proven by injected storage, compiling, or rendering a local
controller. Initial controls and their
verdicts are recorded in the experiment's `PREREGISTRATION.txt`.

#### Local notification preview sample

Previously recovered legacy exports remain available in **Phone-only Message
Preview…**, explicitly labeled as a library rather than the selected web thread.
They are not automatically attached by a matching business name. Automatic
preview display requires an explicit local Textem account binding and the exact
confirmed route; old exports have no such binding and are not silently migrated.
An explicit route mismatch never falls back to a title. Existing account-scoped
shared-image links are unaffected.

The optional developer companion v0.9 can separately save its latest Google
Messages notification preview after **Enable local content samples** is selected.
Android notification access alone does not enable content storage. On the Mac,
choose **Textem → Phone Notification Preview… → Read latest phone sample** using
the same authorized TLS/USB developer connection. Source titles/text and available
bitmap pictures stay in private local storage; no URLs are automatically fetched.

This is a bounded sample, **not automatic inbox/history recovery**. Android can
shorten or omit notification content; the sampled graphic is not guaranteed to
match a full phone card. URI attachments and unknown picture types remain
unsupported. A title never determines identity, web account or conversation;
this viewer is explicitly unlinked and cannot send messages. Existing shared
images/bindings and Google pairing are unchanged.

The Mac keeps one latest snapshot in owner-only `Textem/NotificationPreviews`
under Application Support until **Delete Mac sample**; the phone's delete action
is separate. A cached snapshot is timestamped, not presented as a live inbox.
See the [probe documentation](Experiments/AndroidProbe/README.md#separate-local-notification-content-sample-v09)
for limits, retention, content opt-in and safe summary readback.

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
