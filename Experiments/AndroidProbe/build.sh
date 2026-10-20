#!/bin/sh
set -eu
cd "$(dirname "$0")"
if [ "$#" -eq 0 ]; then
    set -- assembleDebug assembleDebugAndroidTest lintDebug
fi
# Keep regenerable Gradle state out of iCloud. Module output also uses .nosync.
exec ./gradlew --project-cache-dir .gradle.nosync "$@"
