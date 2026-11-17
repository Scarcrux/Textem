# Textem read-only Android probe

## Explicit selected history transfer (v0.15)

In **Choose a history thread**, inspect the actual selected text, then tap
**Make this history available to paired Mac**. This explicit action captures
only that public SMS/MMS provider thread. The Mac's conversation options menu
has **Read selected phone history…**; compare the returned text and confirm
before linking it to the current account and conversation. This is a source
association, not another Google pairing. Existing phone connection credentials
are reused. **Saved Conversation Previews…** also opens linked history offline.

History uses a separate format/cache and `/v1/selected-history` HTTPS route.
Requests read only already-published snapshots; they cannot choose a thread ID
or trigger a provider query. Phone identifiers are HMAC-derived, participant
addresses are not transferred, and tokens/content never enter diagnostics.
SMS permission, capture opt-ins and channel authorization are checked; disabling
local content or deleting captures clears published history. A seven-day transfer
window applies. Mac caches persist until unlink or account removal.

Coverage is explicit: up to 500 SMS and 500 MMS rows, 32 parts per MMS,
20,000 characters per row, two MiB per snapshot and eight threads/eight MiB on
the phone. Attachments are counted as omitted, never guessed from links. The
Mac retains existing notification graphics independently. RCS-only content may
be absent; this is **not complete RCS history**. Publish again on the phone to
update a snapshot.

## Granted notification media and durable connection (v0.14)

Captured MessagingStyle image URIs and explicit picture-icon URIs can now supply
one picture when no embedded bitmap exists. The reader reuses the share reader's
exact Google private-provider allowlist and actual OS URI-read-grant check. It
does not fetch web links, open unknown/exported providers, read avatars, retain
URI strings or request broad storage/media permissions. Reads are capped at six
MiB/five seconds, decoded dimensions are bounded and downsampled to 2048, and
the existing one-MiB PNG publication limit remains. Unavailable pictures retain
text; `uri_attachments` counts unresolved references after successful recovery.
The capture opt-ins/access are rechecked during reads and before publication.

An explicit **Start local connection** in v0.14 enables durable resume until
Stop, revoke or permission/opt-in removal. A v0.13 token or Bluetooth association
alone does not opt into resume. The service uses Android sticky restart and a
non-exported boot/package-update receiver under Android's
[foreground-service lifecycle rules](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start).
It waits for active private IPv4 Wi-Fi rather than using cellular/VPN-only
networks. Android Force Stop still requires an explicit restart.

Local DNS-SD advertises only `Textem-` plus a public certificate-pin prefix.
The Mac tries its saved endpoint, then bounded local discovery after a connection
failure. Discovery never supplies trust: the imported full certificate pin must
validate before the token is transmitted. Tokens and source identities are never
advertised. Successful endpoints are cached in process memory; changing address
does not require replacing the phone credentials or thread links.

The signed Mac app's **Help → Diagnostics → Check Phone Connection…** uses its
own Keychain and HTTPS client and writes a private content-free report. The
explicit `--check-phone-connection` launch argument runs the same check without
an alert. It neither selects conversations nor mutates links/cache. Reported
network success and visible route-validated pane evidence are separate fields.
This is an instrument for live testing, not proof of UI rendering or history by
its existence. New incoming Google picture capture still needs real evidence.

## Explicit local phone connection (v0.13)

The optional **Automatic recovery setup → Start local connection** service
replaces ADB for conversation-preview reads after explicit setup. It is off by
default. Enable notification checks, Android notification access and local
content samples first. Starting also requires the running/stop notification.
The foreground service follows Android's
[connected-device service contract](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device).
It does not start on boot or from the existing Bluetooth companion association.

Both devices must share a private IPv4 network. Export a private `.textempair`
file using Android's document picker, transfer it privately to the Mac, and
import it with **Phone connection…** in the conversation preview pane. The file
contains a random authorization secret: keep it private and delete transferred
copies after import. No message content is included in the file. Mac credentials
are stored in device-local Keychain; the phone encrypts its token with an
AndroidKeyStore AES key and keeps a non-exportable TLS private key.

The client pins the explicitly imported certificate before sending its token,
refuses redirects/cookies, binds replies to a random request ID and checks the
journal's phone identity. The phone checks current capture opt-ins and Android
access on each read. The one HTTPS route reads only the bounded notification
journal; it does not read SMS/MMS providers or send messages. Header, transfer
size and time limits apply. No credentials, source text or pictures are logged.

