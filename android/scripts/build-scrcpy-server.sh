#!/bin/bash
# Builds the bundled scrcpy server jar from source (Genymobile/scrcpy, Apache 2.0) instead of bundling a
# prebuilt binary downloaded from GitHub Releases, so nothing in the APK's assets is a blob that wasn't
# compiled from source during this build (F-Droid requires this; see docs/building-and-signing.md).
#
# Pinned by commit, not just tag: a tag can be retargeted, a commit can't, so this fails loudly instead of
# silently building different source than the one THIRD_PARTY_NOTICE.txt and this script were reviewed against.
#
# Needs: git, the Android SDK with platform 36 and build-tools 36.0.0 (ANDROID_HOME), javac.
# Output is cached at app/build/scrcpy/scrcpy-server-v<version>.jar; set GOSSIP_REBUILD_SCRCPY=1 to force a rebuild.
set -euo pipefail

SCRCPY_VERSION="4.1"
SCRCPY_TAG="v$SCRCPY_VERSION"
SCRCPY_COMMIT="2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0"
SCRCPY_REPO="https://github.com/Genymobile/scrcpy.git"

HERE="$(cd "$(dirname "$0")/.." && pwd)" # android/
OUT_DIR="$HERE/app/build/scrcpy"
SRC_DIR="$OUT_DIR/src"
JAR_NAME="scrcpy-server-v$SCRCPY_VERSION.jar"
OUT_JAR="$OUT_DIR/$JAR_NAME"

if [ -f "$OUT_JAR" ] && [ -z "${GOSSIP_REBUILD_SCRCPY:-}" ]; then
  echo "$OUT_JAR already built; skipping (set GOSSIP_REBUILD_SCRCPY=1 to force)."
  exit 0
fi

: "${ANDROID_HOME:?ANDROID_HOME must point at the Android SDK (needs platform 36, build-tools 36.0.0)}"

rm -rf "$SRC_DIR"
mkdir -p "$OUT_DIR"
git clone --quiet --depth 1 --branch "$SCRCPY_TAG" "$SCRCPY_REPO" "$SRC_DIR"
ACTUAL_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$SCRCPY_COMMIT" ]; then
  echo "scrcpy $SCRCPY_TAG resolved to $ACTUAL_COMMIT, expected $SCRCPY_COMMIT (tag retargeted, or this pin needs updating for a deliberate version bump)." >&2
  exit 1
fi

# Match whatever build-tools/platform are actually installed (CI runners and dev machines vary) rather than
# hardcoding a version, the same way release.yml locates apksigner/aapt2.
BUILD_TOOLS_VERSION="$(basename "$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)")"
PLATFORM_VERSION="$(basename "$(ls -d "$ANDROID_HOME"/platforms/android-*/ | sort -V | tail -1 | sed 's:/$::')" | sed 's/^android-//')"

CLASSES_OUT="$OUT_DIR/build"
rm -rf "$CLASSES_OUT"
mkdir -p "$CLASSES_OUT"
(
  cd "$SRC_DIR/server"
  ANDROID_PLATFORM="$PLATFORM_VERSION" ANDROID_BUILD_TOOLS="$BUILD_TOOLS_VERSION" BUILD_DIR="$CLASSES_OUT" bash build_without_gradle.sh
)
mv "$CLASSES_OUT/scrcpy-server" "$OUT_JAR"
rm -rf "$CLASSES_OUT" "$SRC_DIR"
echo "Built $OUT_JAR ($(shasum -a 256 "$OUT_JAR" | cut -d' ' -f1))"
