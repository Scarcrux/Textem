#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# These controls run before invoking Xcode or touching a signed bundle.
for version in 1.0b0 1.0b2-extra 1.0; do
  if output="$(BUILD_NUMBER=1 VERSION="$version" bash Experiments/NativeAutoFill/signed-build.sh 2>&1)"; then
    echo "Unexpectedly accepted version: $version" >&2
    exit 1
  fi
  [[ "$output" == 'VERSION must be a release (1.0.0) or a beta (1.0b2)' ]]
done

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
for target in candidate reference; do
  mkdir -p "$fixture/$target.app/Contents"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string test.example.$target" "$fixture/$target.app/Contents/Info.plist" >/dev/null
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.scarcrux.textem' "$fixture/candidate.app/Contents/Info.plist"

if output="$(bash Experiments/NativeAutoFill/preserve-signing.sh "$fixture/candidate.app" "$fixture/reference.app" 2>&1)"; then
  echo 'Unexpectedly accepted a different reference identifier' >&2
  exit 1
fi
[[ "$output" == Reference\ bundle\ identifier\ differs.* ]]
if output="$(bash Experiments/NativeAutoFill/preserve-signing.sh "$fixture/candidate.app" "$fixture/reference.app" --migrate-identifier 2>&1)"; then
  echo 'Unexpectedly accepted an unrelated identifier for migration' >&2
  exit 1
fi

echo 'Version and identifier guard controls passed'