In v0.13, **Stop** ends the listener but retains credentials. Restarting reuses the port,
certificate and encrypted token. **Revoke** stops it and invalidates old exported
files. **Disconnect** on the Mac retains cached previews and prevents debugging
fallback, but cannot remotely revoke copies of an exported file. Phone restart
requires an explicit Start; network-address changes require a new export/import.
The v0.14 section above supersedes manual restart/address-update requirements.
Long-running capture reliability and complete history still require separate
evidence; implementing resume/discovery alone does not prove them.

Before first pairing, an existing developer ADB setup remains available. A
configured, inaccessible, revoked or malformed paired connection never silently
falls back to ADB. Shared graphics and code AutoFill retain their existing paths.

`CompanionInstrumentation` runs only synthetic loopback TLS with isolated cache,
preferences and keystore aliases. It cannot open the production listener or read
owner journals. Run it without opening activities or granting permissions:

```sh
adb -s EXPLICIT_TEST_DEVICE shell am instrument -w -r dev.textem.probe/.CompanionInstrumentation
```

## Conversation preview journal (v0.12)

Approved local content capture now also writes a private bounded notification
journal: four snapshots per source, 32 total, eight MiB total, seven days at the
next write. Unchanged content is not duplicated or re-aged. Disabling capture or
content capture clears the journal; deleting content also clears the latest
sample. Distinct conversation events no longer cancel one another in the capture
worker. This journal is partial notification content, not a complete RCS archive.

The Mac can explicitly bind a chosen phone source to a verified account/route,
cache previews, and refresh while that conversation pane is open. Existing code
AutoFill still reads the separate latest sample and has independent authorization.
See [the recovery design](../PhoneRecovery/README.md) for setup and release gates.

`JournalInstrumentation` tests the real extractor/journal with synthetic content
in an isolated cache. It launches no activity, sends no UI input and performs no
SMS/MMS-provider queries. It never changes the owner's capture opt-in.

## Conversation sampling (v0.11)

Some Google Messages notifications have no conversation shortcut. They are not
eligible sources for code linking. These events no longer cancel a queued valid
preview or invalidate a recent saved preview; the saved timestamps are unchanged.
If no recent saved preview exists, the companion still reports `SOURCE_REQUIRED`.
Refreshing scans at most20 Google notifications and chooses the latest usable
source-bearing conversation instead of stopping at the first non-summary event.
A capped scan refuses to claim a complete selection. Source identity, explicit
account linking, original message time, POSTED origin and code expiry rules remain
unchanged. The preview is the latest supported conversation sample, not an archive
or proof that every Google notification can be recovered.

## Verification-code redaction (v0.10)

A real posted dummy-code notification on the test phone was delivered to the companion
as Android's "Sensitive notification content hidden" placeholder. Notification
access alone did not expose the OTP. The new `REDACTED` state reports this cause
and refuses to publish the placeholder as a recovered preview.

In **Automatic recovery setup**, **Link Textem Mac (Android approval)** opens
Android's normal Bluetooth companion-device chooser (Android13+). Open Bluetooth
settings on the Mac to make it discoverable, select that actual Mac on the phone,
and approve Android's association request. No self-managed/system-only permission,
watch/computer role, root command or protection-disable toggle is used. Only
association IDs created by this flow and still confirmed by Android are claimed
as linked. **Remove Textem Mac companion link** removes those associations.

Android documents trusted companion associations as exempt from OTP notification
redaction. This remains a handset test requirement, not a guarantee: association
is not a transport connection or proof of code access. An existing listener may
need notification access reopened to refresh Android's cached trust. A fresh
posted unredacted code, explicit Mac source/account link and actual OS field fill
are separate remaining checks. Synthetic tests never create owner associations
or write test codes into the Mac's production vault.

