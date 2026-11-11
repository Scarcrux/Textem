#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
make icloud-heal
mkdir -p .build.nosync/native-autofill-project
xcodegen generate --spec Experiments/NativeAutoFill/project.yml --project-root "$PWD" \
  --project "$PWD/.build.nosync/native-autofill-project"
echo 'Generated an experimental Xcode host + extension project; no install or OS enablement.'
