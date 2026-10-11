#!/bin/sh
# Builds the Rust protocol engine as the Swift package the Mac app depends on (../desktop/target/swift-package).
# Run it once before `xcodegen generate` / `xcodebuild`, and again after changing anything under desktop/.
#
#   scripts/build-core.sh              this machine's architecture only (local builds, tests, CI)
#   scripts/build-core.sh --universal  arm64 + x86_64 (release builds)
#
# Needs a Rust toolchain: `brew install rustup && rustup default stable` (and, for --universal,
# `rustup target add aarch64-apple-darwin x86_64-apple-darwin`).
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--universal" ]; then
  exec "$here/../desktop/scripts/build-xcframework.sh"
fi
exec "$here/../desktop/scripts/build-xcframework.sh" --host-only
