#!/bin/bash
# Packages build/NoneNote-<version>.app into a drag-to-Applications disk image.
#   ./scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist" 2>/dev/null || true)"
VERSION="${1:-${MARKETING_VERSION:-${PLIST_VERSION:-1.0.0}}}"
APP="$ROOT/build/NoneNote-${VERSION}.app"
# Fall back to the convenience symlink from build.sh
[ -d "$APP" ] || APP="$ROOT/build/Noty.app"
DMG="$ROOT/build/NoneNote-${VERSION}.dmg"

[ -d "$APP" ] || { echo "no app at $APP — run ./build.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Stage as NoneNote.app so the DMG shows a clean drag target.
cp -R "$APP" "$STAGE/NoneNote.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "NoneNote ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    -imagekey zlib-level=9 \
    "$DMG" >/dev/null

SIZE=$(stat -f%z "$DMG")
echo "✓ $DMG ($((SIZE / 1024 / 1024)) MB)"

# Apple expects the disk image itself to be signed before it is notarized.
# Skipped for ad-hoc builds, where a signature would mean nothing anyway.
IDENTITY="${CODESIGN_IDENTITY:-${APPLE_SIGNING_IDENTITY:-}}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    echo "✓ signed the disk image as $IDENTITY"
fi
