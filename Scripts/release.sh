#!/bin/bash
# Builds, signs, and – for a real, non-dry run – notarises (if it can),
# staples (if it notarised) and publishes a Shelf anybody can download.
#
# Seven steps to a built, signed app, and every one of them says what it did:
#
#   1  the four checks    – a release is not a way round them
#   2  the signing identity – a Developer ID from the keychain, or ad-hoc with
#      "-unsigned" in the download's name if there is none (see below)
#   3  archive             – Release, Hardened Runtime iff a Developer ID was
#      found (docs/adr/0022-updates-separate-delivery-sparkle.md)
#   4  verify the signature – Hardened Runtime as expected, entitlements as built
#   5  zip                 – ditto, the format notarisation wants
#   6  notarise             – notarytool submit --wait, only with a Developer ID
#   7  staple and assess    – stapler, then spctl, which is what the Mac in
#      front of somebody else will run – only reached after a real notarisation
#
# Then, for a real (non-dry) run only: a dmg beside the zip – the zip is
# what the appcast names and Sparkle fetches, the dmg is a first download by
# hand – and publishing (ADR 0022): sign both, cut a GitHub release in the
# separate Erikemmer/shelf-releases repository with both as assets, and push
# the appcast Sparkle's own updater reads – generate_appcast, sign_update,
# and generate_keys (used directly, once, outside this script) always take
# `--account shelf`, never the default: this Mac's keychain already holds
# another app's own Sparkle key under that default account, and calling any
# of these three without `--account shelf` would silently touch that other
# key pair instead of Shelf's own
# (docs/adr/0022-updates-separate-delivery-sparkle.md).
#
# **The appcast is never regenerated from the whole archive history**
# (Sprint 15, Teil B – found by a local dry run before it shipped, not
# assumed): generate_appcast applies its --download-url-prefix to every
# archive it is shown, so pointing it at the accumulated folder on a second
# release silently rewrote the first release's own, already-published entry
# to a URL under the second release's tag. Every run instead hands
# generate_appcast only the one archive it just built, and
# Scripts/appcast-merge.py splices that single new item into the existing
# feed, moving every other item's markup untouched rather than letting it be
# regenerated. --maximum-deltas 0: a delta file would need its own uploaded
# asset, which nothing here does.
#
# **A missing Developer ID does not stop a real run.** Until Erik enrols in
# the Apple Developer Program, every real release is ad-hoc-signed, skips
# notarisation and stapling (and says so), and its download's filename ends
# in "-unsigned" so nobody mistakes it for something Gatekeeper will simply
# accept — but it still gets built, signed, and published, exactly the way
# `v1.0.0` itself was handed out. **It never creates anything that costs
# money and never touches a certificate.** A Developer ID certificate and an
# App Store Connect key are Erik's to make; this script only ever *reads*
# them out of the keychain, and says exactly what is missing and where to
# make it when they are not there.
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
# Always ad-hoc, always skips notarisation, stapling and every publish step,
# whatever is or is not in the keychain — the local proof that the path up to
# notarisation still works, without touching shelf-releases, a GitHub token,
# or the Sparkle key. That is the run this repository can show on its own;
# a real run (signed or not) is the one that actually publishes.
#
# Output goes to ~/Library/Caches/Shelf/release/, never under ~/Documents.
# The shelf-releases checkout ($HOME/Library/Caches/Shelf/shelf-releases by
# default, Sprint 15, Teil B) is an ordinary git repository, not a build
# product — but it lives under Caches anyway now, not ~/Documents, which
# iCloud syncs: a git repository in a synced folder is the same class of
# problem CLAUDE.md already calls out for SQLite (docs/CONCEPT.md §12). If
# it is missing, this script clones it fresh with `gh repo clone` — the
# repository on GitHub is the truth, a clone only ever a copy of it.
#
# Usage: Scripts/release.sh            (a real release – builds AND publishes)
#        RELEASE_DRY_RUN=1 Scripts/release.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${RELEASE_OUT:-$HOME/Library/Caches/Shelf/release}"
PROFILE="${SHELF_NOTARY_PROFILE:-shelf-notarytool}"
RELEASES_REPO="${SHELF_RELEASES_REPO:-$HOME/Library/Caches/Shelf/shelf-releases}"
SPARKLE_ACCOUNT="${SHELF_SPARKLE_ACCOUNT:-shelf}"
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

say "version $VERSION"
say "output   $OUT"
[ "$DRY" = "1" ] && say "DRY RUN – ad-hoc signature, no notarisation, nothing published"

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

