#!/bin/bash
# Drives the real window through the four Sprint 8 sheets and photographs each.
#
# The command line proves the arithmetic (`proof-run.sh` section 12); this
# proves the *window* offers it, and that what it offers says what it does
# before it does anything — which is a different claim from "the core can work
# it out".
#
# It presses one button that moves something, and only one: the organise is
# carried out so that the *report* can be photographed, which is the fourth
# picture and the one that says what actually happened. That is safe here and
# nowhere else — this script only ever runs against the throw-away library
# `Scripts/organize-library.sh` builds, and it refuses to start if that library
# is not the one it was given. The export dialogue is photographed and
# cancelled; nothing is exported.
#
# Needs Screen Recording and Accessibility, and an unlocked screen. It never
# ends a Shelf it did not start.
#
# It runs in **either language**. `SHELF_SHOT_LANGUAGE=de` pins German and uses
# the German menu names; anything else is English. Every name this script types
# is in one table below, `menu_name`, so a script that drives menus says which
# language it is written for rather than discovering it at run time — the
# Sprint 7 lesson, which cost two runs of `online-shot.sh`.
#
# Usage: Scripts/organize-shot.sh [library] [output folder]
#        SHELF_SHOT_LANGUAGE=de Scripts/organize-shot.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LANGUAGE="${SHELF_SHOT_LANGUAGE:-en}"
LIB="${1:-$HOME/Library/Caches/Shelf/measure-library-8/shots/library}"
DEFAULT_OUT="$ROOT/docs/screenshots/sprint-8"
[ "$LANGUAGE" = "en" ] || DEFAULT_OUT="$DEFAULT_OUT/de"
OUT="${2:-$DEFAULT_OUT}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "organize-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "organize-shot: $1"; }

# Shelf follows the Mac's language; every menu name below is English, so the
# run says which language it is written for (the Sprint 7 lesson).
. "$HERE/app-language.sh"
pin_app_language "$LANGUAGE"

# Every word this script types at a menu or waits for in a window, in one
# place. A missing row is a loud failure rather than a silent miss, because a
# menu item asked for by the wrong name reads exactly like a menu item that is
# not there (Scripts/app-language.sh).
menu_name() {
    if [ "$LANGUAGE" = "de" ]; then
        case "$1" in
            file) echo "Ablage" ;;
            library) echo "Bibliothek" ;;
            organize) echo "Bibliothek aufräumen…" ;;
            export) echo "Bibliothek exportieren…" ;;
            spellings) echo "Schreibweisen" ;;
            target) echo "Alle werden zu" ;;
            obstacle) echo "dort liegt schon etwas" ;;
            moved) echo "Bewegt ·" ;;
            calibre) echo "Für Calibre" ;;
            booksonly) echo "Nur die Bücher" ;;
            archive) echo "Archiv" ;;
            honest) echo "Nur die Buchdateien" ;;
            move_button) echo "Ordner bewegen" ;;
            emptied) echo "Autorenordner" ;;
            *) fail "no German word for '$1' — add it to menu_name" ;;
        esac
    else
        case "$1" in
            file) echo "File" ;;
            library) echo "Library" ;;
            organize) echo "Organize Library…" ;;
            export) echo "Export Library…" ;;
            spellings) echo "Spellings" ;;
            target) echo "They all become" ;;
            obstacle) echo "already there, and it is not empty" ;;
            moved) echo "Moved ·" ;;
            calibre) echo "For Calibre" ;;
            booksonly) echo "Just the books" ;;
            archive) echo "Archive" ;;
            honest) echo "The book files alone" ;;
            move_button) echo "Move" ;;
            emptied) echo "author folders" ;;
            *) fail "no English word for '$1' — add it to menu_name" ;;
        esac
    fi
}

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index — run Scripts/organize-library.sh first"

# This script presses "Move N Folders" for the report shot, so it checks that
# it has been pointed at the disposable library and not at a real one. A
# screenshot is never a reason to rearrange somebody's books.
case "$LIB" in
    *"/Library/Caches/Shelf/"*) : ;;
    *) fail "this script moves folders for the report shot and will only do it inside
       ~/Library/Caches/Shelf. Build one with Scripts/organize-library.sh." ;;
esac
mkdir -p "$OUT"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app)" || exit 1
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1

# Never end a Shelf this script did not start.
require_no_foreign_shelf

open -a "$APP" "$LIB" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 14 2>/dev/null; }
# `grep -c`, never `grep -q`: under `pipefail` a match closes the pipe, the
# other side dies of SIGPIPE, the status becomes 141 and a hit reads as a miss.
tree_has() {
    local n
    n=$(tree | grep -c "$1")
    [ "${n:-0}" -gt 0 ]
}
wait_for() {
    local waited=0
    until tree_has "$1"; do
        waited=$((waited + 1))
        [ "$waited" -lt 30 ] || fail "$2"
        sleep 1
    done
}
shoot() {
    front
    sleep 1.5
    local wid
    wid=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
    [ -n "$wid" ] || fail "no window to photograph"
    screencapture -o -x -l "$wid" "/tmp/organize-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/organize-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/organize-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
    tree | sed -n '/AXSheet/,$p' | head -60 >"$OUT/ax-$1.txt"
}
escape() {
    front
    sleep 0.4
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
    sleep 1.5
}
click_named() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "desc=$1" 2>/dev/null) || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
    sleep 1
}

front
sleep 0.8
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 25}
    delay 0.3
    set size of window 1 to {1440, 950}
