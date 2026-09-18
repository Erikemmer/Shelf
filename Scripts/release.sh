#!/bin/bash
# Builds, signs, notarises and staples a Shelf anybody can download.
#
# Seven steps, and every one of them says what it did:
#
#   1  the four checks            – a release is not a way round them
#   2  archive                    – Release, hardened runtime
#   3  export and sign            – Developer ID, an identity from the keychain
#   4  verify the signature       – hardened runtime on, entitlements as built
#   5  zip                        – ditto, the format notarisation wants
#   6  notarise                   – notarytool submit --wait
#   7  staple and assess          – stapler, then spctl, which is what the Mac
#                                   in front of somebody else will run
#
# **It never creates anything that costs money and never touches a
# certificate.** A Developer ID certificate and an App Store Connect key are
# Erik's to make; this script only ever *reads* them out of the keychain, and
# says exactly what is missing and where to make it when they are not there.
#
# No password is ever passed on a command line or written to a file.
# `notarytool` reads a **keychain profile**, created once by hand:
#
#     xcrun notarytool store-credentials shelf-notarytool \
#         --apple-id <apple id> --team-id <team id> --password <app-specific password>
#
# ## The dry run
#
#     RELEASE_DRY_RUN=1 Scripts/release.sh
#
# signs **ad hoc** (`-`), skips steps 6 and 7, and does everything else for
# real. It proves the path as far as notarisation without an identity, without
# an Apple ID and without sending anything anywhere. That is the run this
# repository can show; the rest needs Erik.
#
# Output goes to ~/Library/Caches/Shelf/release/, never under ~/Documents.
#
# Usage: Scripts/release.sh            (a real release)
#        RELEASE_DRY_RUN=1 Scripts/release.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${RELEASE_OUT:-$HOME/Library/Caches/Shelf/release}"
PROFILE="${SHELF_NOTARY_PROFILE:-shelf-notarytool}"
DRY="${RELEASE_DRY_RUN:-0}"
SKIP_CHECKS="${RELEASE_SKIP_CHECKS:-0}"

say() { printf 'release: %s\n' "$1"; }
step() { printf '\nrelease: ── %s ──\n' "$1"; }
fail() {
    printf 'release: FAILED – %s\n' "$1" >&2
    exit 1
}

VERSION=$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/project.yml")
[ -n "$VERSION" ] || fail "no MARKETING_VERSION in project.yml"
NAME="Shelf-$VERSION"
ARCHIVE="$OUT/$NAME.xcarchive"
APP="$OUT/Shelf.app"
ZIP="$OUT/$NAME.zip"

say "version $VERSION"
say "output   $OUT"
[ "$DRY" = "1" ] && say "DRY RUN – ad-hoc signature, no notarisation, nothing leaves this Mac"

# ── 0. the tools ─────────────────────────────────────────────────────────────
xcode-select -p >/dev/null 2>&1 || fail "Xcode not found. Install it, open it once, then run this again."
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen missing. brew install xcodegen"
xcrun --find notarytool >/dev/null 2>&1 || fail "notarytool missing – it ships with Xcode 13 and later."

# ── 1. the four checks ───────────────────────────────────────────────────────
# A release that skipped them would be the one build nobody checked.
if [ "$SKIP_CHECKS" = "1" ]; then
    say "step 1 skipped by RELEASE_SKIP_CHECKS=1 – say so in the release notes"
else
    step "1/7  make test && make lint"
    make -C "$ROOT" test >/dev/null || fail "make test is red. A release does not go round it."
    make -C "$ROOT" lint >/dev/null || fail "make lint is red."
    say "tests and lint green"
fi

# ── 2. the identity ──────────────────────────────────────────────────────────
step "2/7  the signing identity"
IDENTITY=""
if [ "$DRY" = "1" ]; then
    IDENTITY="-"
    say "ad hoc (-) – this build will run on this Mac and nowhere else"
else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
    if [ -z "$IDENTITY" ]; then
        fail "no “Developer ID Application” certificate in the keychain.

       That certificate is what lets a Mac other than this one open Shelf
       without being told it is damaged. Making one needs the Apple Developer
       Program, which costs money, so this script will not make one:

         1  developer.apple.com ▸ Certificates ▸ + ▸ Developer ID Application
         2  download it and double-click it to put it in the login keychain
         3  check it is there:  security find-identity -v -p codesigning

       Until then:  RELEASE_DRY_RUN=1 Scripts/release.sh
       proves every step up to notarisation."
    fi
    say "signing as: $IDENTITY"
fi

# ── 3. archive ───────────────────────────────────────────────────────────────
step "3/7  archive"
mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$APP" "$ZIP"
( cd "$ROOT" && xcodegen generate >/dev/null ) || fail "xcodegen failed"

