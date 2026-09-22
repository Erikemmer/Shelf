#!/bin/bash
# Drives the real window through "Write into the Book File" and photographs
# its cover row — Sprint 11, Schritt 3: the cover became a line in the same
# confirmation sheet Sprint 10 built (docs/adr/0021-metadata-and-a-cover-may-
# be-written-into-an-epub.md), never a second command or a second sheet.
#
# Four pictures: a cover Shelf would replace (beside a field that also
# changes, in the one sheet), a book with no cover in its own file at all
# that Shelf has one to offer for, a cover that is already the same, and the
# state afterward. Every claim is checked against the library on disk, not
# against the screenshot.
#
# Runs against the library `shelf-tool epub-cover-write-fixture` builds —
# three ordinary synthetic books and three real, decodable JPEGs made from
# Shelf's own app icon with `sips` (never a borrowed image, CLAUDE.md) — so
# the cover row's own description ("JPEG, 300 × 450") is real, not a made-up
# string nothing ever decoded.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
#
# It runs in **either language**. `SHELF_SHOT_LANGUAGE=de` pins German and
# uses the German names; anything else is English.
#
# Usage: Scripts/write-into-book-cover-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LANGUAGE="${SHELF_SHOT_LANGUAGE:-en}"
CACHE="$HOME/Library/Caches/Shelf/write-into-book-cover-11"
LIB="${1:-$CACHE/library}"
DEFAULT_OUT="$ROOT/docs/screenshots/sprint-11"
[ "$LANGUAGE" = "en" ] || DEFAULT_OUT="$DEFAULT_OUT/de"
OUT="${2:-$DEFAULT_OUT}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/debug/shelf-tool"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "write-into-book-cover-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "write-into-book-cover-shot: $1"; }

name_of() {
    if [ "$LANGUAGE" = "de" ]; then
        case "$1" in
            menuItem) echo "Ins Buch schreiben…" ;;
            writeButton) echo "Ins Buch schreiben" ;;
            checkbox) echo "Ich habe die Liste oben gelesen" ;;
            cancel) echo "Abbrechen" ;;
            close) echo "Schließen" ;;
            clearSearch) echo "Suche leeren" ;;
            searchField) echo "Suchen" ;;
            alreadySame) echo "schon gleich" ;;
            noCoverInBook) echo "Kein Cover im Buch" ;;
            nothingToWrite) echo "Nichts zu schreiben" ;;
            writtenInto) echo "beschrieben" ;;
            *) fail "no German name for '$1'" ;;
        esac
    else
        case "$1" in
            menuItem) echo "Write into the Book File…" ;;
            writeButton) echo "Write into the Book File" ;;
            checkbox) echo "I have read the list above" ;;
            cancel) echo "Cancel" ;;
            close) echo "Close" ;;
            clearSearch) echo "Clear the search" ;;
            searchField) echo "Search" ;;
            alreadySame) echo "already the same" ;;
            noCoverInBook) echo "No cover in the book" ;;
            nothingToWrite) echo "Nothing to write" ;;
            writtenInto) echo "written into" ;;
            *) fail "no English name for '$1'" ;;
        esac
    fi
}

. "$HERE/app-language.sh"
pin_app_language "$LANGUAGE"
. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

case "$LIB" in
    "$HOME/Library/Caches/Shelf/"*) ;;
    *) fail "this script writes into books, so it only runs against a throw-away library
       under ~/Library/Caches/Shelf. Build one: shelf-tool epub-cover-write-fixture" ;;
esac

[ -x "$TOOL" ] || swift build --scratch-path "$SCRATCH" >/dev/null || fail "could not build shelf-tool"

# Three real, decodable JPEGs — Shelf's own app icon at three different
# sizes, via sips, never a borrowed image. Regenerated every run so the
# fixture's covers and this script's expected sizes can never drift apart.
COVERS="$CACHE/covers"
mkdir -p "$COVERS"
ICON_DIR="$ROOT/App/Shelf/Resources/Assets.xcassets/AppIcon.appiconset"
sips -s format jpeg -z 450 300 "$ICON_DIR/icon_256x256.png" --out "$COVERS/old.jpg" >/dev/null \
    || fail "could not make old.jpg with sips"
