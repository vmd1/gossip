#!/bin/bash
# End-to-end test of the Mac app against the Android app on an emulator, both running their real TransportManager and the
# Rust protocol engine. Nothing touches a real phone or the real Gossip data on this Mac: the emulator is fresh and the
# Mac test host uses throwaway identity and trust stores.
#
#   mac/scripts/e2e-emulator.sh [avd-name]        (default AVD: a16; E2E_AVD overrides)
#
# Needs: an arm64 AVD, the Android SDK, a Rust toolchain (the apps build the engine), Xcode and XcodeGen.
# What it does: boots the AVD headless if none is running, builds and installs the debug app and the instrumentation APK,
# then runs mac/GossipTests/EmulatorE2ETests, which starts the Android side (android/.../e2e/TransportE2eTest) itself.
set -uo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$PATH"   # the apps build the Rust engine
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AVD="${1:-${E2E_AVD:-a16}}"
SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="${ADB:-$(command -v adb || echo "$SDK/platform-tools/adb")}"
OUT="${TMPDIR:-/tmp}/gossip-e2e"; mkdir -p "$OUT"
STARTED_EMULATOR=0

cleanup() {
  [ -n "${SERIAL:-}" ] && "$ADB" -s "$SERIAL" forward --remove-all >/dev/null 2>&1
  if [ "$STARTED_EMULATOR" = 1 ] && [ -n "${SERIAL:-}" ]; then "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1; fi
}
trap cleanup EXIT

SERIAL="$("$ADB" devices | awk '/^emulator-[0-9]+\tdevice/{print $1; exit}')"
if [ -z "$SERIAL" ]; then
  echo "== booting emulator $AVD"
  nohup "$SDK/emulator/emulator" -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot-save -gpu swiftshader_indirect >"$OUT/emulator.log" 2>&1 &
  STARTED_EMULATOR=1
  for _ in $(seq 1 120); do
    SERIAL="$("$ADB" devices | awk '/^emulator-[0-9]+\tdevice/{print $1; exit}')"
    [ -n "$SERIAL" ] && [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
    SERIAL=""; sleep 2
  done
  [ -n "$SERIAL" ] || { echo "emulator did not boot (see $OUT/emulator.log)"; exit 2; }
fi
echo "== using $SERIAL"

echo "== building the Android app and its instrumentation APK"
(cd "$REPO/android" && ./gradlew -q :app:assembleDebug :app:assembleDebugAndroidTest) || exit 2
"$ADB" -s "$SERIAL" install -r -t "$REPO/android/app/build/outputs/apk/debug/app-debug.apk" >/dev/null || exit 2
"$ADB" -s "$SERIAL" install -r -t "$REPO/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk" >/dev/null || exit 2
"$ADB" -s "$SERIAL" shell pm clear dev.vmd1.gossip >/dev/null 2>&1   # fresh app data: no identity, no trusted devices
"$ADB" -s "$SERIAL" logcat -c

echo "== building the protocol engine and the Mac test host"
"$HERE/build-core.sh" >/dev/null || exit 2
(cd "$REPO/mac" && xcodegen generate >/dev/null) || exit 2

echo "== running the end-to-end test (about three minutes)"
(cd "$REPO/mac" && TEST_RUNNER_GOSSIP_E2E_ADB_SERIAL="$SERIAL" TEST_RUNNER_GOSSIP_E2E_ADB="$ADB" \
  xcodebuild -project Gossip.xcodeproj -scheme Gossip -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$OUT/derived" test -only-testing:GossipTests/EmulatorE2ETests >"$OUT/xcodebuild.log" 2>&1)
STATUS=$?
grep -E "Android E2E log|E2E:|OK \(|FAILURES|Test Case .*(passed|failed|skipped)|error:|XCTAssert|failed:|timed out" "$OUT/xcodebuild.log" | grep -v "linkd\|Registry" | head -80
echo "== full logs: $OUT/xcodebuild.log, $OUT/emulator.log"
[ $STATUS -eq 0 ] && echo "E2E PASSED" || echo "E2E FAILED"
exit $STATUS
