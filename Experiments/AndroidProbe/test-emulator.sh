#!/bin/sh
set -eu
cd "$(dirname "$0")"
probe_serial=${1:?Pass an explicit emulator serial, for example emulator-5584}
case "$probe_serial" in emulator-*) ;; *) echo 'Refusing a non-emulator target' >&2; exit 1;; esac
probe_adb=${ANDROID_HOME:?Set ANDROID_HOME}/platform-tools/adb
[ "$("$probe_adb" -s "$probe_serial" shell getprop ro.kernel.qemu | tr -d '\r')" = 1 ]
[ "$("$probe_adb" -s "$probe_serial" shell getprop sys.boot_completed | tr -d '\r')" = 1 ]
"$probe_adb" -s "$probe_serial" install -r .build.nosync/app/outputs/apk/debug/app-debug.apk
"$probe_adb" -s "$probe_serial" install -r .build.nosync/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
probe_result=$("$probe_adb" -s "$probe_serial" shell am instrument -w -r dev.textem.probe.test/dev.textem.probe.ProbeInstrumentation)
printf '%s\n' "$probe_result"
# am instrument can itself exit zero for a failing test; require both signals.
case "$probe_result" in *'INSTRUMENTATION_RESULT: stream=PASS:'*) ;; *) exit 1;; esac
case "$probe_result" in *'INSTRUMENTATION_CODE: -1'*) ;; *) exit 1;; esac
