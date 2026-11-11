#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
make icloud-heal
study="$PWD/Experiments/NativeAutoFill"
out="$PWD/.build.nosync/native-autofill"
mkdir -p "$out/TextemCodeProvider.appex/Contents/MacOS"
sdk="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)"
for arch in arm64 x86_64; do
  mkdir -p "$out/$arch"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -sdk "$sdk" \
    -target "$arch-apple-macos15.0" -emit-library -static -emit-module \
    -module-name NativeAutoFillCore "$study"/Core/*.swift \
    -emit-module-path "$out/$arch/NativeAutoFillCore.swiftmodule" -o "$out/$arch/libNativeAutoFillCore.a"
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -sdk "$sdk" \
    -target "$arch-apple-macos15.0" -application-extension -parse-as-library \
    -I "$out/$arch" -L "$out/$arch" -lNativeAutoFillCore \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "$study/Provider/CredentialProvider.swift" -o "$out/$arch/TextemCodeProvider"
done
lipo -create "$out/arm64/TextemCodeProvider" "$out/x86_64/TextemCodeProvider" \
  -output "$out/TextemCodeProvider.appex/Contents/MacOS/TextemCodeProvider"
cp "$study/Extension-Info.plist" "$out/TextemCodeProvider.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-1}" "$out/TextemCodeProvider.appex/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION:-0.1.0}" "$out/TextemCodeProvider.appex/Contents/Info.plist"
plutil -lint "$out/TextemCodeProvider.appex/Contents/Info.plist"
codesign --force --sign - "$out/TextemCodeProvider.appex"
codesign --verify --strict "$out/TextemCodeProvider.appex"
echo 'Compiled universal experimental extension; NOT provisioned, installed, or activated.'