sips -s format jpeg -z 600 400 "$ICON_DIR/icon_512x512.png" --out "$COVERS/new.jpg" >/dev/null \
    || fail "could not make new.jpg with sips"
sips -s format jpeg -z 525 350 "$ICON_DIR/icon_256x256@2x.png" --out "$COVERS/added.jpg" >/dev/null \
    || fail "could not make added.jpg with sips"

# Rebuilt every run, for the same reason write-into-book-shot.sh rebuilds
# its own fixture: "The Glass Almanac" actually gets its file replaced by
# scene 4, so a second run against a stale library would start from a book
# already changed.
rm -rf "$LIB"
FIXTURE_OUT=$("$TOOL" epub-cover-write-fixture "$LIB" "$COVERS/old.jpg" "$COVERS/new.jpg" "$COVERS/added.jpg" 2>&1) \
    || fail "epub-cover-write-fixture failed:
$FIXTURE_OUT"
say "fixture built"
echo "$FIXTURE_OUT" | sed 's/^/  /'

mkdir -p "$OUT"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    while IFS= read -r candidate; do
        candidate="${candidate#* }"
        [ -x "$candidate/Contents/MacOS/Shelf" ] || continue
        APP="$candidate"
        break
    done < <(find ~/Library/Developer/Xcode/DerivedData -name "Shelf.app" -path "*/Build/Products/*" \
        -not -path "*Index.noindex*" -maxdepth 6 -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn)
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1

require_no_foreign_shelf

open -a "$APP" "$LIB" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

