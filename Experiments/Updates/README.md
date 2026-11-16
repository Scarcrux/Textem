# Signed updates

Textem embeds stable Sparkle 2.10.0 through a pinned Swift package in both build
paths, preserving its license in `Contents/Resources/Sparkle-LICENSE`.
**Textem → Check for Updates…** uses Sparkle's standard update UI.
**Settings → Updates** controls automatic checks using Sparkle's own stored
preference. Checks default off without an extra permission prompt. Automatic
installation and system profiling are disabled. Archives are verified before
extraction; the appcast must also carry a valid Ed25519 signature.

The intended feed is `https://textem.scarcrux.com/updates/appcast.xml`. Integration
and local staging do not publish this feed or an application release. Until the
first signed feed and archive are published, a manual network check may report
that the feed is unavailable; this is not an up-to-date verdict. A real update
check/install through the published channel remains a release gate.

## Key and staging

The private signing key stays in the login Keychain under Sparkle's
`textem-updates` account, separate from other projects. Only `SUPublicEDKey` is
committed. Do not export the private key into the repository, logs, shell
arguments, CI variables or the web server. The official `generate_keys --account
textem-updates -p` command reads only the public key.

Resolve dependencies, build a Developer ID app using
`Experiments/NativeAutoFill/signed-build.sh`, and notarize/staple it using the
existing local signing workflow. Then run:

```sh
bash Experiments/Updates/stage.sh /path/to/notarized/Textem.app
```

This refuses unsigned/unnotarized apps, a signing-public-key mismatch, disabled
verification flags, or an existing output directory. It stages one ZIP and a
signed `appcast.xml` in `.build.nosync/updates/BUILD/` using official Sparkle
tools. `verify.py` checks bundle identity, build, exact HTTPS URL, length, and
both archive and feed signatures. The staging script has no upload or publish
step. Preserve the generated feed bytes; edits invalidate its signature.

Publishing the archive and appcast is a separate manually approved release.
Future updates must keep a monotonically increasing `CFBundleVersion`, the
existing designated signing requirement, and the public update key. Never
replace only the application executable or omit Sparkle's nested signed helpers.

## Verification

`swift test` covers configuration and lifecycle guards, opt-in preference
writes, busy/startup failures, official-tool signature acceptance, and rejection
of altered archives, wrong keys, unsigned or altered feeds. Synthetic controls
use temporary private keys and never the project's Keychain signing secret.
The opt-in native design test renders the settings and scrolls to the bottom.

An explicit `--check-app-updates` launch writes a private, content-free
`Diagnostics/app-update-check.json` report: actual startup/check readiness,
automatic-check state, signing requirements, and embedded framework version.
It does not perform a network check, install anything, or navigate the app.

Sources: [setup](https://sparkle-project.org/documentation/),
[programmatic integration](https://sparkle-project.org/documentation/programmatic-setup/),
[settings](https://sparkle-project.org/documentation/customization/).
