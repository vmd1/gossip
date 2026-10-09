#!/bin/bash
# Cross-device end-to-end test of the relay: the Mac app's real TransportManager against the Android app's real
# TransportManager on an emulator, where the two talk to each other ONLY through a local relay server (relay/). Nothing
# touches a real phone or the real Gossip data on this Mac: the emulator is fresh and the Mac test host uses throwaway
# identity, trust and topic stores.
#
#   mac/scripts/e2e-relay-emulator.sh [avd-name]        (default AVD: a16; E2E_AVD overrides)
#
# Needs: Node 18+, an arm64 AVD, the Android SDK, a Rust toolchain (the apps build the engine), Xcode and XcodeGen.
# What it does: boots the AVD headless if none is running, builds and installs the debug app and the instrumentation APK,
# builds the relay, then runs mac/GossipTests/EmulatorRelayE2ETests. That test starts (and later kills and restarts) the relay
# on a free port, maps it into the emulator with `adb reverse` so both devices use the SAME address ws://127.0.0.1:<port>
# (the origin string is signed into every join, so it must match on both sides), pairs the devices over the LAN-style path,
# then takes the LAN away and checks everything over the relay. It takes about five minutes.
set -uo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$PATH"   # the apps build the Rust engine
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
AVD="${1:-${E2E_AVD:-a16}}"
SDK="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
ADB="${ADB:-$(command -v adb || echo "$SDK/platform-tools/adb")}"
NODE="$(command -v node)" || { echo "node is required"; exit 2; }
OUT="${TMPDIR:-/tmp}/gossip-e2e-relay-emulator"; mkdir -p "$OUT"
STARTED_EMULATOR=0

cleanup() {
  if [ -n "${SERIAL:-}" ]; then
    "$ADB" -s "$SERIAL" forward --remove-all >/dev/null 2>&1
    "$ADB" -s "$SERIAL" reverse --remove-all >/dev/null 2>&1
  fi
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

echo "== building the relay"
(cd "$REPO/relay" && { [ -d node_modules ] || npm ci --silent; } && npm run build --silent) || { echo "relay build failed"; exit 2; }

echo "== building the Android app and its instrumentation APK"
(cd "$REPO/android" && ./gradlew -q :app:assembleDebug :app:assembleDebugAndroidTest) || exit 2
"$ADB" -s "$SERIAL" install -r -t "$REPO/android/app/build/outputs/apk/debug/app-debug.apk" >/dev/null || exit 2
"$ADB" -s "$SERIAL" install -r -t "$REPO/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk" >/dev/null || exit 2
"$ADB" -s "$SERIAL" shell pm clear dev.vmd1.gossip >/dev/null 2>&1   # fresh app data: no identity, no trusted devices, no topic
"$ADB" -s "$SERIAL" logcat -c

echo "== building the protocol engine and the Mac test host"
"$HERE/build-core.sh" >/dev/null || exit 2
(cd "$REPO/mac" && xcodegen generate >/dev/null) || exit 2

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
echo "== running the cross-device relay end-to-end test (relay on 127.0.0.1:$PORT, about five minutes)"
(cd "$REPO/mac" && TEST_RUNNER_GOSSIP_E2E_ADB_SERIAL="$SERIAL" TEST_RUNNER_GOSSIP_E2E_ADB="$ADB" \
  TEST_RUNNER_GOSSIP_E2E_RELAY_DIR="$REPO/relay" TEST_RUNNER_GOSSIP_E2E_NODE="$NODE" TEST_RUNNER_GOSSIP_E2E_RELAY_PORT="$PORT" \
  xcodebuild -project Gossip.xcodeproj -scheme Gossip -configuration Debug -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$OUT/derived" test -only-testing:GossipTests/EmulatorRelayE2ETests >"$OUT/xcodebuild.log" 2>&1)
STATUS=$?
grep -E "Android E2E log|E2E:|OK \(|FAILURES|Test Case .*(passed|failed|skipped)|error:|XCTAssert|failed:|timed out" "$OUT/xcodebuild.log" | grep -v "linkd\|Registry" | head -120
echo "== full logs: $OUT/xcodebuild.log, $OUT/emulator.log"
[ $STATUS -eq 0 ] && echo "RELAY EMULATOR E2E PASSED" || echo "RELAY EMULATOR E2E FAILED"
exit $STATUS