References: [Android OTP hardening](https://developer.android.com/about/versions/15/behavior-changes-all#otp-fraud),
[companion pairing](https://developer.android.com/develop/connectivity/bluetooth/companion-device-pairing),
and [AOSP listener trust](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/services/core/java/com/android/server/notification/NotificationManagerService.java).

Separate local experiment, **not** an Android messaging replacement or a new
Google Messages paired computer. The Mac's Shared Phone Images panel can import
one explicitly saved graphic from companion v0.7 onward.

## Why this exists

The second native relay disconnected the normal web inbox. A phone-side reader
could avoid that relay arbitration entirely. Google's [storage/access help](https://support.google.com/messages/answer/10262381)
says received encrypted messages can be accessible to apps granted SMS or
notification permissions. That is a lead, **not** proof of business-message or
link-preview accessibility. The history probe tests public SMS/MMS provider access;
v0.8 adds a separately opted-in, metadata-only notification readiness check below.

Do not turn a
blocked permission, missing thread, or empty cursor into a claim that RCS is absent.

## Privacy and limitations

- Only `READ_SMS` is requested, after tapping **Choose a history thread**.
  That permission is broad: the OS can expose SMS/MMS across the phone. The probe
  indexes at most 50 recent thread snippets and reads the one you explicitly tap.
  Version 0.3 labels rows with bounded participant addresses/short codes, the last
  message date and a 200-character preview instead of an unhelpful row number.
  A local filter matches the loaded addresses/previews (case/accents ignored);
  it never searches older/unselected message bodies or increases the thread cap.
  Participants come from the SMS/MMS provider's [canonical-address route](https://android.googlesource.com/platform/packages/providers/TelephonyProvider/+/master/src/com/android/providers/telephony/MmsSmsProvider.java),
  at most 8 IDs per thread and 128 characters per address. Missing/blocked label
  lookups remain explicitly unavailable; they do not hide the thread. These
  are **not** Google business/contact names; no Contacts permission or lookup is
  added. Try a short code, number, brand word or recognizable phrase in a preview.
- The v0.13 optional local connection adds Internet, connected-device foreground
  service, network-state and notification permissions. No Google credentials,
  Google pairing, default-SMS role, root, Accessibility, sending, mark-read,
  deletion, or provider writes. No analytics or third-party runtime libraries.
  Notification access is optional and separately approved in Android from v0.8;
  it is never requested by history or image sharing.
- History and Inspect data appear only in the phone UI and process memory; image
  content is not saved unless **Save image for Mac** is explicitly selected
  (see below). Content is never logged. Screenshots are blocked; backup and device transfer are
  disabled. Version 0.2 saves only a fixed-key numeric/enum diagnostic snapshot
  in app-private `files/probe-summary.json`, so the paired Mac can retrieve
  counters automatically. It contains no message text, URLs, addresses or IDs.
  **Clear and return** deletes it; a new sample overwrites it. Reopening the app
  does not erase it. Only **Copy content-free summary** writes to the clipboard.
- Queries sample at most 20 rows **per source** (40 total SMS+MMS), with at most
  32 parts per MMS, 3 image reads, 6 MiB/image, and 20,000 characters/message.
  The UI reports reached caps. A full cursor/source failure remains distinguishable
  from successful empty results. These are sample limits, not completeness claims.
- History/Inspect images are decoded as bounded thumbnails to test actual
  readability, then discarded. A readable MMS attachment is **not** proof of a link-preview graphic
  or of Google's interactive-card schema. No destination URLs are fetched.
- SMS permission is [hard restricted](https://developer.android.com/reference/android/Manifest.permission#READ_SMS):
  the installer must allowlist it as well as the user granting it. If blocked,
  stop and report `BLOCKED`; do not change the default SMS app or bypass controls.
- Synthetic controls use invented data and the same scan engine. Their success
  validates the instrument, not actual Google Messages access on a handset.

## Build

Requirements: JDK 17+, Android SDK platform 35 and build tools, Internet access
for initial build dependencies. Runtime local-network access is described above;
the build requires no Google session or messaging credentials.

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
./build.sh
```

The checked-in Gradle wrapper pins 8.9 with its official distribution SHA-256.
Build output is `.build.nosync/app/outputs/apk/debug/app-debug.apk`; the test APK
is `.build.nosync/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk`.
Gradle caches/output stay in regenerable `.nosync` directories. This is a local,
debug-signed probe, not a Play Store or production release. No signing credentials
or user-local SDK paths belong in the repository.

## Scripted emulator validation

Use a fresh, explicitly selected API-35 emulator. Never use an unqualified `adb`
command that could select a real connected phone. The test requires SMS permission
to remain ungranted; **do not** install with `-g`.

```sh
./test-emulator.sh emulator-5584
```

The script refuses non-emulator targets, checks the emulator is booted, and exits
nonzero on an unsuccessful test (even if Android's instrument command exits zero).
The custom instrumentation has no JUnit/runtime dependencies. It exercises real
image decoding, positive and negative scan controls, all caps, sanitized reports,
the production parameterized query specs, real pre-query permission denial,
the installed permission/component manifest, and the actual Activity buttons and
visible result text. Expected instrumentation result code is `-1` and a `PASS`
stream. Result `0`, missing result, crash, timeout or `FAIL` means failure.

## Automated handset checks and report readback (v0.2)

After an explicit device pairing and app update, the operator can run checks
without asking the owner to tap through synthetic screens:

```sh
python3 -B -m unittest -v test_probe.py
python3 -B probe.py --serial PHONE_CONNECTION self-test
python3 -B probe.py --serial PHONE_CONNECTION report
```

`PHONE_CONNECTION` must be the explicitly approved current adb serial/endpoint;
no implicit device selection or network scanning is performed. The self-targeted
instrumentation is included in this local debug probe APK, so no separate test
APK is installed on the handset. It uses synthetic data, tests the real UI thread
list/selection/rendering/clear path, and measures that actual provider-query and
media-read counters do not increase. With SMS granted, no private provider is
queried. Without SMS granted, the early-denial guard is also exercised. Permissions
are never granted/revoked by the runner, and the result names the branch used.
The host has a 45-second test deadline; on timeout it stops only its own probe
test process, not Google Messages or the adb server. UI launches have a separate
15-second bound and fixed phase labels distinguish failures from slow startup.
The self-test preflight refuses an unbooted device instead of reporting a failed
probe check during operating-system startup.

Self-test temporarily opens the probe and clears the last diagnostic snapshot;
run it **before** selecting a real sample. `report` only reads the known private
metadata file, with a 4 KiB limit. It never opens a UI hierarchy, screenshot,
clipboard, or message store. The host parser rejects unknown/duplicate keys,
out-of-range values, synthetic kinds, impossible counts and stale (>30 minute)
snapshots before printing anything. Blocked/partial/empty samples remain distinct
from exposed content; none is a full-card verdict. A missing result exits nonzero.

The device owner still approves the Android permission prompt and chooses the
allowed real conversation once. There is no repeated manual report copying or
visual confirmation needed to collect text/link/image counters. Exact fidelity
against a private Google Messages thread remains a separate ground-truth question,
not something fixture success can establish.

Version 0.3's granted-handset runner has 83 assertions, including actual labelled
rows, accent-insensitive and no-match filtering, optional-label failure/cap
controls and correct original-thread selection after filtering. With permission
denied, the extra provider guard checks also run. Filtering text is not saved as
view state, autofill is excluded, and the input requests no keyboard suggestions
or personalized learning (the keyboard ultimately controls its own behavior).
No participant/date/preview/search fields were added to diagnostic readback.

## First handset sample (owner-coordinated, not automatic)

1. Install the **app APK only**, after approving the device and installer path.
   No real handset install or permission grant is performed by the build.
2. Run automated `self-test` first (or **Synthetic controls** if no adb link).
   A failure stops the experiment.
3. Tap **Choose a history thread** and review the SMS permission request. If the
   installer/system blocks it, keep Google Messages unchanged and stop.
4. Choose a known ordinary-text thread as the positive control, compare the
   displayed text on-device, then clear and choose one approved phone-only
   business thread. Never paste message contents or screenshots into diagnostics.
5. Read fixed-field counters with `report` (or copy only the content-free summary).
   Grade text, web links, image attachments,
   and the actual phone-preview graphic independently. If the thread is missing,
   record that rather than silently increasing scan scope.
6. Confirm Textem's normal inbox is still connected. Only then decide whether
   authenticated local transfer or notification support is worth building.
7. Clear/close the probe and revoke its SMS permission or uninstall when finished.

No historical RCS/business content has been proven accessible until this actual
device sample succeeds. Nothing here promises full cards or automatic syncing.

## Exact-graphic Share probe (v0.4)

The owner-selected a retailer provider sample had 20 text messages/20 links and no
MMS/image parts within the row cap. Google documents automatic previews as a
separate lookup, not necessarily a received attachment. Inspection of installed
Messages found a private rich-card image provider supporting temporary URI grants;
that does **not** establish that its Share UI exports automatic-preview graphics.

The APK now includes a separate **Textem Share Probe** sharesheet target for
`SEND`/`SEND_MULTIPLE` images, plain text and HTML text. If Google Messages offers
Share for an approved graphic, choose this target, then **Inspect shared item**.
Do not use Forward/send as a substitute. No Share action is an informative
negative outcome; there is no silent history/cache enumeration fallback.

- Nothing is opened before Inspect. Only up to 8 unique URI candidates are
  considered, with at most 3 image opens and 6 MiB per image (+1 sentinel byte).
  The decoder samples to at most 256px and rejects excessive source dimensions.
- The live path requires `content://`, an allowlisted Google Messages media
  authority, a private grant-capable provider owned by Google Messages, a read
  grant flag, and an actual explicit URI read grant. Existing SMS permission is
  **not** accepted instead. No new broad permission/provider/service is added;
  a package-visibility declaration permits only Messages provider-owner checks.
- Other providers, `file://`, network/SMS/MMS URIs and missing grants are blocked
  without opening. The fixed reason (`URI_POLICY`, `READ_GRANT_MISSING`,
  `PROVIDER_POLICY` or `READ_DENIED`) explains the boundary without exposing a URI.
  A policy block is not evidence that the sender shared no image.
- Text/links are counted but never displayed, copied, opened or saved. Image
  bytes are decoded only to verify readability, then discarded; no image is
  displayed, hashed, saved, transferred or uploaded. No HTML is rendered.
- The secure receiver is excluded from recents, does not preserve the incoming
  Intent as view state, and finishes when left. A 10-second UI deadline cancels
  its active descriptor/read; a single in-flight worker prevents accumulating
  reads, and generation checks reject late results from older Activities. A
  timeout is not success and its counters may omit an unfinished read.
- A fresh share clears only the previous share diagnostic, not the history
  report. Clear removes the share report. Returning to another app after Inspect
  keeps the fixed counters available to the paired Mac. No URI grant is persisted.

```sh
python3 -B probe.py --serial PHONE_CONNECTION share-report
```

This reads **only** app-private `files/share-summary.json`, at most4KiB, mode0600.
Version 0.4's 17 exact fields contain schema/kind/time, fixed state/block reason, bounded
counts and booleans; no text, URI, address, filename, source identity or image hash.
The existing 18-field history schema/file remain separate. Host checks reject
synthetic share reports, unknown/private fields, stale data, bad types, impossible
counts and false image-success states. `IMAGE_READABLE` means a decodable granted
shared image, **not** proof that it is the exact visible card, original-quality
asset, complete history, or useful Mac transfer. `TEXT_OR_LINK_ONLY`, `BLOCKED`,
`UNREADABLE`, `TIMEOUT` and empty/unsupported/malformed inputs remain distinct.

The automated self-test adds real-engine positive/negative byte controls and the
installed share Activity's waiting/Inspect/result/Clear flow, including a deliberately
blocked synthetic read to exercise its deadline. Fixture extras always replace
the entire input with synthetic data, and their report kind is rejected as live
evidence. The real explicit-grant denial guard is also exercised without opening
Google data. This is **not** a claim that positive Google-to-probe URI-grant
delivery has been tested until the owner performs the approved Share sample.
Self-test clears diagnostics; run it before selecting/sharing a real sample.

Verified v0.4 on the owner test phone: **154 automated assertions**, no real
image/provider reads and unchanged SMS grant;18 host tests,61 Mac tests, build,
signature and clean lint. Positive Google share delivery is still pending.
Providers may ignore cancellation; the receiver then blocks additional reads
instead of accumulating workers. Close/relaunch the probe if its worker remains
stuck. New SMS-denied emulator execution was not repeated for this version.

### Safe source diagnostics (v0.5)

The owner reported `BLOCKED / URI_POLICY` after a real Share. This proves an early
probe-policy rejection, not absent graphics or an Android permission denial.
Version 0.5 adds an instrument without widening any image-read rule:

- **URI rule** distinguishes allowed, non-content scheme, unknown authority,
  user/profile prefix, port, fragment and length limit. Multiple unlike inputs
  are explicitly `MULTIPLE`, not attributed to a single source.
- **Provider owner** is only `GOOGLE_MESSAGES`, `OTHER_APP`, `UNRESOLVED`,
  `UNAVAILABLE`, `NOT_CHECKED` or `MULTIPLE`. Dynamic provider/package names,
  paths, query strings, fragments, filenames and hashes are never retained.
- **Provider access** classifies private/grant-capable, exported, private without
  URI grants, or unresolved/unavailable/not-checked/multiple. This is metadata,
  not an authorization to read.
- **Explicit read grant** and the incoming **share read flag** are reported
  separately. These are point-in-time diagnostics; the original live read path
  still rechecks actual permissions immediately before opening.

Only after Inspect, bounded simple `content://` authorities can be looked up
using [PackageManager provider metadata](https://developer.android.com/reference/android/content/pm/PackageManager#resolveContentProvider(java.lang.String,%20int))
and [explicit URI-grant checks](https://developer.android.com/reference/android/content/Context#checkUriPermission(android.net.Uri,%20int,%20int,%20int)).
No provider is queried/opened for those diagnostic lookups. Invalid URI shapes
and non-content schemes skip metadata entirely. No new permission or package
visibility is added. `UNRESOLVED` can reflect Android package-visibility limits;
it is not proof that the provider does not exist. Metadata exceptions become
fixed `UNAVAILABLE` categories without replacing the original read verdict.

Share schema **2** has exactly **22 keys** (the existing 17 plus five fixed
diagnostic fields). The host still strictly accepts schema1's 17 keys, without
inventing absent source diagnostics. Both versions reject dynamic fields,
synthetic reports and impossible states. The history schema remains unchanged.
Timeout diagnostics can be `NOT_CHECKED` because an unfinished worker is not
allowed to publish a late or partial success. After updating, a **fresh Share →
Inspect** is required; old counters cannot reveal the previously rejected source.

Verified v0.5 on a dedicated API35 emulator: **246 denied-SMS assertions** and
**243 granted-SMS assertions**, including scripted installed source-diagnostic UI,
zero real content reads, unchanged original read boundaries, private schema2 and
Clear. **30 host tests**, **61 Mac tests**, APK build/signature and clean lint pass.
Handset installation, the real blocked source's categories, and exact-graphic
recovery are **pending**, not inferred from synthetic/emulator checks.

### Observed Google ProxyProvider correction (v0.6)

Direct owner-authorized UI inspection found a promotional graphic in the open
a pet-supplies business thread. Opening its media viewer exposes a real Share button; the system
chooser reports one image. A v0.5 real share was blocked before any open even
though its fixed diagnostics reported Google ownership, a private grant-capable
provider, an explicit read grant and the Intent read flag. The Android grant
record targeting this probe identifies the missing static authority as
`com.google.android.apps.messaging.shared.datamodel.ProxyProvider`.

Version 0.6 adds **only that exact authority**. A provider-name prefix is not
trusted, and all existing ownership/private-provider/actual-URI-grant checks and
read/decode bounds remain. No permission, component, package-visibility, schema,
transport, default messaging app or send capability is added. Synthetic controls
cover the new PNG route, lookalike authority, wrong provider policy, missing
flag/grant and the real production ungranted-URI guard with SMS already granted.
The relevant UI is **media viewer → Share → Textem Share Probe → Inspect**, not
Forward, a recipient picker, the history scan, or a screenshot shared as evidence.

Verified v0.6 on the owner test phone: **252 synthetic assertions** pass with
SMS granted and zero real content reads;30 host/61 Mac tests, build, signature
and clean lint pass. A new denied-SMS emulator run was not repeated. Then a fresh
real Google media-viewer share of the same a pet-supplies business graphic reports
**IMAGE_READABLE: one URI, one opened/decodable image, zero blocked/unreadable/
oversized/skipped items**, with a private Google provider and an explicit grant.
This fixes the observed v0.5 false policy block. It does **not** implement automatic
phone-history image recovery, Mac image transfer, or full interactive cards.
Temporary screen-timeout extension was restored; inspection screenshots were
removed and no phone message/image was deleted. Source bytes remain discarded
after the bounded decoder test, as before.

### Explicit local Mac image handoff (v0.7)

On a fresh Google Messages media-viewer share, choose **Textem Share Probe →
Save image for Mac**, rather than Inspect. Save reuses the existing exact Google
provider/explicit-grant guards and requires exactly one readable image. It
decodes and re-encodes a PNG no larger than 2048 pixels per side and 6 MiB;
original bytes/EXIF, URI, filename, message text and links are not exported.
This is a bounded representation, not original-byte identity or full-card recovery.

One active pending export is stored privately as `files/mac-image.json` and one
of two fixed PNG slots. The inactive slot is written first, then the manifest is
atomically replaced. Invalid input leaves the previous pair intact. At most two
PNG slots are retained. The fixed 10-key manifest contains only schema/kind,
random UUID, save time, fixed filename, MIME, dimensions, size and SHA-256.
Synthetic exports are isolated under cache and tagged `SYNTHETIC_IMAGE`; they
cannot replace a real pending image and the Mac refuses them.

**Remove saved Mac image** deletes the pending manifest and both slots, not the
original Google message. Clear diagnostics/close does not delete that export.
The export persists until replaced/removed or app data is cleared; Mac import
requires it to be no older than 24 hours. The separate Mac library persists until
its own **Remove Mac copy** action. The v0.7 image handoff adds no Internet
permission, listener or background sync. Content transfer is explicit over the
owner-authorized developer connection; do not publish collected image artifacts.

The Mac panel is **Textem → Shared Phone Images…**. It requires local
platform-tools and an authorized USB or TLS Wireless debugging phone. Enter the
current connection IP:port, not the pairing-code port. It imports only the fixed
app-private files, validates PNG/manifest/hash, bounds time/output/storage, and
does not associate images with an account or conversation by guessing.

Verified live v0.7 on the owner test phone: app-only update preserved SMS access;
287 synthetic assertions passed without actual provider reads. A fresh approved
Google Messages media-viewer share of the a pet-supplies business graphic saved a real
1050×700 PNG (571608 bytes). The signed Mac client imported it through the
production transport/store and rendered the actual cat/orange-bag graphic;
digest/size/dimensions and 0700/0600 Mac permissions were checked. A vendor-hidden
TLS port property initially caused a false refusal; the Mac checks an exact
TLS-connect mDNS record and its authorized named transport in that case. If
discovery is unavailable, a fixed, bounded CNXN/STLS protocol preflight verifies
the explicitly supplied listener requires TLS; adb still handles authenticated
encryption. Legacy AUTH/CNXN replies, malformed data and timeouts are refused.
No new permission, message send, ad-link click or full-history claim.

### Automatic recovery readiness check (v0.8)

This is an instrument, **not automatic content sync**. Open **Automatic recovery
setup** in the phone probe. **Enable checks and open Android access settings**
sets a separate local opt-in and opens Android's notification-access screen.
The owner must approve **Textem automatic recovery** there. Android's permission
is broad and can expose other apps' notifications; the service filters the exact
Google Messages package before retrieving its payload. Never grant this access
through ADB on the owner's device.

After both approvals, the passive listener samples new notifications and one
current non-summary Google Messages notification when connected/refreshed. It
examines at most 20 Google notifications: summaries-only stays `SUMMARY_SKIPPED`,
and an exhausted search cap is `UNAVAILABLE`, never successful empty. It
stores only fixed counts/types in private mode0600 `notification-summary.json`:
text lengths, bitmap/picture-icon presence, attachment-URI counts and identity
field presence. It never stores source text, titles, sender/notification IDs,
URI strings or pixels, loads icons/attachment URIs, invokes notification actions,
dismisses notifications or marks them read. At most 10 messages and 4000 characters
per text value are counted. It cannot establish historical completeness or that
notification graphics equal the phone's full card. MessagingStyle decoding needs
API30+; older devices report `UNAVAILABLE` rather than guessing Bundle fields.

**Disable checks** stops payload inspection without changing Android's permission;
revoke that permission in Android to remove system access. **Clear readiness
diagnostics** deletes only the report, not the saved Mac image or phone messages.
History, sharing and notification opt-in remain independent. The non-exported
listener is protected by Android's signature-level binding permission. Version
0.13 adds the explicit local connection described above; no Accessibility access.

```sh
python3 -B probe.py --serial PHONE_CONNECTION notification-report
```

The host reads only that known app-private report, rejecting synthetic, stale,
oversized, duplicate/unknown fields and impossible states without printing raw
errors/content. Synthetic notification controls use isolated cache and do not
change capture opt-in or OS access. Live notification delivery, content transport
and reliable conversation identity must be verified before automatic sync is built
or claimed ready. Existing explicit Share → Save → Mac import remains usable.

Verified v0.8: build/lint/signature, 36 host tests, 327 denied/324 granted API35
emulator assertions and 324 test phone assertions pass; existing SMS access and
the real saved export remain intact. The installed setup UI is script-checked.
An emulator-only permission grant proves Android binds the service and an actual
Refresh yields `ACTIVE_SCAN/EMPTY`. After the owner approved access, the actual
test phone listener reported `ACTIVE_SCAN/SHAPES_PRESENT`: three MessagingStyle text
entries (423 characters), a shortcut, and no picture/URI fields. That source is
not yet established as an affected business conversation; full cards/history
and exact graphics are not proven by this metadata sample.

### Separate local notification content sample (v0.9)

**Enable local content samples** is a separate opt-in, off by default. It needs
readiness checks and Android notification access too; approving metadata alone
does not save content. The owner has explicitly approved local text/available-image
capture for this development campaign. Enable it only after build/control gates.

The companion saves one latest notification sample, replacing its predecessor,
not a continuous inbox/history. It captures at most ten text previews (4000 UTF-16
units each), a 256-unit source title and one explicit bitmap picture. A plain
bitmap picture-icon can also qualify; avatars/large icons are never used as card
graphics. Pictures are re-encoded as PNG, at most2048px per side and1MiB. Unsupported
or oversized pictures do not erase usable text; URI/resource/adaptive icons are
not opened. No URLs in message text are fetched. Notification-level pictures are
not attributed to particular messages, nor called original/full-card graphics.

Only a nonempty Google shortcut supplies identity, combined with Google app UID
(including Android user) under a private per-install HMAC secret. Titles never
become identity. Another install/UID/shortcut produces a different key. Missing
identity is refused, never matched by sender/title. No raw shortcut, notification
ID, separate sender field or attachment URI leaves the phone. The approved title
and message text can naturally contain names, addresses or links; they are private
content, not content-free diagnostics. Content callbacks require API29+ and
MessagingStyle decoding API30+; unsupported older devices report unavailable.

The private mode0600 files are `notification-content.json` (2MiB maximum), the
fixed-state `notification-content-state.json`, and a separate private identity
file that is never transferred. The image is inline canonical base64, so the
sample is replaced atomically as a unit. A bounded single-worker/latest-only
queue, generation checks and opt-in revision checks prevent late publication
after Disable/Clear/close. Summary updates cannot cancel a queued individual.
This does not change Google pairing, default messaging, existing SMS grants,
shared-image exports or metadata report format. The metadata report's false
content-export/decode flags describe that counts-only report, not this separately
approved content file.

**Disable content samples** prevents new saves but retains the latest sample.
**Delete saved notification content** removes only that sample, not the stable
identity, Google messages, saved shared image or metadata. Disable first to prevent
a future new notification from repopulating the file. Files persist until replaced
or deleted; transfer accepts only samples captured within30 minutes. No new OS
permission or Internet/send/provider-write capability is added.

```sh
python3 -B probe.py --serial PHONE_CONNECTION notification-content-summary
```

This command reads fixed state/sample/state files, refuses a changed or stale
attempt and rejects synthetic/private/unknown fields and bad images. It outputs
only counts and support states, never a source title, message body, identifier,
URL or base64. Synthetic parser/encoder controls use isolated cache and cannot
overwrite owner files or arm content capture. A separately tagged synthetic cache
fixture permits automated Android-to-host PNG compatibility checks.

Validated locally:377 denied/374 granted API35 assertions,44 host tests, and87
Mac tests including actual native fixture rendering. The installed Mac viewer
uses specific support-state errors rather than suggesting more permissions for
unsupported source data. The signed universal desktop build is2026102605.
The test phone's v0.9 update and real content transfer are still pending reconnecting
its wireless-debugging listener; a real metadata sample is not a content-transfer
or business-card proof.
