#!/usr/bin/env bash
# Wrap an .app in a compressed DMG with an /Applications shortcut. No third-party tools.
#   scripts/make-dmg.sh path/to/Stale.app dist/Stale-1.0.0.dmg
set -euo pipefail

APP="$1"
OUT="$2"
VOLNAME="$(basename "$APP" .app)"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT"
echo "Created $OUT"
