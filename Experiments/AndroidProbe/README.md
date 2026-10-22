# Textem read-only Android probe

Separate local experiment, **not** an Android messaging replacement or a new
Google Messages paired computer. The shipping Mac app is unchanged.

## Why this exists

The second native relay disconnected the normal web inbox. A phone-side reader
could avoid that relay arbitration entirely. Google's [storage/access help](https://support.google.com/messages/answer/10262381)
says received encrypted messages can be accessible to apps granted SMS or
notification permissions. That is a lead, **not** proof of business-message or
link-preview accessibility. This probe tests only public SMS/MMS provider access.

`PREREGISTRATION.md` defines the sample and its stop conditions. Do not turn a
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
- No Internet permission, networking, notification access, Google credentials,
  Google pairing, default-SMS role, root, Accessibility, sending, mark-read,
  deletion, or provider writes. No analytics or third-party runtime libraries.
- Message data appears only in the phone UI and process memory. It is not saved
  or logged by the app. Screenshots are blocked; backup and device transfer are
  disabled. Version 0.2 saves only a fixed-key numeric/enum diagnostic snapshot
  in app-private `files/probe-summary.json`, so the paired Mac can retrieve
  counters automatically. It contains no message text, URLs, addresses or IDs.
  **Clear and return** deletes it; a new sample overwrites it. Reopening the app
  does not erase it. Only **Copy content-free summary** writes to the clipboard.
- Queries sample at most 20 rows **per source** (40 total SMS+MMS), with at most
  32 parts per MMS, 3 image reads, 6 MiB/image, and 20,000 characters/message.
  The UI reports reached caps. A full cursor/source failure remains distinguishable
  from successful empty results. These are sample limits, not completeness claims.
- Images are decoded as bounded thumbnails to test actual readability, then
  discarded. A readable MMS attachment is **not** proof of a link-preview graphic
  or of Google's interactive-card schema. No destination URLs are fetched.
- SMS permission is [hard restricted](https://developer.android.com/reference/android/Manifest.permission#READ_SMS):
  the installer must allowlist it as well as the user granting it. If blocked,
  stop and report `BLOCKED`; do not change the default SMS app or bypass controls.
- Synthetic controls use invented data and the same scan engine. Their success
  validates the instrument, not actual Google Messages access on a handset.

## Build

Requirements: JDK 17+, Android SDK platform 35 and build tools, Internet access
for initial build dependencies. This does **not** give the APK Internet access.

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
