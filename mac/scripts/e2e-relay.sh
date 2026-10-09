#!/bin/bash
# End-to-end test of the relay path on the Mac: starts the local relay server from relay/ on a free port, then runs
# mac/GossipTests/RelayE2ETests, which pairs two in-process Mac TransportManagers through it (the LAN is off) and
# exchanges messages, including a 1 MiB payload.
#
#   mac/scripts/e2e-relay.sh
#
# Needs: Node 18+, a Rust toolchain (the Mac app builds the engine), Xcode and XcodeGen. Nothing touches the real Gossip
# data on this Mac: the test host uses throwaway identities, trust stores and topic storage.
#
# The Mac-to-Android half (a real emulator, only the relay between them) is mac/scripts/e2e-relay-emulator.sh.
set -uo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/gossip-e2e-relay"; mkdir -p "$OUT"
RELAY_PID=""

cleanup() { [ -n "$RELAY_PID" ] && kill "$RELAY_PID" >/dev/null 2>&1; }
trap cleanup EXIT

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
ORIGIN="ws://127.0.0.1:$PORT"

echo "== building the relay"
(cd "$REPO/relay" && { [ -d node_modules ] || npm ci --silent; } && npm run build --silent) || { echo "relay build failed"; exit 2; }

echo "== starting the relay on $ORIGIN"
(cd "$REPO/relay" && HOST=127.0.0.1 PORT="$PORT" POW_BITS=8 RELAY_ORIGIN="$ORIGIN" LOG_LEVEL=warn exec node dist/src/relay.js) >"$OUT/relay.log" 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(s.connect_ex(('127.0.0.1',$PORT)))" 2>/dev/null && break
  kill -0 "$RELAY_PID" 2>/dev/null || { echo "relay exited early:"; cat "$OUT/relay.log"; exit 2; }
  sleep 0.2
done

echo "== building the protocol engine and the Mac test host"
"$HERE/build-core.sh" >/dev/null || exit 2
(cd "$REPO/mac" && xcodegen generate >/dev/null) || exit 2

echo "== running the relay end-to-end test"
(cd "$REPO/mac" && TEST_RUNNER_GOSSIP_E2E_RELAY="$ORIGIN" \
  xcodebuild -project Gossip.xcodeproj -scheme Gossip -configuration Debug -destination 'platform=macOS' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$OUT/derived" test -only-testing:GossipTests/RelayE2ETests >"$OUT/xcodebuild.log" 2>&1)
STATUS=$?
grep -E "Test Case .*(passed|failed|skipped)|error:|XCTAssert|failed:|timed out|Executed" "$OUT/xcodebuild.log" | head -40
echo "== logs: $OUT/xcodebuild.log, $OUT/relay.log"
[ $STATUS -eq 0 ] && echo "RELAY E2E PASSED" || echo "RELAY E2E FAILED"
exit $STATUS
