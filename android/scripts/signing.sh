#!/bin/bash
# One stable signing key for every Gossip APK (local and CI), so a build from any machine updates the app
# installed from any other in place. Android refuses an update signed with a different key (you would have to
# uninstall first, losing the app's data and pairings).
#
#   signing.sh generate  Create a fresh, dedicated keystore at ~/.gossip-signing/gossip-android.keystore
#                        (+ .properties) with a random password, independent of ~/.android/debug.keystore.
#                        This is the project key: keep it the same across releases and local builds keep
#                        updating in place. Gradle picks the key up automatically.
#   signing.sh adopt     Legacy path: copies an existing keystore (default ~/.android/debug.keystore) in as
#                        the project key instead of generating a dedicated one. Prefer `generate` for a new
#                        project key — reusing the OS debug keystore means a well-known password sitting in
#                        a file most machines already have, which is unnecessary exposure for a key that
#                        apps trust for silent in-place updates.
#   signing.sh upload    Store the key in the GitHub `release` environment (restricted to main) so the release
#                        workflow signs with it. Needs `gh` with admin rights on the repo.
#
# Gradle (app/build.gradle.kts) reads GOSSIP_ANDROID_KEYSTORE / _KEYSTORE_PASSWORD / _KEY_ALIAS / _KEY_PASSWORD
# (CI) or the files above (local); without them builds use the default debug keystore as before.
#
# BACK UP ~/.gossip-signing/: GitHub secrets cannot be read back. NEVER commit these files: whoever holds the
# key can sign an update that installs over the app on your devices.
set -euo pipefail

STORE="${GOSSIP_SIGNING_DIR:-$HOME/.gossip-signing}"
KEYSTORE="$STORE/gossip-android.keystore"
PROPS="$STORE/gossip-android.properties"
ENVIRONMENT="release"

fingerprint() { keytool -list -v -keystore "$1" -storepass "$2" 2>/dev/null | sed -n 's/.*SHA256: //p' | head -1; }

case "${1:-}" in
  generate)
    if [ -f "$KEYSTORE" ]; then echo "$KEYSTORE already exists; not overwriting."; exit 0; fi
    mkdir -p "$STORE"; chmod 700 "$STORE"
    umask 077
    ALIAS="gossip-release"
    PW="$(openssl rand -base64 24)"
    keytool -genkeypair -v -keystore "$KEYSTORE" -alias "$ALIAS" -keyalg RSA -keysize 2048 -validity 10950 \
      -storepass "$PW" -keypass "$PW" -dname "CN=Gossip, OU=Gossip, O=vmd1, L=Unknown, ST=Unknown, C=US" >/dev/null
    printf 'storePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' "$PW" "$ALIAS" "$PW" > "$PROPS"
    chmod 600 "$KEYSTORE" "$PROPS"
    echo "Generated a dedicated project key: $KEYSTORE"
    echo "SHA-256: $(fingerprint "$KEYSTORE" "$PW")"
    echo "Back up $STORE now (password manager, etc.) — GitHub secrets cannot be read back."
    ;;
  adopt)
    SRC="${2:-$HOME/.android/debug.keystore}"
    [ -f "$SRC" ] || { echo "No keystore at $SRC" >&2; exit 1; }
    if [ -f "$KEYSTORE" ]; then echo "$KEYSTORE already exists; not overwriting."; exit 0; fi
    mkdir -p "$STORE"; chmod 700 "$STORE"
    umask 077
    cp "$SRC" "$KEYSTORE"
    # The default debug keystore uses these well-known values.
    printf 'storePassword=android\nkeyAlias=androiddebugkey\nkeyPassword=android\n' > "$PROPS"
    chmod 600 "$KEYSTORE" "$PROPS"
    echo "Adopted $SRC as the project key: $KEYSTORE"
    echo "SHA-256: $(fingerprint "$KEYSTORE" android)"
    ;;
  upload)
    [ -f "$KEYSTORE" ] && [ -f "$PROPS" ] || { echo "Run '$0 adopt' first." >&2; exit 1; }
    prop() { sed -n "s/^$1=//p" "$PROPS"; }
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
    # The environment (restricted to main) is created by mac/scripts/set-ci-signing-secrets.sh; make sure it is.
    gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" -q '.branch_policies[].name' | grep -qx main \
      || { echo "Environment '$ENVIRONMENT' is not restricted to main; run mac/scripts/set-ci-signing-secrets.sh first." >&2; exit 1; }
    base64 < "$KEYSTORE" | tr -d '\n' | gh secret set ANDROID_KEYSTORE_BASE64 --env "$ENVIRONMENT" --repo "$REPO"
    prop storePassword | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD --env "$ENVIRONMENT" --repo "$REPO"
    prop keyAlias | tr -d '\n' | gh secret set ANDROID_KEY_ALIAS --env "$ENVIRONMENT" --repo "$REPO"
    prop keyPassword | tr -d '\n' | gh secret set ANDROID_KEY_PASSWORD --env "$ENVIRONMENT" --repo "$REPO"
    echo "Secrets in '$ENVIRONMENT': $(gh secret list --env "$ENVIRONMENT" --repo "$REPO" | awk '{print $1}' | tr '\n' ' ')"
    echo "Key SHA-256 (put this in release.yml's EXPECTED_ANDROID_CERT_SHA256, lowercase, no colons): $(fingerprint "$KEYSTORE" "$(prop storePassword)")"
    ;;
  *) echo "usage: $0 generate | adopt [keystore] | upload" >&2; exit 2 ;;
esac
