#!/bin/bash
# Submits signed build products to Apple's notary service and staples the ticket
# so the app launches on a machine that has never seen it.
#   ./scripts/notarize.sh <path>...        # each path: .app, .dmg or .zip
#
# Credentials, using the same variable names StoryMoss passes to tauri-action:
#   APPLE_ID + APPLE_PASSWORD (app-specific password) + APPLE_TEAM_ID
# or a profile stored once with:
#   xcrun notarytool store-credentials <profile> --apple-id ... --team-id ...
#   NOTARY_PROFILE=<profile>
#
# Without credentials the run is skipped — that keeps `./build.sh` usable on a
# dev machine. NOTARIZE=required turns the skip into a failure, which is what
# the release pipeline uses so an unnotarized DMG can never be published.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REQUIRE="${NOTARIZE:-}"

# --- credentials ------------------------------------------------------------
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi

if [ "${#NOTARY_ARGS[@]}" -eq 0 ]; then
    if [ "$REQUIRE" = "required" ]; then
        echo "✗ notarization required but no credentials found." >&2
        echo "  Set APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID, or NOTARY_PROFILE." >&2
        exit 1
    fi
    echo "→ notarization skipped (no credentials; set APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID or NOTARY_PROFILE)"
    exit 0
fi

[ "$#" -gt 0 ] || { echo "usage: $(basename "$0") <path>..." >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A .app cannot be submitted directly — Apple's service takes a container, so it
# gets zipped with ditto (which keeps the bundle's symlinks and permissions).
# The ticket is stapled onto the .app itself, not the throwaway zip.
submit_and_staple() {
    # Declared one per line: `local a="$1" b="$a"` expands $a before the
    # assignment, which trips `set -u`.
    local target="$1"
    local upload="$target"
    local staple="$target"
    local zip=""

    if [ -d "$target" ]; then
        case "$target" in
            *.app) : ;;
            *) echo "✗ refusing to notarize unexpected directory: $target" >&2; return 1 ;;
        esac
        zip="$TMP/$(basename "$target").zip"
        echo "→ zipping $(basename "$target") for submission"
        ditto -c -k --keepParent "$target" "$zip"
        upload="$zip"
        staple="$target"
    elif [ -f "$target" ]; then
        : # .dmg / .pkg / .zip — submitted as-is
    else
        echo "✗ no such path: $target" >&2
        return 1
    fi

    echo "→ submitting $(basename "$upload") to the notary service (this can take a few minutes)"
    if ! xcrun notarytool submit "$upload" "${NOTARY_ARGS[@]}" --wait --timeout 30m; then
        echo "✗ notarization failed for $target" >&2
        # The credentials are deliberately not echoed back: they would land in
        # the CI log in plain text.
        echo "  Inspect the log with:" >&2
        echo "    xcrun notarytool log <id>   # same credentials as above" >&2
        return 1
    fi

    echo "→ stapling $(basename "$staple")"
    xcrun stapler staple "$staple"
    xcrun stapler validate "$staple"
}

for path in "$@"; do
    submit_and_staple "$path"
done

echo "✓ notarized and stapled: $*"