# ── 2. the signing identity ──────────────────────────────────────────────────
# Three outcomes, not two: a dry run is always ad-hoc and never publishes; a
# real run signs for real if it can, and otherwise falls back to ad-hoc *and
# still publishes* – the fallback v1.0.0 itself shipped under, now automated
# rather than done by hand once. Only the dry run is an escape hatch that
# proves nothing else touches the network.
IDENTITY=""
SUFFIX=""
HARDENED="NO"
NOTARISE=0
step "2/7  the signing identity"
if [ "$DRY" = "1" ]; then
    IDENTITY="-"
    say "ad hoc (-) – this build will run on this Mac and nowhere else"
else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
    if [ -n "$IDENTITY" ]; then
        HARDENED="YES"
        NOTARISE=1
        say "signing as: $IDENTITY"
    else
        IDENTITY="-"
        SUFFIX="-unsigned"
        say "no “Developer ID Application” certificate in the keychain – signing ad hoc."
        say "That certificate is what lets a Mac other than this one open Shelf without"
        say "being told it is damaged. Making one needs the Apple Developer Program,"
        say "which costs money, so this script will not make one:"
        say "  1  developer.apple.com ▸ Certificates ▸ + ▸ Developer ID Application"
        say "  2  download it and double-click it to put it in the login keychain"
        say "  3  check it is there:  security find-identity -v -p codesigning"
        say "Until then, every real release ships ad-hoc, unsigned, un-notarised –"
        say "exactly as v1.0.0 did – and this one continues rather than stopping here."
    fi
fi
ZIP="$OUT/$NAME$SUFFIX.zip"
DMG="$OUT/$NAME$SUFFIX.dmg"

# ── 3. archive ───────────────────────────────────────────────────────────────
step "3/7  archive"
mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$APP" "$OUT/$NAME.zip" "$OUT/$NAME-unsigned.zip"
( cd "$ROOT" && xcodegen generate >/dev/null ) || fail "xcodegen failed"

ARCHIVE_LOG="$OUT/archive.log"
if [ "$IDENTITY" = "-" ]; then
    # Ad-hoc, and therefore without the automatic provisioning that a
    # Developer ID build uses. Hardened Runtime stays off (HARDENED=NO
    # above): an ad-hoc signature has no real team for the app and the
    # embedded Sparkle.framework to share, and Hardened Runtime's library
    # validation would refuse to load the framework if it were on
    # (docs/adr/0022-updates-separate-delivery-sparkle.md).
    xcodebuild -project "$ROOT/Shelf.xcodeproj" -scheme Shelf -configuration Release \
        -archivePath "$ARCHIVE" \
        CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
        SHELF_HARDENED="$HARDENED" \
        archive >"$ARCHIVE_LOG" 2>&1 \
        || fail "archive failed – see $ARCHIVE_LOG"
else
    # A real Developer ID signs the app and Sparkle.framework under the same
    # team, so Hardened Runtime turns on here – notarisation refuses a build
    # without it.
    xcodebuild -project "$ROOT/Shelf.xcodeproj" -scheme Shelf -configuration Release \
        -archivePath "$ARCHIVE" \
        CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
        SHELF_HARDENED="$HARDENED" \
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
# `codesign -d` reading the very signature step 4 above just verified is not
# expected to fail — but an empty FLAGS from a broken pipe would otherwise
# fall through the ad-hoc branch's own `*)` case below as if it correctly
# read "no runtime flag", which is indistinguishable from a real read
# failure without this check (Sprint 15, Teil B: every pipe here closed
# with `|| fail`, or said why it does not need to be).
[ -n "$FLAGS" ] || fail "could not read the code directory flags back off $APP"
say "code directory flags: ${FLAGS:-unknown}"
if [ "$HARDENED" = "YES" ]; then
    case "$FLAGS" in
        *runtime*) say "hardened runtime: on" ;;
        *) fail "hardened runtime is NOT on (flags: ${FLAGS:-unknown}). Notarisation would refuse it." ;;
    esac
else
    # Expected off here: ad-hoc has no shared team with Sparkle.framework for
    # library validation to check, so this build never asks Hardened Runtime
    # to turn on in the first place.
    case "$FLAGS" in
        *runtime*) fail "hardened runtime is on in an ad-hoc build – SHELF_HARDENED did not take effect, or project.yml's default changed." ;;
        *) say "hardened runtime: off (ad-hoc, expected – docs/adr/0022-updates-separate-delivery-sparkle.md)" ;;
    esac
