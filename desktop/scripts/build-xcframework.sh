#!/bin/sh
# Builds the macOS Swift package for the core: an XCFramework of the static library plus the generated Swift
# bindings, assembled into a self-contained SwiftPM package at desktop/target/swift-package (product and module
# "GossipCoreKit"). The Mac app depends on it as a local package (mac/project.yml).
#
#   scripts/build-xcframework.sh              universal (arm64 + x86_64): what releases use
#   scripts/build-xcframework.sh --host-only  just this machine's architecture: quick local and CI builds
#
#   rustup target add aarch64-apple-darwin x86_64-apple-darwin   (once; universal only)
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

host_only=0
[ "${1:-}" = "--host-only" ] && host_only=1

out=target/swift-package
rm -rf "$out" target/xcframework-build
mkdir -p "$out/Sources/GossipCoreKit" target/xcframework-build/headers

# Bindings come from a library build of the host architecture (the generator reads the embedded metadata).
cargo build -p gossip-ffi --release
cargo run -q -p gossip-ffi --bin uniffi-bindgen -- generate \
  --library target/release/libgossip_ffi.dylib --language swift --out-dir target/xcframework-build/gen

cp target/xcframework-build/gen/gossip_ffi.swift "$out/Sources/GossipCoreKit/gossip_ffi.swift"
cp target/xcframework-build/gen/gossip_ffiFFI.h target/xcframework-build/headers/
cp target/xcframework-build/gen/gossip_ffiFFI.modulemap target/xcframework-build/headers/module.modulemap

if [ "$host_only" = 1 ]; then
  cp target/release/libgossip_ffi.a target/xcframework-build/libgossip_ffi.a
else
  for t in aarch64-apple-darwin x86_64-apple-darwin; do
    cargo build -p gossip-ffi --release --target "$t"
  done
  lipo -create -output target/xcframework-build/libgossip_ffi.a \
    target/aarch64-apple-darwin/release/libgossip_ffi.a target/x86_64-apple-darwin/release/libgossip_ffi.a
fi

xcodebuild -create-xcframework \
  -library target/xcframework-build/libgossip_ffi.a -headers target/xcframework-build/headers \
  -output "$out/gossip_ffiFFI.xcframework"

cat > "$out/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GossipCoreKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GossipCoreKit", targets: ["GossipCoreKit"])],
    targets: [
        // The Rust core as a static library (module name matches the generated bindings' `import gossip_ffiFFI`).
        .binaryTarget(name: "gossip_ffiFFI", path: "gossip_ffiFFI.xcframework"),
        .target(name: "GossipCoreKit", dependencies: ["gossip_ffiFFI"]),
    ]
)
SWIFT

echo "built $here/$out ($([ "$host_only" = 1 ] && echo host-only || echo universal))"
