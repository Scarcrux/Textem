#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != --migrate-identifier ) ]]; then
  echo 'usage: signed-build.sh [--migrate-identifier]' >&2
  exit 1
fi
: "${BUILD_NUMBER:?Set BUILD_NUMBER to a new numeric build version}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,12}$ ]]
textem_version="${VERSION:-1.0b3}"
[[ "$textem_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+|b[1-9][0-9]*)$ ]] || {
  echo 'VERSION must be a release (1.0.0) or a beta (1.0b2)' >&2
  exit 1
}
textem_reference_app="${TEXTEM_REFERENCE_APP:-/Applications/Textem.app}"
textem_release_root="$PWD/.build.nosync/native-autofill-release-$BUILD_NUMBER"
textem_jobs="${COMMANDEM_SWIFT_JOBS:-4}"
[[ "$textem_jobs" =~ ^[1-9][0-9]?$ ]]
bash Experiments/NativeAutoFill/project.sh
mkdir -p "$textem_release_root"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -jobs "$textem_jobs" \
  -project .build.nosync/native-autofill-project/TextemNativeCodes.xcodeproj \
  -scheme TextemNativeCodes -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$textem_release_root/derived" -archivePath "$textem_release_root/Textem.xcarchive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="$textem_version" archive
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -exportArchive \
  -archivePath "$textem_release_root/Textem.xcarchive" -exportPath "$textem_release_root/export" \
  -exportOptionsPlist Experiments/NativeAutoFill/DeveloperIDExport.plist -allowProvisioningUpdates
bash Experiments/NativeAutoFill/preserve-signing.sh "$textem_release_root/export/Textem.app" "$textem_reference_app" "$@"
bash Experiments/NativeAutoFill/verify.sh "$textem_release_root/export/Textem.app" "$textem_reference_app" "$BUILD_NUMBER" "$@"
echo 'Developer ID artifact verified. Notarization and installation are separate; nothing published or installed.'