fi
codesign -d --entitlements - --xml "$APP" >"$OUT/entitlements.plist" 2>/dev/null \
    && say "entitlements written to $OUT/entitlements.plist"

# ── 5. zip ───────────────────────────────────────────────────────────────────
step "5/7  zip"
# `ditto`, not `zip`: the archive has to keep the bundle's symlinks and
# resource forks, and notarisation refuses one that does not.
ditto -c -k --keepParent "$APP" "$ZIP" || fail "could not make $ZIP"
say "$(basename "$ZIP") ($(($(stat -f %z "$ZIP") / 1024)) KB)"

# ── 6/7. notarise, staple and assess ─────────────────────────────────────────
if [ "$DRY" = "1" ]; then
    step "6/7  notarise – SKIPPED (dry run)"
    say "a real run would now send $(basename "$ZIP") to Apple with:"
    say "    xcrun notarytool submit \"$ZIP\" --keychain-profile $PROFILE --wait"
    step "7/7  staple – SKIPPED (dry run)"
    say "and then:  xcrun stapler staple \"$APP\"  and  spctl -a -vvv -t install \"$APP\""
    echo
    say "dry run complete. Everything up to notarisation is proved. Nothing published."
    say "app: $APP"
    say "zip: $ZIP"
    exit 0
fi

if [ "$NOTARISE" = "1" ]; then
    step "6/7  notarise"
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "no notarytool keychain profile called “$PROFILE”.

       The profile holds an Apple ID and an app-specific password, in the
       keychain, so that no password is ever on a command line or in a file.
       Make it once:

         xcrun notarytool store-credentials $PROFILE \\
             --apple-id <your apple id> --team-id <your team id> \\
             --password <an app-specific password from appleid.apple.com>

       Then run this again."

    # No `|| fail` on this pipe itself: `notarytool submit --wait`'s own exit
    # code is not the right thing to gate on anyway, since it can return 0
    # for a *rejected* submission too — the content check right below, on
    # what the log actually says, is the real verdict and already fails the
    # build if it is not "Accepted" (Sprint 15, Teil B: every pipe here
    # closed with `|| fail`, or said why it does not need to be).
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$OUT/notarytool.log" \
        | sed 's/^/    /'
    grep -c "status: Accepted" "$OUT/notarytool.log" >/dev/null 2>&1 \
        && [ "$(grep -c 'status: Accepted' "$OUT/notarytool.log")" -gt 0 ] \
        || fail "notarisation was not accepted – see $OUT/notarytool.log.
       The submission id in that log reads its own report back with:
         xcrun notarytool log <id> --keychain-profile $PROFILE"
    say "accepted"

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
else
    step "6/7  notarise – SKIPPED (no Developer ID)"
    say "an ad-hoc, unsigned build cannot be notarised – nothing was sent to Apple."
    step "7/7  staple and assess – SKIPPED (nothing to staple)"
    say "spctl on this build, for the record (expected: rejected):"
    # No `|| fail` here on purpose: unlike the notarised branch's own spctl
    # check above, `rejected` is the *correct* answer for an ad-hoc build —
    # gating on it would fail every ad-hoc release (Sprint 15, Teil B).
    spctl -a -vvv -t install "$APP" 2>&1 | sed 's/^/    /'
    echo
    say "done. $NAME is signed ad hoc and unsigned – notarisation and stapling skipped."
fi
say "app: $APP"
say "zip: $ZIP  ← this is the download Sparkle's own updater fetches"

# ── dmg: the first, by-hand download ─────────────────────────────────────────
# Not for Sparkle — the appcast only ever names the zip (below). This is the
# second GitHub release asset, for someone who has no Shelf yet and is
# choosing between the two, the way a Mac app is usually offered.
step "dmg: the first, by-hand download"
rm -f "$DMG"
hdiutil create -volname "Shelf" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null \
    || fail "could not create $DMG"
say "dmg: $DMG ($(($(stat -f %z "$DMG") / 1024)) KB)"

# ── publish: get Sparkle's own CLI tools ─────────────────────────────────────
# From the SPM artifact Xcode already resolved for the app target itself
# (docs/adr/0022-updates-separate-delivery-sparkle.md) – no brew, no separate
# download of a second tarball. A fixed, cache-local resolution directory
# rather than DerivedData's own (which is keyed by a hash that is not stable
# across a `make clean` or a different Mac) so this step finds the same tools
# every time it runs.
step "publish: Sparkle's own CLI tools"
SPARKLE_SPM_DIR="$OUT/SourcePackages"
xcodebuild -resolvePackageDependencies -project "$ROOT/Shelf.xcodeproj" -scheme Shelf \
    -clonedSourcePackagesDirPath "$SPARKLE_SPM_DIR" >/dev/null 2>&1 \
    || fail "could not resolve Sparkle's own SPM package to find sign_update/generate_appcast"
