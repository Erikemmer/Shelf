#!/bin/bash
# Drives the real window through "Remove Cover" — the hole Sprint 9 left
# open on purpose (`CoverReplacement.remove` existed for undo; nothing
# offered it, because nobody asked for it, docs/BACKLOG.md). Photographs the
# menu item, in both places it now sits (the inspector's own Cover menu and
# the grid/table context menu), and the two states a screenshot can prove a
# unit test cannot: the cell drawing the placeholder afterward, and the
# sidebar's "Missing Cover" counter one higher. Every claim is checked
# against the folder on disk and the sidebar's own count, not against the
# picture.
#
# Also proves the two disabled states, the same way `cover-shot.sh` proves a
# refusal: by clicking the item anyway and checking nothing happened.
#
# Runs against `Scripts/cover-library.sh`'s own fixture — the same library
# `cover-shot.sh` uses — so it never writes into a library that is not a
# disposable one of its own.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
#
# It runs in **either language**. `SHELF_SHOT_LANGUAGE=de` pins German and
# uses the German names; anything else is English.
#
# Usage: Scripts/remove-cover-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LANGUAGE="${SHELF_SHOT_LANGUAGE:-en}"
CACHE="$HOME/Library/Caches/Shelf/cover-library-9"
LIB="${1:-$CACHE/library}"
DEFAULT_OUT="$ROOT/docs/screenshots/sprint-12"
[ "$LANGUAGE" = "en" ] || DEFAULT_OUT="$DEFAULT_OUT/de"
OUT="${2:-$DEFAULT_OUT}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "remove-cover-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "remove-cover-shot: $1"; }

name_of() {
    if [ "$LANGUAGE" = "de" ]; then
        case "$1" in
            coverMenu) echo "Das Cover von" ;;
            remove) echo "Cover entfernen" ;;
            missing) echo "Ohne Cover" ;;
            clearSearch) echo "Suche leeren" ;;
            searchField) echo "Suchen" ;;
            *) fail "no German name for '$1'" ;;
        esac
    else
        case "$1" in
            coverMenu) echo "Change the cover of" ;;
            remove) echo "Remove Cover" ;;
            missing) echo "Missing Cover" ;;
            clearSearch) echo "Clear the search" ;;
            searchField) echo "Search" ;;
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
    *) fail "this script removes covers, so it only runs against a throw-away library
       under ~/Library/Caches/Shelf. Build one: Scripts/cover-library.sh" ;;
esac
[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – run Scripts/cover-library.sh"
mkdir -p "$OUT"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app)" || exit 1
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
tree() { swift "$HERE/ax-dump.swift" "$PID" 14 2>/dev/null; }
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
    screencapture -o -x -l "$wid" "/tmp/remove-cover-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/remove-cover-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/remove-cover-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null) || return 1
    [ -n "$point" ] || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
