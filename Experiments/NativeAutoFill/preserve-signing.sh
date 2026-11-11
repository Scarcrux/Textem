#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then echo 'usage: preserve-signing.sh candidate.app installed-reference.app' >&2; exit 1; fi
sign_candidate_path="$(cd "$1" && pwd -P)"
sign_reference_path="$(cd "$2" && pwd -P)"
test "$sign_candidate_path" != "$sign_reference_path"
case "$sign_candidate_path" in /Applications/*) echo 'refusing to re-sign an installed app' >&2; exit 1;; esac
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$sign_candidate_path/Contents/Info.plist")" = com.scarcrux.textem
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$sign_reference_path/Contents/Info.plist")" = com.scarcrux.textem
codesign --verify --deep --strict "$sign_reference_path"
sign_requirement="$(codesign -dr - "$sign_reference_path" 2>&1 | sed -n 's/^designated => //p')"
test -n "$sign_requirement"
# Xcode export synthesizes a broader default requirement with a Mac App Store
# alternative. Keep the installed app's exact Developer ID requirement instead;
# preserve the exported signed entitlements and nested extension's signature.
codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
  --requirements "=designated => $sign_requirement" \
  --sign 99842B5A6A3B15AEF88EC89CE9A1B67E46F4B9C8 "$sign_candidate_path"
codesign --verify --deep --strict "$sign_candidate_path"
