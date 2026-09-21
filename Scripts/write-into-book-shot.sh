#!/bin/bash
# Drives the real window through "Write into the Book File" and photographs
# it — the command that, for the first time in this project, lets Shelf
# write into a book's own file (docs/adr/0021-metadata-and-a-cover-may-be-
# written-into-an-epub.md).
#
# Five pictures: the command itself, the confirmation with a field's old
# value beside the new one, a field the sheet marks as unwritable rather
# than dropping, the DRM refusal, and the state afterward. Every claim is
# checked against the library on disk, not against the screenshot.
#
# Runs against the library `shelf-tool epub-write-fixture` builds — three
# ordinary synthetic books, one with a `<dc:title>`-less EPUB, one
# announcing Adobe DRM — never a real one, and never a borrowed book
# (CLAUDE.md).
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
#
# It runs in **either language**. `SHELF_SHOT_LANGUAGE=de` pins German and
# uses the German names; anything else is English.
#
# Usage: Scripts/write-into-book-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LANGUAGE="${SHELF_SHOT_LANGUAGE:-en}"
CACHE="$HOME/Library/Caches/Shelf/write-into-book-10"
LIB="${1:-$CACHE/library}"
DEFAULT_OUT="$ROOT/docs/screenshots/sprint-10"
[ "$LANGUAGE" = "en" ] || DEFAULT_OUT="$DEFAULT_OUT/de"
OUT="${2:-$DEFAULT_OUT}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/debug/shelf-tool"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "write-into-book-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "write-into-book-shot: $1"; }

# Every word this script types at a menu or looks for in the tree, in one
# place — the Sprint 7 lesson in a script of its own.
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
            cannotBeWritten) echo "kann nicht geschrieben werden" ;;
            protectedWord) echo "geschützt" ;;
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
            cannotBeWritten) echo "cannot be written" ;;
            protectedWord) echo "protected" ;;
            writtenInto) echo "written into" ;;
            *) fail "no English name for '$1'" ;;
        esac
    fi
}

. "$HERE/app-language.sh"
pin_app_language "$LANGUAGE"
. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
require_awake_screen "$@"

case "$LIB" in
    "$HOME/Library/Caches/Shelf/"*) ;;
    *) fail "this script writes into books, so it only runs against a throw-away library
       under ~/Library/Caches/Shelf. Build one: shelf-tool epub-write-fixture" ;;
esac

[ -x "$TOOL" ] || swift build --scratch-path "$SCRATCH" >/dev/null || fail "could not build shelf-tool"

# The fixture is rebuilt every run: the book "written into" below actually
# gets its file replaced, so a second run against a stale library would
# start from a book that has already been changed.
rm -rf "$LIB"
FIXTURE_OUT=$("$TOOL" epub-write-fixture "$LIB" 2>&1) || fail "epub-write-fixture failed:
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
    screencapture -o -x -l "$wid" "/tmp/write-into-book-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/write-into-book-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/write-into-book-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null) || return 1
    [ -n "$point" ] || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
