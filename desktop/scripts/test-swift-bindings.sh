#!/bin/sh
# Builds the FFI library, generates the Swift bindings, compiles them with a smoke test and runs it.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
cargo build -p gossip-ffi
gen=target/gen/swift
rm -rf "$gen" && mkdir -p "$gen"
cargo run -q -p gossip-ffi --bin uniffi-bindgen -- generate \
  --library target/debug/libgossip_ffi.dylib --language swift --out-dir "$gen"
out=target/gen/swift-smoke
rm -f "$out"   # never run a stale binary if the build below fails
swiftc -o "$out" \
  -Xcc -fmodule-map-file="$gen/gossip_ffiFFI.modulemap" -I "$gen" \
  -L target/debug -lgossip_ffi -Xlinker -rpath -Xlinker "$here/target/debug" \
  "$gen/gossip_ffi.swift" ffi/tests/swift/main.swift
"$out"