menu_point() { swift "$HERE/menu-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null; }
# Clearing the search and re-laying out seven cells is not instant, and the
# first attempt right after `clearSearch` can ask before the grid has
# finished — so this retries the read-only lookup a few times before a
# caller treats "not found yet" as "not there at all".
cell_point() {
    local point tries=0
    while [ "$tries" -lt 8 ]; do
        point=$(swift "$HERE/cell-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null)
        [ -n "$point" ] && { echo "$point"; return 0; }
        tries=$((tries + 1))
        sleep 0.5
    done
    return 1
}
click_menu_item() {
    local point
    point=$(menu_point "$1" "${2:-0}") || return 1
    [ -n "$point" ] || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
# A pop-up `NSMenu` opening at all is a race with the click that asked for it
# — the same class of flakiness `open_write_sheet` in
# write-into-book-cover-shot.sh already waits out. One retry, on a probe that
# only reads (`menu_point`, never clicks), before giving up for real.
open_cover_menu() {
    click "desc=$(name_of coverMenu)" || fail "there is no cover menu under the picture"
    sleep 1.5
    if [ -z "$(menu_point "$(name_of remove)")" ]; then
        click "desc=$(name_of coverMenu)" || fail "there is no cover menu under the picture"
        sleep 1.5
        [ -n "$(menu_point "$(name_of remove)")" ] || fail "the Cover menu never opened"
    fi
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
# `metadata.opf` holds an apostrophe as `&apos;` (`OPFDocument.escaped`), so a
# title carrying one has to be escaped the same way before it is grepped for
# — otherwise `grep` finds nothing, `dirname` of nothing is `.`, and every
# check downstream silently asks the wrong folder rather than failing loudly.
xml_escaped_title() { echo "$1" | sed "s/&/\&amp;/g; s/'/\&apos;/g"; }
folder_of() {
    local match
    match=$(grep -rl "<dc:title>$(xml_escaped_title "$1")<" "$LIB" --include=metadata.opf 2>/dev/null | head -1)
    [ -n "$match" ] && dirname "$match"
}
cover_of() { find "$1" -maxdepth 1 -name 'cover.*' 2>/dev/null | head -1; }
missing_count() { tree | grep -o "$(name_of missing), [0-9]*" | head -1; }
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

place_window

# ── 1. The menu item, on a book that has a cover, and what it does ──────────
BOOK="The Ministry Called Peace #1"
select_book "Ministry Called"
FOLDER=$(folder_of "$BOOK")
[ -d "$FOLDER" ] || fail "no folder for “${BOOK}” – is this the library cover-library.sh built?"
[ -n "$(cover_of "$FOLDER")" ] || fail "“${BOOK}” has no cover to begin with"
MISSING_BEFORE=$(missing_count)
open_cover_menu
shoot 1-menu
click_menu_item "$(name_of remove)" || fail "no “$(name_of remove)” item in the inspector's Cover menu"
sleep 2
[ -z "$(cover_of "$FOLDER")" ] || fail "the cover is still on disk after “$(name_of remove)”"
MISSING_AFTER=$(missing_count)
[ "$MISSING_AFTER" != "$MISSING_BEFORE" ] || fail "the sidebar still says “${MISSING_BEFORE}”"
say "removed “${BOOK}”'s cover: sidebar $MISSING_BEFORE → $MISSING_AFTER"
shoot 2-after

# ── 2. Disabled: a book that already has no cover ───────────────────────────
COVERLESS="The Long Way Gods #1"
select_book "Long Way Gods"
EMPTY=$(folder_of "$COVERLESS")
[ -d "$EMPTY" ] || fail "no folder for “${COVERLESS}”"
[ -z "$(cover_of "$EMPTY")" ] || fail "“${COVERLESS}” unexpectedly has a cover – rebuild the library"
open_cover_menu
shoot 3-disabled-no-cover
click_menu_item "$(name_of remove)" >/dev/null 2>&1
sleep 1
# A click on a *disabled* item does not dismiss the menu the way a click on an
# enabled one does — Escape closes it, so the next stage's clicks land on the
# grid rather than on a menu still sitting open on top of it.
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
sleep 0.5
[ -z "$(cover_of "$EMPTY")" ] || fail "clicking a disabled “$(name_of remove)” wrote a cover"
say "“$(name_of remove)” disabled on a book with no cover, and clicking it did nothing"

# ── 3. The grid's own context menu, on a book that has a cover ──────────────
BOOK2="The Handmaid's of Darkness #2"
FOLDER2=$(folder_of "$BOOK2")
[ -d "$FOLDER2" ] || fail "no folder for “${BOOK2}”"
[ -n "$(cover_of "$FOLDER2")" ] || fail "“${BOOK2}” has no cover to begin with"
click "desc=$(name_of clearSearch)" >/dev/null 2>&1
sleep 2
POINT=$(cell_point "desc=The Handmaid") || fail "no cell for “${BOOK2}”"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* } >/dev/null 2>&1
sleep 0.5
MISSING_BEFORE2=$(missing_count)
POINT=$(cell_point "desc=The Handmaid") || fail "no cell for “${BOOK2}”"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* } right >/dev/null 2>&1
sleep 1
shoot 4-grid-context-menu
click_menu_item "$(name_of remove)" || fail "no “$(name_of remove)” item in the grid's context menu"
sleep 2
[ -z "$(cover_of "$FOLDER2")" ] || fail "the cover is still on disk after the grid menu's “$(name_of remove)”"
MISSING_AFTER2=$(missing_count)
[ "$MISSING_AFTER2" != "$MISSING_BEFORE2" ] || fail "the sidebar still says “${MISSING_BEFORE2}” after the grid menu"
say "grid context menu removed “${BOOK2}”'s cover: sidebar $MISSING_BEFORE2 → $MISSING_AFTER2"

# ── 4. Disabled: a multiple selection ────────────────────────────────────────
BOOK3="Use of Season #3"
BOOK4="The Ministry Justice #5"
FOLDER3=$(folder_of "$BOOK3")
FOLDER4=$(folder_of "$BOOK4")
[ -n "$(cover_of "$FOLDER3")" ] || fail "“${BOOK3}” has no cover to begin with"
[ -n "$(cover_of "$FOLDER4")" ] || fail "“${BOOK4}” has no cover to begin with"
POINT=$(cell_point "desc=Use of Season") || fail "no cell for “${BOOK3}”"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* } >/dev/null 2>&1
sleep 0.5
POINT=$(cell_point "desc=The Ministry Justice") || fail "no cell for “${BOOK4}”"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* } cmd >/dev/null 2>&1
sleep 0.5
POINT=$(cell_point "desc=The Ministry Justice") || fail "no cell for “${BOOK4}”"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* } right >/dev/null 2>&1
sleep 1
shoot 5-disabled-multiple-selection
click_menu_item "$(name_of remove)" >/dev/null 2>&1
sleep 1
[ -n "$(cover_of "$FOLDER3")" ] || fail "“${BOOK3}” lost its cover during a disabled multiple selection"
[ -n "$(cover_of "$FOLDER4")" ] || fail "“${BOOK4}” lost its cover during a disabled multiple selection"
say "“$(name_of remove)” disabled during a multiple selection, and clicking it changed nothing"

say "done – $OUT"
