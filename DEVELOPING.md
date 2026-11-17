# Developing Textem

Developer and research material for Textem. For what Textem is and how to use
it, see the [README](README.md).

## Phone companion tools

The **Phone** menu and **Help → Diagnostics → Check Phone Connection…** serve
the experimental Android companion. They are hidden unless **Settings →
Advanced → Show phone companion tools** is on (it defaults on only where phone
data has already been saved on the Mac).

## Requirements

- macOS 13 (Ventura) or later; Xcode with a Swift 6 toolchain
- Tests: `xcrun --toolchain XcodeDefault swift test`

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

## App updates

Sparkle provides **Textem → Check for Updates…** and an optional automatic-check
toggle in **Settings → Updates**. Automatic checks default off; installation
requires approval. Signed feed/archive staging is documented in
[the update guide](Experiments/Updates/README.md). The first published update
channel and end-to-end install remain separate release gates.

## Offline Mode launch arguments

The `--offline` launch argument deliberately enables and saves Offline Mode
(the same persisted choice as **View → Offline Mode**). The read-only
`--check-offline-mode` argument reports the current mode without changing it.

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

### Explicitly shared phone graphics

The experimental Android companion can save one graphic from Google Messages'
media viewer: **Share → Textem Share Probe → Save image for Mac**. Use a fresh
share and choose Save directly; **Inspect** remains diagnostics-only. On the Mac,
choose **Phone → Shared Phone Images… → Import from phone**. Install companion
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

> **Current behaviour (since `e68b631`).** Codes also come from texts observed
> arriving in Textem's own Google Messages window (rows that change after the
> inbox loads; never a rescan of existing rows), not only from linked phone
> notification samples. Codes without an `@site #code` footer are offered only
> in Textem's AutoFill list and through **Copy Code** notifications. The
> notes below describe the original phone-notification prototype and its
> signing workflow, which still apply. Live macOS offer-and-fill is unverified.


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
controller.

#### Local notification preview sample

The optional developer companion v0.9 can separately save its latest Google
Messages notification preview after **Enable local content samples** is selected.
Android notification access alone does not enable content storage. On the Mac,
choose **Phone → Phone Notification Preview… → Read latest phone sample** using
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

## Notification diagnostics

Choose **Help → Diagnostics → Send Test Notification** to test macOS delivery independently
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

