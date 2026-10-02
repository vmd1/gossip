#!/bin/bash
# Scripted Universal Control end-to-end test against a real Android device (no mesh, no Mac app needed).
#
# Prerequisites: the debug APK is installed (`./gradlew :app:installDebug`, or `adb install -r`), Gossip's
# foreground service is running, and Shizuku is running on the device. The device may stay locked: the probe
# activity shows over the keyguard.
#
#   mac/scripts/run-tablet-e2e.sh [adb-serial] [scenario...]      (default scenarios: basic idle)
#
# It starts a control session through the debug-only adb receiver, then drives it with the same Swift
# protocol code the Mac app uses (mac/scripts/e2e/main.swift) and asserts on logcat (tag GossipProbe =
# what the system delivered to an app) and `dumpsys input` (the virtual devices appear and disappear).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERIAL="${1:-$(adb devices | awk 'NR==2{print $1}')}"; shift || true
SCENARIOS=("${@:-basic idle}")
ADB=(adb -s "$SERIAL")
OUT="${TMPDIR:-/tmp}/ucontrol-e2e"; mkdir -p "$OUT"
DRIVER="$OUT/ucdriver"
FAILS=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILS=$((FAILS+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

swiftc -O -o "$DRIVER" "$HERE/../Gossip/Features/UniversalControl/ControlProtocol.swift" \
  "$HERE/../Gossip/Features/UniversalControl/ControlWebSocketClient.swift" "$HERE/e2e/main.swift" 2>&1 | grep error && exit 2

SECRET_HEX="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
SECRET_B64="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

start_session() { # $1 = session id; echoes the port
  "${ADB[@]}" logcat -c
  "${ADB[@]}" shell am broadcast -n dev.vmd1.gossip/.debug.ControlDebugReceiver -a dev.vmd1.gossip.debug.CONTROL_START \
    --es sessionId "$1" --es secret "$SECRET_B64" >/dev/null
  for _ in $(seq 1 40); do
    port=$("${ADB[@]}" logcat -d -s ControlBridge | sed -n "s/.*\[$1\] listening on port \([0-9]*\).*/\1/p" | tail -1)
    [ -n "$port" ] && { echo "$port"; return 0; }
    sleep 0.5
  done
  return 1
}
end_session() { "${ADB[@]}" shell am broadcast -n dev.vmd1.gossip/.debug.ControlDebugReceiver -a dev.vmd1.gossip.debug.CONTROL_END --es sessionId "$1" >/dev/null; sleep 1.5; }
devices() { "${ADB[@]}" shell dumpsys input | grep -c "Gossip \(Mouse\|Keyboard\)" ; }

for scenario in ${SCENARIOS[@]}; do
  echo "== scenario: $scenario"
  "${ADB[@]}" shell am start -n dev.vmd1.gossip/.debug.InputProbeActivity >/dev/null; sleep 1.5
  SID="e2e-$scenario-$RANDOM"
  PORT=$(start_session "$SID") || { fail "session did not become ready (is Shizuku running?)"; continue; }
  # UC_HOST=<device LAN ip> connects directly over Wi-Fi like the Mac app does (no adb tunnel jitter).
  if [ -z "${UC_HOST:-}" ]; then "${ADB[@]}" forward tcp:"$PORT" tcp:"$PORT" >/dev/null; fi
  check "no virtual devices before entering" '[ "$(devices)" = "0" ]'
  "${ADB[@]}" logcat -c
  "$DRIVER" "${UC_HOST:-127.0.0.1}" "$PORT" "$SID" "$SECRET_HEX" "$scenario" | tee "$OUT/$scenario.driver.log" &
  DRV=$!
  if [ "$scenario" = basic ]; then
    sleep 3; check "mouse + keyboard exist while the cursor is on the device" '[ "$(devices)" -ge 2 ]'
  fi
  wait $DRV
  "${ADB[@]}" logcat -d > "$OUT/$scenario.logcat"
  grep GossipProbe "$OUT/$scenario.logcat" > "$OUT/$scenario.probe"
  case "$scenario" in
  basic)
    check "virtual devices removed after leave" '[ "$(devices)" = "0" ]'
    check "mouse hovers (>=15 HOVER_MOVE from Gossip Mouse)" '[ "$(grep -c "HOVER_MOVE.*dev=Gossip Mouse" "$OUT/basic.probe")" -ge 15 ]'
    check "entered at the left edge" 'grep -m1 "HOVER_.*x=0.0 " "$OUT/basic.probe" >/dev/null || grep -m1 "HOVER_.*x=[0-3]\.[0-9] " "$OUT/basic.probe" >/dev/null'
    check "primary click: DOWN buttons=0x1 then UP" 'grep -q "ACTION_DOWN.*buttons=0x1" "$OUT/basic.probe" && grep -q "ACTION_UP" "$OUT/basic.probe"'
    check "secondary click: buttons=0x2" 'grep -q "buttons=0x2" "$OUT/basic.probe"'
    check "scroll up, down and right arrive with the right signs" 'grep -q "scroll v=1.0 h=0.0" "$OUT/basic.probe" && grep -q "scroll v=-[1-9]" "$OUT/basic.probe" && grep -q "scroll v=0.0 h=1.0" "$OUT/basic.probe"'
    check "HID key a: KEYCODE_A down/up from Gossip Keyboard" 'grep -q "key action=DOWN code=KEYCODE_A meta=0x0 char=a.*Gossip Keyboard" "$OUT/basic.probe" && grep -q "key action=UP code=KEYCODE_A" "$OUT/basic.probe"'
    check "ctrl+a: meta has CTRL_ON" 'grep -q "key action=DOWN code=KEYCODE_A meta=0x[0-9a-f]*1[0-9a-f]*000" "$OUT/basic.probe" || grep -q "code=KEYCODE_A meta=0x[1-9a-f][0-9a-f]\{3,\}" "$OUT/basic.probe"'
    check "enter key" 'grep -q "code=KEYCODE_ENTER" "$OUT/basic.probe"'
    check "typed text 'Hello 42' arrives as key events" 'for c in H E L O 4 2 SPACE; do grep -q "code=KEYCODE_$c" "$OUT/basic.probe" || exit 1; done'
    check "no screen sleep was issued" '! grep -q "KEYCODE_SLEEP" "$OUT/basic.logcat"'
    check "no scrcpy video/mirror window" '! grep -qi "scrcpy stream open\|ScreenBridge" "$OUT/basic.logcat"'
    ;;
  idle)
    check "screen state unchanged (not put to sleep)" '"${ADB[@]}" shell dumpsys power | grep -q "mWakefulness=Awake\|Wakefulness=Awake"'
    ;;
  drift) ;;
  esac
  end_session "$SID"
  "${ADB[@]}" forward --remove tcp:"$PORT" >/dev/null 2>&1
done
echo; [ "$FAILS" = 0 ] && echo "ALL PASSED" || { echo "$FAILS FAILED"; exit 1; }
