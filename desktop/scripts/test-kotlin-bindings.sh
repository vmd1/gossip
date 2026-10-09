#!/bin/sh
# Builds the FFI library, generates the Kotlin bindings and runs the Kotlin smoke test on the JVM through JNA.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
cargo build -p gossip-ffi
case "$(uname -s)" in Darwin) lib=libgossip_ffi.dylib ;; *) lib=libgossip_ffi.so ;; esac
gen=target/gen/kotlin
rm -rf "$gen" && mkdir -p "$gen"
cargo run -q -p gossip-ffi --bin uniffi-bindgen -- generate \
  --library "target/debug/$lib" --language kotlin --no-format --out-dir "$gen"
cd ffi/kotlin
gradle --no-daemon -q test -PnativeLibDir="$here/target/debug"
