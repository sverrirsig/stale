#!/usr/bin/env bash
# Build Stale for distribution: Release build → Developer ID signature → notarized → DMG.
#   scripts/release.sh 1.0.0
#
# Signing and notarization run only when these are set (they are, in GitHub Actions):
#   APPLE_TEAM_ID                 e.g. ABCDE12345
#   APPLE_ID                      Apple ID email used for notarization
#   APPLE_APP_SPECIFIC_PASSWORD   from appleid.apple.com → App-Specific Passwords
# Without them the script produces an unsigned DMG for local testing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
DIST="dist"
BUILD="build"
APP="$BUILD/Build/Products/Release/Stale.app"
DMG="$DIST/Stale-$VERSION.dmg"
SIGNED=false
[[ -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] && SIGNED=true

rm -rf "$DIST" "$BUILD"
mkdir -p "$DIST"

echo "▸ Building Stale $VERSION (signed: $SIGNED)"
if $SIGNED; then
  xcodebuild -project Stale.xcodeproj -scheme Stale -configuration Release \
    -derivedDataPath "$BUILD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build | grep -E "error|warning: .*\.swift|BUILD" || true
else
  xcodebuild -project Stale.xcodeproj -scheme Stale -configuration Release \
    -derivedDataPath "$BUILD" \
    build | grep -E "error|warning: .*\.swift|BUILD" || true
fi
[[ -d "$APP" ]] || { echo "Build failed: $APP not found"; exit 1; }

notarize() {
  echo "▸ Notarizing $(basename "$1")"
  local out status id
  out="$(xcrun notarytool submit "$1" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait 2>&1)" && status=0 || status=$?
  echo "$out"
  # A submission can come back Invalid with exit 0, so check the reported status too.
  if [[ $status -ne 0 ]] || ! grep -q "status: Accepted" <<<"$out"; then
    id="$(sed -n 's/^ *id: *//p' <<<"$out" | head -1)"
    if [[ -n "$id" ]]; then
      echo "▸ Notarization not accepted; fetching Apple's log for $id"
      local log="$(mktemp -t notarylog)"
      if xcrun notarytool log "$id" \
        --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        "$log"; then cat "$log"; else echo "(could not fetch log)"; fi
      rm -f "$log"
    fi
    exit 1
  fi
}

if $SIGNED; then
  codesign --verify --deep --strict --verbose=1 "$APP"
  ditto -c -k --keepParent "$APP" "$DIST/Stale.zip"
  notarize "$DIST/Stale.zip"
  xcrun stapler staple "$APP"
  rm "$DIST/Stale.zip"
fi

scripts/make-dmg.sh "$APP" "$DMG"

if $SIGNED; then
  codesign --sign "Developer ID Application" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "▸ Gatekeeper assessment"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

echo "▸ Done: $DMG"