ARCHIVE_LOG="$OUT/archive.log"
if [ "$DRY" = "1" ]; then
    # Ad-hoc, and therefore without the automatic provisioning that a Developer
    # ID build uses: the point of the dry run is the *path*, not the identity.
    xcodebuild -project "$ROOT/Shelf.xcodeproj" -scheme Shelf -configuration Release \
        -archivePath "$ARCHIVE" \
        CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
        archive >"$ARCHIVE_LOG" 2>&1 \
        || fail "archive failed – see $ARCHIVE_LOG"
else
    xcodebuild -project "$ROOT/Shelf.xcodeproj" -scheme Shelf -configuration Release \
        -archivePath "$ARCHIVE" \
        CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
        archive >"$ARCHIVE_LOG" 2>&1 \
        || fail "archive failed – see $ARCHIVE_LOG"
fi
say "archived: $ARCHIVE"

ARCHIVED_APP="$ARCHIVE/Products/Applications/Shelf.app"
[ -d "$ARCHIVED_APP" ] || fail "the archive holds no Shelf.app – see $ARCHIVE_LOG"
cp -R "$ARCHIVED_APP" "$APP" || fail "could not copy the app out of the archive"

# ── 4. verify the signature ──────────────────────────────────────────────────
step "4/7  the signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /' \
    || fail "the signature does not verify"
FLAGS=$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^CodeDirectory.*flags=\([^ ]*\).*/\1/p')
say "code directory flags: ${FLAGS:-unknown}"
case "$FLAGS" in
    *runtime*) say "hardened runtime: on" ;;
    *) fail "hardened runtime is NOT on (flags: ${FLAGS:-unknown}). Notarisation would refuse it." ;;
esac
codesign -d --entitlements - --xml "$APP" >"$OUT/entitlements.plist" 2>/dev/null \
    && say "entitlements written to $OUT/entitlements.plist"

# ── 5. zip ───────────────────────────────────────────────────────────────────
step "5/7  zip"
# `ditto`, not `zip`: the archive has to keep the bundle's symlinks and
# resource forks, and notarisation refuses one that does not.
ditto -c -k --keepParent "$APP" "$ZIP" || fail "could not make $ZIP"
say "$(basename "$ZIP") ($(($(stat -f %z "$ZIP") / 1024)) KB)"

# ── 6. notarise ──────────────────────────────────────────────────────────────
if [ "$DRY" = "1" ]; then
    step "6/7  notarise – SKIPPED (dry run)"
    say "a real run would now send $(basename "$ZIP") to Apple with:"
    say "    xcrun notarytool submit \"$ZIP\" --keychain-profile $PROFILE --wait"
    step "7/7  staple – SKIPPED (dry run)"
    say "and then:  xcrun stapler staple \"$APP\"  and  spctl -a -vvv -t install \"$APP\""
    echo
    say "dry run complete. Everything up to notarisation is proved."
    say "app: $APP"
    say "zip: $ZIP"
    exit 0
fi

step "6/7  notarise"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "no notarytool keychain profile called “$PROFILE”.

       The profile holds an Apple ID and an app-specific password, in the
       keychain, so that no password is ever on a command line or in a file.
       Make it once:

         xcrun notarytool store-credentials $PROFILE \\
             --apple-id <your apple id> --team-id <your team id> \\
             --password <an app-specific password from appleid.apple.com>

       Then run this again."

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$OUT/notarytool.log" \
    | sed 's/^/    /'
grep -c "status: Accepted" "$OUT/notarytool.log" >/dev/null 2>&1 \
    && [ "$(grep -c 'status: Accepted' "$OUT/notarytool.log")" -gt 0 ] \
    || fail "notarisation was not accepted – see $OUT/notarytool.log.
       The submission id in that log reads its own report back with:
         xcrun notarytool log <id> --keychain-profile $PROFILE"
say "accepted"

# ── 7. staple and assess ─────────────────────────────────────────────────────
step "7/7  staple and assess"
# The ticket goes into the bundle, so a Mac with no network can still check it.
xcrun stapler staple "$APP" || fail "stapling failed"
xcrun stapler validate "$APP" || fail "the stapled ticket does not validate"
say "stapled"

# What the Mac in front of somebody else actually runs.
spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/    /' || fail "Gatekeeper refused the app"

# The zip made in step 5 has no ticket in it, so it is made again.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP" || fail "could not re-make $ZIP"
say "re-zipped with the ticket: $ZIP"

echo
say "done. $NAME is signed, notarised, stapled and assessed."
say "app: $APP"
say "zip: $ZIP  ← this is the download"
