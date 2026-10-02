#!/bin/bash
# Local-development and CI code signing for Gossip, with ONE stable self-signed identity.
#
# macOS ties the Accessibility / Input Monitoring grants to the app's code signature, so a stable signature
# means the grants survive rebuilds and updates. The same certificate must sign every build (local and CI),
# so it is created once as a .p12 file, imported here, and uploaded to GitHub with set-ci-signing-secrets.sh.
#
#   create-signing-cert.sh [name] [--generate-only]
#
# * If ~/.gossip-signing/<name>.p12 (+ .password) is missing, a new certificate is generated there (mode 700).
# * Unless --generate-only, the .p12 is imported into your login keychain (unless it is already there).
# * Then Config/Signing.local.xcconfig (git-ignored) is written so Debug and Release builds use the identity.
#
# BACK UP ~/.gossip-signing/: GitHub secrets cannot be read back, and losing the key means a new identity
# (every user re-grants Accessibility / Input Monitoring once). NEVER commit these files: whoever holds the
# key can sign an app that inherits those grants.
#
# The certificate is self-signed, so Gatekeeper does not trust builds on other users' Macs; it exists for
# stable grants, not notarization. It is deliberately not marked trusted in your keychain.
set -euo pipefail

NAME="gossip.vmd1.dev"
GENERATE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --generate-only) GENERATE_ONLY=1 ;;
    *) NAME="$arg" ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
STORE="${GOSSIP_SIGNING_DIR:-$HOME/.gossip-signing}"
P12="$STORE/$NAME.p12"
PASSFILE="$STORE/$NAME.password"

generate() {
  mkdir -p "$STORE"; chmod 700 "$STORE"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/openssl.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  local pass; pass="$(openssl rand -base64 32 | tr -d '\n')"
  umask 077
  printf '%s' "$pass" > "$PASSFILE"
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
    -out "$P12" -passout "pass:$pass" -legacy 2>/dev/null \
    || openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
         -out "$P12" -passout "pass:$pass"
  chmod 600 "$P12" "$PASSFILE"
  echo "Generated $P12 (password in $PASSFILE). Back both up somewhere safe; never commit them."
}

if [ ! -f "$P12" ] || [ ! -f "$PASSFILE" ]; then
  generate
fi

[ "$GENERATE_ONLY" = 1 ] && exit 0

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" is already in your keychain."
else
  security import "$P12" -k "$KEYCHAIN" -P "$(cat "$PASSFILE")" -T /usr/bin/codesign
  # Let codesign use the key without a prompt on every build.
  echo "Allowing codesign to use the key (macOS may ask for your login password)..."
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
    || security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN"
fi

cat > "$HERE/../Config/Signing.local.xcconfig" <<XC
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = $NAME
DEVELOPMENT_TEAM =
XC
echo "Wrote Config/Signing.local.xcconfig. Run 'xcodegen generate' in mac/ and rebuild."
