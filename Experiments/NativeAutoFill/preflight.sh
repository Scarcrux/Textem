#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
make icloud-heal
mkdir -p .build.nosync/native-autofill
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  Experiments/NativeAutoFill/Core/Provisioning.swift Experiments/NativeAutoFill/main.swift \
  -o .build.nosync/native-autofill/preflight
.build.nosync/native-autofill/preflight
