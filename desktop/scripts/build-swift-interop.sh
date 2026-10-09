#!/bin/sh
# Builds the Swift side of the interop tests: a harness around the Mac app's real crypto/envelope sources.
# Output: desktop/target/interop/swift-harness. The Rust interop test skips itself when this is missing.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/target/interop"
mkdir -p "$out"
swiftc -O -o "$out/swift-harness" \
  "$repo/mac/Gossip/Crypto/NoiseSession.swift" \
  "$repo/mac/Gossip/Transport/Envelope.swift" \
  "$repo/mac/Gossip/Transport/EnvelopeSigning.swift" \
  "$repo/mac/Gossip/Features/Hotspot/HotspotGattProtocol.swift" \
  "$here/interop/swift/main.swift"
echo "built $out/swift-harness"