SIGN_UPDATE=$(find "$SPARKLE_SPM_DIR/artifacts" -type f -name sign_update -perm -u+x 2>/dev/null | head -1)
GENERATE_APPCAST=$(find "$SPARKLE_SPM_DIR/artifacts" -type f -name generate_appcast -perm -u+x 2>/dev/null | head -1)
[ -x "$SIGN_UPDATE" ] || fail "sign_update not found under $SPARKLE_SPM_DIR/artifacts"
[ -x "$GENERATE_APPCAST" ] || fail "generate_appcast not found under $SPARKLE_SPM_DIR/artifacts"
say "sign_update:      $SIGN_UPDATE"
say "generate_appcast: $GENERATE_APPCAST"

# ── publish: sign the update ─────────────────────────────────────────────────
step "publish: sign the update"
# --account $SPARKLE_ACCOUNT always: this Mac's keychain holds another app's
# own Sparkle key under the *default* account, and omitting --account here
# would silently sign with (or read) that key instead of Shelf's own
# (docs/adr/0022-updates-separate-delivery-sparkle.md).
#
# This call is informational, and closed with `|| fail` anyway (Sprint 15,
# Teil B): `sign_update` on an update *archive* only ever prints the
# signature and length for a person to read or paste by hand — it does not
# modify $ZIP. The signature that actually ends up in the appcast is
# generate_appcast's own, computed independently, below, also with
# --account shelf. Printed here so the run shows the signature before the
# appcast step does, and so a keychain or key problem is caught this early
# rather than only once generate_appcast reaches the same key.
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$ZIP" | sed 's/^/    /' \
    || fail "sign_update failed – the Sparkle key in the keychain (account $SPARKLE_ACCOUNT) may be missing or inaccessible"
# The dmg the same way, for the same record — never read by Sparkle or by
# generate_appcast, which only ever sees $ZIP.
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG" | sed 's/^/    /' \
    || fail "sign_update failed on the dmg – the Sparkle key in the keychain (account $SPARKLE_ACCOUNT) may be missing or inaccessible"

# ── publish: the releases repository ─────────────────────────────────────────
step "publish: Erikemmer/shelf-releases"
if [ ! -d "$RELEASES_REPO/.git" ]; then
    say "cloning $RELEASES_REPO"
    gh repo clone Erikemmer/shelf-releases "$RELEASES_REPO" || fail "could not clone shelf-releases"
fi
git -C "$RELEASES_REPO" pull --ff-only --quiet || fail "could not fast-forward $RELEASES_REPO"

# An rc version goes to the beta feed with --prerelease, so a stable install
# is never offered a release candidate by accident; a stable version goes to
# appcast.xml, which rc versions never touch.
case "$VERSION" in
    *-rc*)
        APPCAST_FILE="appcast-beta.xml"
        GH_PRERELEASE_FLAG=(--prerelease)
        CHANNEL="beta"
        ;;
    *)
        APPCAST_FILE="appcast.xml"
        GH_PRERELEASE_FLAG=()
        CHANNEL="stable"
        ;;
esac
say "channel: $CHANNEL ($APPCAST_FILE)"

say "release notes from CHANGELOG.md"
NOTES_HTML="$OUT/$NAME$SUFFIX.html"
python3 "$HERE/changelog-notes.py" "$VERSION" "$ROOT/CHANGELOG.md" >"$NOTES_HTML" \
    || fail "changelog-notes.py could not find this release's own section – see its own message above"