cleanup() {
    [ -n "${PID:-}" ] || return
    osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
    sleep 2
    kill -0 "$PID" 2>/dev/null && kill "$PID" 2>/dev/null
}
trap 'cleanup; restore_app_language' EXIT

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null; }
tree_has() {
    local n
    n=$(tree | grep -c "$1")
    [ "${n:-0}" -gt 0 ]
}
shoot() {
    front
    sleep 1.5
    local wid
    wid=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
    [ -n "$wid" ] || fail "no window to photograph"
    screencapture -o -x -l "$wid" "/tmp/write-into-book-cover-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/write-into-book-cover-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/write-into-book-cover-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null) || return 1
    [ -n "$point" ] || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
place_window() {
    front
    sleep 0.8
    osascript >/dev/null 2>&1 <<POSITION
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
POSITION
    sleep 1
}
select_book() {
    click "desc=$(name_of clearSearch)" >/dev/null 2>&1
    sleep 1
    click "desc=$(name_of searchField)" || fail "no search field"
    sleep 0.5
    osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1
    sleep 2
    click "cell" || fail "the search for “$1” found no book"
    sleep 2
}
# The same reason write-into-book-shot.sh has this: "Write into the Book
# File…" is the inspector's last button, below the first screenful for any
# book with a description, and a SwiftUI ScrollView needs a real scroll
# event, not AXScrollToVisible.
scroll_inspector_down() {
    swift "$HERE/scroll-at.swift" 1300 500 -25 6 >/dev/null 2>&1
    sleep 0.5
}
open_write_sheet() {
    scroll_inspector_down
    click "desc=$(name_of menuItem)" || fail "no “$(name_of menuItem)” button under the selection"
    sleep 1
    local waited=0
    until tree_has "AXSheet"; do
        waited=$((waited + 1))
        # A click that lands before the inspector has finished scrolling to
        # this book's own button is a click at empty space, not a failure
        # worth ending the run over — one retry at the same description,
        # halfway through the wait, before giving up for real.
        if [ "$waited" -eq 15 ]; then
            click "desc=$(name_of menuItem)" >/dev/null 2>&1
        fi
        [ "$waited" -lt 30 ] || fail "the sheet never appeared"
        sleep 1
    done
    # The sheet appears in its own "planning" state first — a ProgressView
    # while `EPUBWrite.plan` reads the file and rebuilds its archive off the
    # main actor — and a fixed sleep here raced that on a real cover's own
    # tens of KB (this fixture's covers are real, decodable JPEGs, not a
    # few-hundred-byte synthetic one). Wait for the planning caption to be
    # gone rather than guess how long planning takes.
    waited=0
    while tree_has "Working out what would change"; do
        waited=$((waited + 1))
        [ "$waited" -lt 30 ] || fail "the sheet never left its planning state"
        sleep 1
    done
    sleep 2
}
close_sheet() {
    click "desc=$(name_of cancel)" >/dev/null 2>&1 || click "desc=$(name_of close)" >/dev/null 2>&1
    sleep 1
}

place_window

# ── 1. A cover Shelf would replace, beside a field that also changes ────────
select_book "The Glass Almanac"
open_write_sheet
tree_has "Erik & Erik Press" || fail "the sheet does not show the changed publisher"
tree_has "$(name_of noCoverInBook)" && fail "“The Glass Almanac” has a cover in its own file already"
shoot 1-cover-changed
close_sheet

# ── 2. No cover in the book at all, Shelf has one to offer ──────────────────
select_book "Cinders and Salt"
open_write_sheet
tree_has "$(name_of noCoverInBook)" || fail "the sheet does not say “$(name_of noCoverInBook)”"
shoot 2-no-cover-in-book
close_sheet

# ── 3. A cover that is already the same ──────────────────────────────────────
# "The Quiet Harbour" was never edited and its cover.<ext> is exactly what
# import extracted from its own file — nothing about it would change, so
# the sheet reads "Nothing to write" and the cover row itself is tagged
# "already the same", the same state a text field gets when it already
# matches (Sprint 10, Schritt E2).
select_book "The Quiet Harbour"
open_write_sheet
tree_has "$(name_of nothingToWrite)" || fail "the sheet does not say “$(name_of nothingToWrite)” for an unchanged book"
tree_has "$(name_of alreadySame)" || fail "the cover row is not tagged “$(name_of alreadySame)”"
shoot 3-cover-already-same
close_sheet

# ── 4. After: the book's own file now carries the new cover ─────────────────
select_book "The Glass Almanac"
open_write_sheet
tick_checkbox() {
    osascript <<EOF 2>/dev/null
tell application "System Events" to tell (first application process whose unix id is $PID)
    set allEls to entire contents of sheet 1 of window 1
    repeat with el in allEls
        try
            if class of el is checkbox then
                click el
                return 1
            end if
        end try
    end repeat
    return 0
end tell
EOF
}
TICKED=$(tick_checkbox)
if [ "${TICKED:-0}" -le 0 ]; then
    # The sheet's own list can still be laying out its last row (the cover
    # one, added last in `bookSection`) the instant the checkbox is first
    # asked for — one more try after a short wait, before giving up.
    sleep 1.5
    TICKED=$(tick_checkbox)
fi
[ "${TICKED:-0}" -gt 0 ] || fail "could not tick “$(name_of checkbox)”"
sleep 0.5
click "desc=$(name_of writeButton)" 1 || fail "no “$(name_of writeButton)” button"
WAITED=0
until tree_has "$(name_of writtenInto)"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 30 ] || fail "the sheet never reported it was finished"
    sleep 1
done
sleep 1
FOLDER=$(dirname "$(grep -rl "<dc:title>The Glass Almanac<" "$LIB" --include=metadata.opf 2>/dev/null | head -1)")
[ -d "$FOLDER" ] || fail "no folder for “The Glass Almanac” after the write"
NEW_EPUB=$(find "$FOLDER" -maxdepth 1 -name '*.epub' | head -1)
[ -n "$NEW_EPUB" ] || fail "no epub left in “The Glass Almanac”'s folder after the write"
# The book's own file now carries `new.jpg`'s exact bytes, not merely "some
# image" — compared with cmp, not trusted from the screenshot.
COVER_ENTRY=$(unzip -Z1 "$NEW_EPUB" | grep -i '\.jpg$' | head -1)
[ -n "$COVER_ENTRY" ] || fail "no .jpg entry in the book's own file after the write"
unzip -p "$NEW_EPUB" "$COVER_ENTRY" > /tmp/write-into-book-cover-after.jpg
cmp -s /tmp/write-into-book-cover-after.jpg "$COVERS/new.jpg" \
    || fail "the book's own cover is not new.jpg's exact bytes after the write"
rm -f /tmp/write-into-book-cover-after.jpg
say "checked: $NEW_EPUB now carries new.jpg's exact bytes, on disk"
shoot 4-after
close_sheet

say "done – $OUT"
