#!/bin/bash
# Builds the Release app that `make app` hands to `make smoke`, and refuses to
# call it built if its signature is one that cannot start.
#
# ## Why this is a script and no longer three lines in the Makefile
#
# `make app` used to ask one question — "is there a Developer ID in the
# keychain?" — and turn Hardened Runtime on if the answer was yes. It never
# told `xcodebuild` to *sign* with that identity, so the build stayed ad hoc.
# While no such certificate existed the two halves could not disagree. One
# arrived on 19 October 2026, and from then on every `make app` on this Mac
# produced an ad-hoc build with Hardened Runtime on: library validation finds
# no team shared by the app and the embedded Sparkle.framework and dyld ends
# the process before `main` ("mapping process and mapped file (non-platform)
# have different Team IDs"). Found on 11 November 2026 from eight crash
# reports in two minutes.
#
# So the identity that decides Hardened Runtime is now the identity the build
# is signed with, exactly as `Scripts/release.sh` already does it, and the
# result is read back rather than trusted.
#
# ## Use
#
#     Scripts/build-app.sh               # Developer ID if there is one, else ad hoc
#     SHELF_ADHOC=1 Scripts/build-app.sh # ad hoc whatever the keychain holds
#
# `SHELF_ADHOC=1` is for a session that must not touch the keychain's private
# key — signing with it can raise a prompt only a person can answer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "app: FAILED – $*" >&2
    exit 1
}

developer_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1
}

signature_flags() {
    codesign -d --verbose=2 "$1" 2>&1 | sed -n 's/^CodeDirectory.*flags=[^(]*(\([^)]*\)).*/\1/p'
}

team_of() {
    codesign -d --verbose=2 "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}

IDENTITY=""
if [ "${SHELF_ADHOC:-0}" != "1" ]; then
    IDENTITY="$(developer_id)"
fi

COMMIT="$(git rev-parse HEAD)"
if [ -n "$IDENTITY" ]; then
    # The name of the identity is a person's name; it stays out of the log.
    echo "app: signing with the Developer ID in the keychain — Hardened Runtime on"
    xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Release \
        CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
        SHELF_HARDENED=YES SHELF_BUILD_COMMIT="$COMMIT" build
else
    echo "app: ad-hoc build, Hardened Runtime off (see docs/adr/0022-updates-separate-delivery-sparkle.md)"
    xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Release \
        SHELF_HARDENED=NO SHELF_BUILD_COMMIT="$COMMIT" build
fi

# Read the signature back. A comment saying the two halves agree is what this
# target had before; it was true for exactly as long as nobody owned a
# certificate.
PRODUCTS="$(xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Release \
    -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)"
APP="$PRODUCTS/Shelf.app"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
[ -d "$APP" ] || fail "no Shelf.app at $APP"
[ -d "$SPARKLE" ] || fail "no Sparkle.framework inside $APP"

FLAGS="$(signature_flags "$APP")"
case "$FLAGS" in
    *adhoc*runtime* | *runtime*adhoc*)
        fail "the app is signed ad hoc with Hardened Runtime on ($FLAGS). It cannot load Sparkle.framework and will not start."
        ;;
esac
case "$FLAGS" in
    *runtime*)
        [ "$(team_of "$APP")" = "$(team_of "$SPARKLE")" ] \
            || fail "Hardened Runtime is on, and the app and Sparkle.framework are signed by different teams. It will not start."
        ;;
esac
echo "app: signature checked – ${FLAGS:-no flags}, app and Sparkle.framework can load together"
