#!/bin/sh
# Builds the Android artifacts for the core: libgossip_ffi.so for every ABI plus the generated Kotlin bindings.
#
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
#   cargo install cargo-ndk
#   sdkmanager "ndk;27.3.13750724"        (any NDK r26+ works; ANDROID_NDK_HOME overrides the lookup below)
#
#   scripts/build-android.sh                          all four ABIs (releases, CI)
#   scripts/build-android.sh --abis arm64-v8a         just the listed ABIs, comma separated (quick local builds)
#   (or set GOSSIP_CORE_ABIS)
#
# Output (desktop/target/android):
#   jniLibs/<abi>/libgossip_ffi.so   copy into the app's src/main/jniLibs
#   kotlin/uniffi/gossip_ffi/gossip_ffi.kt   copy into the app's sources (package uniffi.gossip_ffi)
# The generated Kotlin talks to the library through JNA; the app needs `net.java.dev.jna:jna:5.17.0@aar`.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
  ANDROID_NDK_HOME="$(ls -d "$sdk"/ndk/* 2>/dev/null | sort -V | tail -1)"
  [ -n "$ANDROID_NDK_HOME" ] || { echo "no NDK found: set ANDROID_NDK_HOME" >&2; exit 1; }
  export ANDROID_NDK_HOME
fi

abis="${GOSSIP_CORE_ABIS:-arm64-v8a,armeabi-v7a,x86_64,x86}"
if [ "${1:-}" = "--abis" ]; then abis="${2:?--abis needs a comma separated list}"; fi

target_for() {
  case "$1" in
    arm64-v8a) echo aarch64-linux-android ;;
    armeabi-v7a) echo armv7-linux-androideabi ;;
    x86_64) echo x86_64-linux-android ;;
    x86) echo i686-linux-android ;;
    *) echo "unknown ABI $1" >&2; exit 1 ;;
  esac
}

out=target/android
rm -rf "$out"
flags=""
first_target=""
for abi in $(echo "$abis" | tr ',' ' '); do
  t="$(target_for "$abi")"
  [ -n "$first_target" ] || first_target="$t"
  flags="$flags -t $abi"
done
# minSdk 29 matches android/app/build.gradle.kts.
# shellcheck disable=SC2086
cargo ndk --platform 29 $flags -o "$out/jniLibs" build -p gossip-ffi --release

# The bindings are the same for every ABI; read the metadata from the first one built.
cargo run -q -p gossip-ffi --bin uniffi-bindgen -- generate \
  --library "target/$first_target/release/libgossip_ffi.so" --language kotlin --no-format --out-dir "$out/kotlin"

echo "built $here/$out"
find "$out" -type f | sort