# A pop-up `NSMenu` (a right-click context menu) is not among the window's
# own elements — `menu-point.swift`, not `cell-point.swift`, the same
# distinction `cover-shot.sh` draws.
click_menu_item() {
    local point
    point=$(swift "$HERE/menu-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null) || return 1
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
# By exact title, so a substring shared with another synthetic book never
# picks the wrong one. Clicking a *cell* also resets the inspector's scroll
# position, which is where the "Write into the Book File…" button lives.
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
# The inspector is one long `ScrollView`, and "Write into the Book File…" is
# its last button — well below the first screenful for any book that has a
# description or an identifier. `AXScrollToVisible` does nothing for a
# SwiftUI `ScrollView` (tried; it is a genuine no-op here), so a real scroll
# wheel event is what moves it — `Scripts/scroll-at.swift`, at a point
# safely inside the inspector's own column.
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
        [ "$waited" -lt 30 ] || fail "the sheet never appeared"
        sleep 1
    done
    sleep 1.5
}
close_sheet() {
    click "desc=$(name_of cancel)" >/dev/null 2>&1 || click "desc=$(name_of close)" >/dev/null 2>&1
    sleep 1
}

place_window

# ── 1. What the button offers ────────────────────────────────────────────────
select_book "The Glass Almanac"
tree_has "$(name_of menuItem)" || fail "no “$(name_of menuItem)” button in the inspector for an eligible EPUB"
scroll_inspector_down
shoot 1-menu

# ── 2. The confirmation, old beside new ──────────────────────────────────────
# This book was edited in Shelf (shelf-tool epub-write-fixture): its
# publisher, language, published date and description all differ from what
# its own file still has.
open_write_sheet
tree_has "Erik & Erik Press" || fail "the sheet does not show the new publisher"
tree_has "2024" || fail "the sheet does not show the new published date"
shoot 2-confirmation
close_sheet

# ── 3. A field the sheet marks, rather than drops ────────────────────────────
# "Nameless" is the one EPUB with no <dc:title> at all, the one real case
# EPUBOPFPatch never invents a title for.
select_book "Nameless"
open_write_sheet
tree_has "$(name_of cannotBeWritten)" || fail "the sheet does not mark the title as unwritable"
shoot 3-unwritten-field
close_sheet

# ── 4. The DRM refusal ───────────────────────────────────────────────────────
# A DRM book alone never offers the command at all — it is not eligible on
# its own, so the inspector's button does not even appear for it. Selecting
# it alongside an ordinary book and opening the sheet from the grid's own
# context menu is what shows the refusal named in a plan with something
# else in it, which is the real shape a mixed selection takes.
click "desc=$(name_of clearSearch)" >/dev/null 2>&1
sleep 1
click "desc=The Quiet Harbour" || fail "no cell for “The Quiet Harbour”"
sleep 1
POINT=$(swift "$HERE/cell-point.swift" "$PID" "desc=A Protected Book" 2>/dev/null) \
    || fail "no cell for “A Protected Book”"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* } cmd
sleep 1
POINT=$(swift "$HERE/cell-point.swift" "$PID" "desc=A Protected Book" 2>/dev/null) \
    || fail "no cell for “A Protected Book”, second look"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* } right
sleep 1
click_menu_item "$(name_of menuItem)" || fail "no “$(name_of menuItem)” item in the grid's context menu"
sleep 1
WAITED=0
until tree_has "AXSheet"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 30 ] || fail "the sheet never appeared from the context menu"
    sleep 1
done
sleep 1.5
tree_has "$(name_of protectedWord)" || fail "the sheet does not explain the DRM refusal"
tree_has "The Quiet Harbour" || fail "the sheet does not also show the eligible book from the same selection"
shoot 4-drm-refused
close_sheet

# ── 5. After: written, the original in the Trash ─────────────────────────────
select_book "The Glass Almanac"
open_write_sheet
# "every checkbox of sheet 1" finds nothing — the sheet is one wrapping
# group deep, so the search has to be recursive ("entire contents"), the
# same reason `device-shot.sh` names the exact group path for its own sheet.
TICKED=$(osascript <<EOF 2>/dev/null
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
)
[ "${TICKED:-0}" -gt 0 ] || fail "could not tick “$(name_of checkbox)”"
sleep 0.5
# Occurrence 1, not 0: "Write into the Book File" is a *prefix* of the
# inspector's own "Write into the Book File…" button, still sitting behind
# the sheet, and it is found first in the tree. Checked once by hand and
# left explicit here rather than trusted to stay lucky.
click "desc=$(name_of writeButton)" 1 || fail "no “$(name_of writeButton)” button"
WAITED=0
# Not "⌘Z" — the sheet's own *ready* explanation already says that,
# before anything runs, and a check for it here could pass the instant the
# button is clicked rather than once the write is actually done. "written
# into" / "beschrieben" is `finished`'s own text alone.
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
# XML-escaped, the way the OPF actually writes it — "Erik & Erik Press"
# plain never matches and the first version of this check said the write
# had failed when it had not.
unzip -p "$NEW_EPUB" OEBPS/content.opf 2>/dev/null | grep -q "Erik &amp; Erik Press" \
    || fail "the book's own file does not carry the new publisher after the write"
say "checked: $NEW_EPUB now carries the publisher written into it, on disk"
shoot 5-after
close_sheet

say "done – $OUT"