end tell
EOF
sleep 1

# ── 1. The merge dialogue ────────────────────────────────────────────────────
# Right-click the first author row. The context menu is the only way in, which
# is itself worth photographing: this is not a command somebody stumbles into.
say "the merge dialogue"

# The sidebar is a scroll view and the Authors section is a long way down it:
# in a 30-book library there are Smart Collections, three shelves and a screenful
# of tags above it, so the row this needs sits *below the window*. Clicking at a
# point outside the window opens nothing, silently — which is exactly how the
# first run of this script reported "the context menu did not open" when what
# had really happened was a right-click on the desktop.
#
# So the row is scrolled into view first, and the point is asked for again
# afterwards, because scrolling has moved it.
bring_into_view() {
    local want="$1" point y tries=0
    while :; do
        point=$(swift "$HERE/cell-point.swift" "$PID" "desc=$want" 2>/dev/null) || return 1
        y=${point#* }
        # The window is 950 high at y=25, so anything past ~955 is off it.
        [ "$y" -gt 25 ] && [ "$y" -lt 955 ] && {
            echo "$point"
            return 0
        }
        # A posted scroll-wheel event does not reach a SwiftUI `ScrollView`
        # at all — the same limit `docs/BACKLOG.md` records for the table — so
        # there is nothing to try again with. The library is built small
        # enough instead (`Scripts/organize-library.sh` says why).
        return 1
    done
}

# The sidebar's help string is a sentence and is therefore translated, so the
# row is found by the author's *name*, which is data and is not.
P=$(bring_into_view "Sebastian Fitzek, 3") \
    || P=$(bring_into_view "Fitzek, Sebastian, 3") \
    || fail "no Fitzek row could be brought into view — is this the library Scripts/organize-library.sh built?"
say "  the author row is at ${P}"
swift "$HERE/click-at.swift" ${P% *} ${P#* } right 2>/dev/null \
    || fail "could not right-click the author row"
sleep 1.5

# The menu is driven from the *keyboard*, not by clicking a menu item by name.
# A SwiftUI `.contextMenu` is an NSMenu that does not appear as a child of the
# application process the way a menu-bar menu does, so `click menu item …`
# finds nothing — and a menu answers arrow keys and ⏎ whatever its parentage.
# Two downs: "Rename “…”…" first, "Merge into…" second.
osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
    key code 125
    delay 0.2
    key code 125
    delay 0.2
    key code 36
end tell
EOF
wait_for "$(menu_name spellings)" "the merge sheet never appeared — did the context menu open?"
sleep 1.5
tree_has "$(menu_name target)" || fail "the merge sheet has no target field"
tree_has "Fitzek" || fail "the merge sheet does not list the spellings it was opened on"
shoot merge-dialog
escape

# ── 2. The organise preview, with its collisions ─────────────────────────────
say "the organise preview"
front
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"$(menu_name organize)\" of menu 1 of menu bar item \"$(menu_name library)\" of menu bar 1" >/dev/null 2>&1 \
    || fail "there is no $(menu_name library) ▸ $(menu_name organize) item"
# The obstacle's own words. Not "collision": two indexed books cannot want one
# folder — the running number is unique — so what a real library has in its way
# is a folder that is already there (docs/DATA-MODEL.md §10).
wait_for "$(menu_name obstacle)" "the preview never appeared, or it names no obstacle — run Scripts/organize-library.sh, which builds one"
sleep 2
shoot organize-preview

# ── 2b. And the report, which is the picture that says what happened ─────────
# The one button this script presses. See the note at the top: the library is
# this project's own throw-away one.
say "carrying the organise out, for the report"
MOVE_BUTTON=$(tree | sed -n "s/.*AXButton desc=\"\([^\"]*$(menu_name move_button)[^\"]*\)\".*/\1/p" | head -1)
[ -n "$MOVE_BUTTON" ] || fail "no button naming “$(menu_name move_button)” in the preview"
say "  pressing “${MOVE_BUTTON}”"
click_named "$MOVE_BUTTON" || fail "could not press “${MOVE_BUTTON}”"
wait_for "$(menu_name moved)" "the report never appeared"
sleep 1.5
tree_has "$(menu_name emptied)" || say "note: no folder was left empty by these moves"
shoot organize-report
escape

# ── 3. The export dialogue ───────────────────────────────────────────────────
say "the export dialogue"
front
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"$(menu_name export)\" of menu 1 of menu bar item \"$(menu_name file)\" of menu bar 1" >/dev/null 2>&1 \
    || fail "there is no $(menu_name file) ▸ $(menu_name export) item"
wait_for "$(menu_name calibre)" "the export sheet never appeared"
sleep 1.5
tree_has "metadata.opf" || fail "the export sheet has no metadata.opf switch"
shoot export-archive

# All three presets, because each says something different about what it
# costs, and the sentence under "just the books" is the reason this sheet is
# worth photographing at all.
click_named "$(menu_name booksonly)" || fail "no “$(menu_name booksonly)” button"
sleep 1
# The start of the sentence, not the middle of it: an accessibility value is
# cut at 90 characters, so a phrase further in can never be matched.
tree_has "$(menu_name honest)" \
    || fail "“$(menu_name booksonly)” does not say that the ratings and shelves stay behind"
shoot export-books-only
say "the honest sentence is on screen ✓"

click_named "$(menu_name calibre)" || fail "no “$(menu_name calibre)” button"
sleep 1
shoot export-for-calibre
escape

say "ok – $OUT (nothing was moved, written or exported)"
