#!/bin/sh
# Loads the Android build of libgossip_ffi.so on a connected device and calls into it (see ffi/tests/android).
# Run scripts/build-android.sh first.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}"
ndk="${ANDROID_NDK_HOME:-$(ls -d "$sdk"/ndk/* | sort -V | tail -1)}"
case "$(uname -s)" in Darwin) host=darwin-x86_64 ;; *) host=linux-x86_64 ;; esac
cc="$ndk/toolchains/llvm/prebuilt/$host/bin/aarch64-linux-android29-clang"
dir=/data/local/tmp/gossip-ffi-test
mkdir -p "$here/target/android"
"$cc" -o "$here/target/android/load_test" "$here/ffi/tests/android/load_test.c" -ldl
adb shell "rm -rf $dir; mkdir -p $dir"
adb push -q "$here/target/android/load_test" "$here/target/android/jniLibs/arm64-v8a/libgossip_ffi.so" "$dir/"
adb shell -n "chmod +x $dir/load_test"
status=0
adb shell -n "cd $dir && ./load_test $dir/libgossip_ffi.so" || status=1
adb shell "rm -rf $dir"
exit $status
