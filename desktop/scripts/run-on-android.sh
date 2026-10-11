#!/bin/sh
# Cross-compiles the core's test suite for ARM64 Android, pushes it to /data/local/tmp on a connected device over
# adb, runs it there and cleans up. Nothing is installed.
#
# With the NDK and cargo-ndk (see build-android.sh) the tests are built against Android's own libc (bionic), the
# same environment the app runs in. Without them it falls back to a static ARM64 Linux binary, which still proves
# the code runs on the device's CPU and kernel:
#   rustup target add aarch64-linux-android   (bionic)   or   aarch64-unknown-linux-musl   (fallback)
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/.." && pwd)"
dir=/data/local/tmp/gossip-core-test

cd "$here"
mkdir -p target
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ANDROID_NDK_HOME="$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
fi
if command -v cargo-ndk >/dev/null 2>&1 && [ -n "${ANDROID_NDK_HOME:-}" ]; then
  export ANDROID_NDK_HOME
  echo "building against bionic with $ANDROID_NDK_HOME"
  build() {
    # cargo-ndk hides cargo's JSON output, so take its toolchain environment and run plain cargo.
    eval "$(cargo ndk-env -t arm64-v8a --platform 29)"
    cargo test -p gossip-core --target aarch64-linux-android --no-run --message-format=json 2>/dev/null
  }
else
  echo "no NDK/cargo-ndk: building a static musl binary instead"
  build() { RUSTFLAGS="-C linker=rust-lld -C linker-flavor=ld.lld" cargo test -p gossip-core --target aarch64-unknown-linux-musl --no-run --message-format=json 2>/dev/null; }
fi

build | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("reason") == "compiler-artifact" and m.get("profile", {}).get("test") and m.get("executable"):
        print(m["target"]["name"], m["executable"])
' > "$here/target/android-tests.txt"

adb shell "rm -rf $dir; mkdir -p $dir/schema"
adb push -q "$repo"/schema/*.json "$dir/schema/"
status=0
while read -r name exe; do
  case "$name" in interop_swift) continue ;; esac   # needs the Swift harness; macOS only
  adb push -q "$exe" "$dir/$name"
  adb shell -n "chmod +x $dir/$name"
  echo "== $name"
  adb shell -n "cd $dir && GOSSIP_SCHEMA_DIR=$dir/schema ./$name 2>&1" | tail -4 || status=1
done < "$here/target/android-tests.txt"
adb shell "rm -rf $dir"
exit $status
