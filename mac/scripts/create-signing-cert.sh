#!/bin/bash
# Creates a self-signed code-signing certificate ("Gossip Local Dev") in your login keychain and writes
# Config/Signing.local.xcconfig so Debug and Release builds are signed with it. A stable signature means
# macOS keeps the Accessibility / Input Monitoring grants across rebuilds.
#
# Local development only: the certificate is self-signed, so Gatekeeper will not trust builds for
# distribution. Re-running is safe (an existing certificate is reused).
set -euo pipefail

NAME="${1:-Gossip Local Dev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
  echo "Certificate \"$NAME\" already exists."
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/openssl.cnf" <<CNF
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
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  P12PASS="gossip-local"
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/cert.p12" -passout "pass:$P12PASS" -legacy 2>/dev/null \
    || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
         -out "$TMP/cert.p12" -passout "pass:$P12PASS"
  security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign
  # Let codesign use the key without a prompt on every build.
  echo "Allowing codesign to use the key (macOS may ask for your login password)..."
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
    || security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN"
  # Trust it for code signing so `security find-identity -v -p codesigning` lists it as valid.
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
fi

cat > "$HERE/../Config/Signing.local.xcconfig" <<XC
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = $NAME
DEVELOPMENT_TEAM =
XC
echo "Wrote Config/Signing.local.xcconfig. Run 'xcodegen generate' in mac/ and rebuild."
