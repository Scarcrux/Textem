#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
make icloud-heal
xcrun --toolchain XcodeDefault swift package resolve
mkdir -p .build.nosync/sparkle-resources
cp .build/artifacts/sparkle/Sparkle/LICENSE .build.nosync/sparkle-resources/Sparkle-LICENSE
mkdir -p .build.nosync/native-autofill-project
xcodegen generate --spec Experiments/NativeAutoFill/project.yml --project-root "$PWD" \
  --project "$PWD/.build.nosync/native-autofill-project"
echo 'Generated an experimental Xcode host + extension project; no install or OS enablement.'
