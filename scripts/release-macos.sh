#!/bin/bash
# End-to-end macOS release build: import the signing certificate, build the app,
# package the DMG, then notarize and staple both so Gatekeeper accepts them on a
# machine that downloaded them.
#   ./scripts/release-macos.sh [version]
#
# Certificate, using the same variable names StoryMoss passes to tauri-action:
#   APPLE_CERTIFICATE           base64 of the Developer ID Application .p12
#   APPLE_CERTIFICATE_PASSWORD  password for that .p12
#   APPLE_SIGNING_IDENTITY      "Developer ID Application: Name (TEAMID)"
# Notarization credentials are read by notarize.sh (APPLE_ID / APPLE_PASSWORD /
# APPLE_TEAM_ID, or NOTARY_PROFILE).
#
# With no APPLE_CERTIFICATE the Developer ID already in the login keychain is
# used — that is what a maintainer's own machine has, and it still notarizes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${MARKETING_VERSION:-1.3.1}}"

KEYCHAIN=""
cleanup() {
    [ -n "$KEYCHAIN" ] && security delete-keychain "$KEYCHAIN" 2>/dev/null || true
}
trap cleanup EXIT

# --- certificate ------------------------------------------------------------
if [ -n "${APPLE_CERTIFICATE:-}" ]; then
    : "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE is set but APPLE_CERTIFICATE_PASSWORD is not}"
    KEYCHAIN="$(mktemp -d)/build.keychain"
    P12="$(mktemp -d)/certificate.p12"

    echo "→ importing the signing certificate"
    printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$P12" 2>/dev/null || {
        echo "✗ APPLE_CERTIFICATE is not valid base64 — re-create the secret" >&2
        exit 1
    }
    security create-keychain -p "" "$KEYCHAIN"
    # Without an unlocked keychain and a partition list, codesign blocks on a GUI
    # prompt that CI can never answer.
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "" "$KEYCHAIN"
    security import "$P12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign || {
        echo "✗ could not import APPLE_CERTIFICATE." >&2
        echo "  Either APPLE_CERTIFICATE_PASSWORD is wrong, or the .p12 is in a" >&2
        echo "  format security(1) cannot read — a .p12 written by OpenSSL 3 needs" >&2
        echo "  'openssl pkcs12 -export -legacy' to import here." >&2
        exit 1
    }
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null
    rm -rf "$(dirname "$P12")"
fi

# Resolve the identity: an explicit name wins, otherwise take the only Developer
# ID identity in the imported keychain.
IDENTITY="${APPLE_SIGNING_IDENTITY:-${CODESIGN_IDENTITY:-}}"
if [ -z "$IDENTITY" ] && [ -n "$KEYCHAIN" ]; then
    IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
                | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning \
                | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' | head -1)"
fi

case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    "")
        echo "✗ no Developer ID Application identity found." >&2
        echo "  A release must be notarizable, so an ad-hoc signature will not do." >&2
        echo "  Import a Developer ID certificate, or set APPLE_SIGNING_IDENTITY." >&2
        exit 1 ;;
    *)
        echo "✗ '$IDENTITY' is not a Developer ID Application identity." >&2
        echo "  Notarization requires a Developer ID certificate; ad-hoc or" >&2
        echo "  Apple Development certificates are rejected by the notary service." >&2
        exit 1 ;;
esac

if [ -n "$KEYCHAIN" ]; then
    # Keep the login keychain in the search list so the notary tool can still
    # find its own credentials while ours is active.
    security list-keychains -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
fi

echo "→ signing as: $IDENTITY"
export CODESIGN_IDENTITY="$IDENTITY"

# --- build ------------------------------------------------------------------
MARKETING_VERSION="$VERSION" "$ROOT/build.sh" release

APP="$ROOT/build/NoneNote-${VERSION}.app"
[ -d "$APP" ] || { echo "✗ expected $APP" >&2; exit 1; }

"$ROOT/scripts/make-dmg.sh" "$VERSION"
DMG="$ROOT/build/NoneNote-${VERSION}.dmg"
[ -f "$DMG" ] || { echo "✗ expected $DMG" >&2; exit 1; }

# Breaking the signature is the one way the DMG can still be rejected after this
# script reports success, so it is checked rather than assumed.
codesign --verify --deep --strict "$APP"
echo "✓ signature valid"

# --- notarize ---------------------------------------------------------------
# The app is notarized first so that dragging it out of the DMG leaves a copy
# that still validates offline; the DMG is stapled so the download itself passes.
NOTARIZE=required "$ROOT/scripts/notarize.sh" "$APP" "$DMG"

echo "✓ release ready: $DMG"
echo "  Gatekeeper check: spctl -a -vvv -t exec '$APP'"
