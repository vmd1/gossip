#!/bin/sh
# Builds the FFI library, generates the C# binding (uniffi-bindgen-cs, which must match the UniFFI version in
# desktop/ffi/Cargo.toml) and runs the C# smoke test against the native library.
#
# One-time setup:
#   cargo install --locked uniffi-bindgen-cs --git https://github.com/NordSecurity/uniffi-bindgen-cs --tag v0.12.0+v0.32.0
#   (--locked matters: without it a newer toml crate breaks the build)
# and a .NET SDK (8 or newer). Pass `release` for an optimised build.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
profile="${1:-debug}"
if [ "$profile" = release ]; then cargo build -p gossip-ffi --release; else cargo build -p gossip-ffi; fi
case "$(uname -s)" in
  Darwin) lib=libgossip_ffi.dylib ;;
  MINGW*|MSYS*|CYGWIN*) lib=gossip_ffi.dll ;;
  *) lib=libgossip_ffi.so ;;
esac
gen=target/gen/csharp
rm -rf "$gen" && mkdir -p "$gen"
uniffi-bindgen-cs --library "target/$profile/$lib" --out-dir "$gen"
cd ffi/csharp
dotnet build -nologo -v q -c Debug
out="$(ls -d bin/Debug/net* | head -1)"
cp "$here/target/$profile/$lib" "$out/"
DYLD_LIBRARY_PATH="$out" LD_LIBRARY_PATH="$out" dotnet "$out/Gossip.Core.dll"