# The channel's own archive directory keeps every release's zip and notes,
# across runs (~/Library/Caches/Shelf/, unlike $OUT which this script
# clears every time) — a record, not generate_appcast's own input any more.
#
# **Why generate_appcast is never pointed at that whole directory (Sprint
# 15, Teil B, found by a local dry run before this fix, not assumed):**
# `--download-url-prefix` is applied to *every* archive generate_appcast
# finds, old and new alike (its own source, Appcast.swift: `for update in
# allUpdates { update.downloadUrlPrefix = downloadURLPrefix }`) — so a
# second release pointed at the accumulated folder silently rewrote the
# *first* release's own, already-published entry to a URL under the
# *second* release's tag, where that older zip was never uploaded. Every
# release only ever hands generate_appcast the one archive it just built,
# in a directory of its own — the URL it computes is then correct for that
# archive alone — and Scripts/appcast-merge.py splices that single new
# `<item>` into the existing feed by hand, moving every other item rather
# than asking generate_appcast to regenerate it. `--maximum-deltas 0`: a
# delta file would need to be uploaded as its own GitHub release asset,
# which nothing here does, so the appcast must never offer one.
ARCHIVE_DIR="$HOME/Library/Caches/Shelf/appcast-archives/$CHANNEL"
mkdir -p "$ARCHIVE_DIR"
cp "$ZIP" "$ARCHIVE_DIR/"
cp "$NOTES_HTML" "$ARCHIVE_DIR/$(basename "$ZIP" .zip).html"

NEW_ITEM_DIR="$OUT/appcast-new-item"
rm -rf "$NEW_ITEM_DIR"
mkdir -p "$NEW_ITEM_DIR"
cp "$ZIP" "$NEW_ITEM_DIR/"
cp "$NOTES_HTML" "$NEW_ITEM_DIR/$(basename "$ZIP" .zip).html"

say "generating this release's own appcast entry"
"$GENERATE_APPCAST" --account "$SPARKLE_ACCOUNT" \
    --maximum-deltas 0 \
    --download-url-prefix "https://github.com/Erikemmer/shelf-releases/releases/download/v$VERSION/" \
    -o "$NEW_ITEM_DIR/appcast.xml" \
    "$NEW_ITEM_DIR" | sed 's/^/    /' \
    || fail "generate_appcast failed"

say "merging it into the existing $APPCAST_FILE"
python3 "$HERE/appcast-merge.py" \
    "$RELEASES_REPO/$APPCAST_FILE" "$NEW_ITEM_DIR/appcast.xml" "$ARCHIVE_DIR/appcast.xml" \
    || fail "appcast-merge.py failed"
cp "$ARCHIVE_DIR/appcast.xml" "$RELEASES_REPO/$APPCAST_FILE"

say "creating the GitHub release in Erikemmer/shelf-releases"
# Two assets: the zip, which the appcast names and Sparkle fetches; the dmg
# beside it, for someone choosing their first download by hand rather than
# through the updater. The appcast never names the dmg.
gh release create "v$VERSION" \
    --repo Erikemmer/shelf-releases \
    --title "Shelf $VERSION" \
    --notes-file "$NOTES_HTML" \
    "${GH_PRERELEASE_FLAG[@]}" \
    "$ZIP" "$DMG" \
    || fail "gh release create failed"

say "pushing the updated $APPCAST_FILE"
git -C "$RELEASES_REPO" add "$APPCAST_FILE"
git -C "$RELEASES_REPO" commit -m "chore: appcast entry for v$VERSION" --quiet
git -C "$RELEASES_REPO" push --quiet || fail "could not push $APPCAST_FILE to shelf-releases"

# ── publish: mark the boundary in this repo's own CHANGELOG.md ──────────────
# Not committed here: this script changes build output and a second repo, but
# leaves the source repo's own working tree for the calling session to
# review and commit like any other change (CLAUDE.md: "git status --short
# before git add").
step "publish: CHANGELOG.md boundary marker"
MARKER_DATE=$(date "+%-d %B %Y")
python3 - "$ROOT/CHANGELOG.md" "$VERSION" "$MARKER_DATE" <<'PYEOF'
import re
import sys

path, version, date = sys.argv[1:4]
with open(path, encoding="utf-8") as f:
    text = f.read()

# The new marker goes at the TOP of the content just published – not next to
# the marker it was extracted down to. That old marker (v1.0.0's, the first
# time this runs) stays exactly where it is, bounding the release *below*
# this one; this new marker is what stops the *next* release's own extraction
# from reaching back into what v{version} already published.
first_heading = re.search(r"^##\s", text, re.MULTILINE)
if not first_heading:
    sys.exit("no '## ' heading found – nothing to put the new marker above")

marker = f"<!-- shelf-release: v{version} · {date} -->"
start = first_heading.start()
new_text = text[:start] + marker + "\n\n" + text[start:]
with open(path, "w", encoding="utf-8") as f:
    f.write(new_text)
print(f"inserted: {marker}")
PYEOF
say "review and commit CHANGELOG.md before the next release – its own new marker is what bounds that one's notes"

echo
say "published. https://github.com/Erikemmer/shelf-releases/releases/tag/v$VERSION"
say "feed: $APPCAST_FILE"
