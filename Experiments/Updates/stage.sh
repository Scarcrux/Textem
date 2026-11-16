#!/bin/bash
# Stage only. Publishing an update is a separate owner-approved release step.
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
test "$#" -eq 1 || { echo 'usage: bash Experiments/Updates/stage.sh /path/to/signed/Textem.app' >&2; exit 1; }
update_app="$(cd "$1" && pwd -P)"
update_tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
test -x "$update_tools/generate_appcast" || { echo 'Resolve the pinned Sparkle package first.' >&2; exit 1; }
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$update_app/Contents/Info.plist")" = com.scarcrux.textem
test "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$update_app/Contents/Info.plist")" = true
test "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$update_app/Contents/Info.plist")" = true
update_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$update_app/Contents/Info.plist")"
[[ "$update_version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$update_app/Contents/Info.plist")" = "$("$update_tools/generate_keys" --account textem-updates -p)"
codesign --verify --deep --strict "$update_app"
spctl --assess --type execute "$update_app"
xcrun stapler validate "$update_app" >/dev/null
update_output="$PWD/.build.nosync/updates/$update_version"
test ! -e "$update_output" || { echo 'Refusing to overwrite an existing staged release.' >&2; exit 1; }
mkdir -p "$update_output"
ditto -c -k --keepParent "$update_app" "$update_output/Textem-$update_version.zip"
"$update_tools/generate_appcast" --account textem-updates --maximum-deltas 0 \
  --download-url-prefix 'https://textem.scarcrux.com/updates/' \
  --link 'https://textem.scarcrux.com/' "$update_output" >"$update_output/generation.log" 2>&1
python3 Experiments/Updates/verify.py "$update_output"
echo "Signed update archive and feed staged locally for build $update_version. Nothing uploaded."
