#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
make icloud-heal
out="$PWD/.build.nosync/native-autofill-consumer"
app="$out/TextemAutoFillConsumer.app"
mkdir -p "$app/Contents/MacOS"
chmod 700 "$out"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --toolchain XcodeDefault swiftc -swift-version 6 -warnings-as-errors \
  Experiments/NativeAutoFill/ConsumerTest/main.swift -o "$app/Contents/MacOS/TextemAutoFillConsumer"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.textem.autofill-consumer</string>
<key>CFBundleName</key><string>Textem AutoFill Consumer Test</string>
<key>CFBundleExecutable</key><string>TextemAutoFillConsumer</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string><key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo 'Distinct local consumer built; no provider registration, production vault access or system fill claimed.'
