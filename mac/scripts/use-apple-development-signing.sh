#!/bin/bash
# Signs local Mac builds with an "Apple Development" certificate from a (free) Apple ID instead of the self-signed
# gossip.vmd1.dev one, so the app has a team ID.
#
# Why: the login Keychain decides who may read an item from, among other things, a "partition list". For an app without
# a team ID that list names the code hash of one build, so every rebuilt or updated Gossip is asked for the login
# password again (once per Keychain item). With a team ID the list names `teamid:XXXXXXXXXX`, which is the same for every
# build signed by that team, so the prompt stops after you click Always Allow once.
#
# One-time setup this script cannot do for you: Xcode > Settings > Accounts > add your Apple ID (a free account is
# enough), then select the "Personal Team" and click Manage Certificates > + > Apple Development.
#
#   mac/scripts/use-apple-development-signing.sh [--undo]
#
# It writes mac/Config/Signing.local.xcconfig (git-ignored), keeping the previous file as Signing.local.xcconfig.bak,
# and prints what it found. --undo restores the backup. Switching identity changes the app's signature once, so macOS
# asks for the Keychain password a final time and the Accessibility and Input Monitoring grants have to be given again.
# Do not use this for CI or releases: those need the same identity on every machine (see docs/building-and-signing.md).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL="$HERE/../Config/Signing.local.xcconfig"

if [ "${1:-}" = "--undo" ]; then
  if [ -f "$LOCAL.bak" ]; then mv "$LOCAL.bak" "$LOCAL"; echo "restored $LOCAL"; else rm -f "$LOCAL"; echo "removed $LOCAL"; fi
  exit 0
fi

IDENT_LINE="$(security find-identity -v -p codesigning | grep '"Apple Development:' | head -1 || true)"
if [ -z "$IDENT_LINE" ]; then
  echo "No 'Apple Development' signing certificate found in your keychain." >&2
  echo "In Xcode: Settings > Accounts > add your Apple ID, then Manage Certificates > + > Apple Development." >&2
  echo "Then run this script again." >&2
  exit 1
fi
HASH="$(awk '{print $2}' <<<"$IDENT_LINE")"
NAME="$(sed -E 's/.*"(Apple Development:[^"]*)".*/\1/' <<<"$IDENT_LINE")"
# The team ID is the certificate subject's organizational unit (OU).
TEAM="$(security find-certificate -c "$NAME" -p | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
  | awk -F'= *' '/organizationalUnitName/{print $2; exit}')"
if [ -z "$TEAM" ]; then
  echo "Found '$NAME' but could not read its team ID." >&2
  exit 1
fi

[ -f "$LOCAL" ] && [ ! -f "$LOCAL.bak" ] && cp "$LOCAL" "$LOCAL.bak"
cat > "$LOCAL" <<XC
// Written by scripts/use-apple-development-signing.sh. Git-ignored. Undo with that script's --undo.
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = $HASH
DEVELOPMENT_TEAM = $TEAM
// Debug builds: Hardened Runtime off so the unit-test host can load its test bundle (as with the self-signed identity).
ENABLE_HARDENED_RUNTIME[config=Debug] = NO
XC
echo "Signing with: $NAME"
echo "Team ID:      $TEAM"
echo "Wrote $LOCAL"
echo "Next: xcodegen generate, build, replace the app, and answer the Keychain prompts with Always Allow once."
