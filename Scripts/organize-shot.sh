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
# Usage: Scripts/organize-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="${1:-$HOME/Library/Caches/Shelf/measure-library-8/shots/library}"
OUT="${2:-$ROOT/docs/screenshots/sprint-8}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "organize-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "organize-shot: $1"; }

# Shelf follows the Mac's language; every menu name below is English, so the
# run says which language it is written for (the Sprint 7 lesson).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
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
    while IFS= read -r candidate; do
        candidate="${candidate#* }"
        [ -x "$candidate/Contents/MacOS/Shelf" ] || continue
        APP="$candidate"
        break
    done < <(find ~/Library/Developer/Xcode/DerivedData -name "Shelf.app" -path "*/Build/Products/*" \
        -not -path "*Index.noindex*" -maxdepth 6 -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn)
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"

# Never end a Shelf this script did not start.
if pgrep -x Shelf >/dev/null; then
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
    sleep 1
    for _ in 1 2 3 4 5; do
        pgrep -x Shelf >/dev/null || break
        osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
        sleep 1.5
    done
    pgrep -x Shelf >/dev/null && fail "a Shelf instance will not quit – close whatever is open in it"
fi

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

P=$(bring_into_view "Show only Sebastian Fitzek") \
    || P=$(bring_into_view "Show only Fitzek, Sebastian") \
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
wait_for "Spellings" "the merge sheet never appeared — did the context menu open?"
sleep 1.5
tree_has "They all become" || fail "the merge sheet has no target field"
tree_has "Fitzek" || fail "the merge sheet does not list the spellings it was opened on"
shoot merge-dialog
escape

# ── 2. The organise preview, with its collisions ─────────────────────────────
say "the organise preview"
front
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"Organize Library…\" of menu 1 of menu bar item \"Library\" of menu bar 1" >/dev/null 2>&1 \
    || fail "there is no Library ▸ Organize Library… item"
wait_for "to move" "the organise preview never appeared"
sleep 2
# The obstacle's own words. Not "collision": two indexed books cannot want one
# folder — the running number is unique — so what a real library has in its way
# is a folder that is already there (docs/DATA-MODEL.md §10).
tree_has "already there, and it is not empty" \
    || fail "the preview names no obstacle — run Scripts/organize-library.sh, which builds one"
shoot organize-preview

# ── 2b. And the report, which is the picture that says what happened ─────────
# The one button this script presses. See the note at the top: the library is
# this project's own throw-away one.
say "carrying the organise out, for the report"
click_named "Move 8 Folders" || click_named "Move 7 Folders" || {
    P=$(swift "$HERE/cell-point.swift" "$PID" "role=AXButton" 2>/dev/null)
    fail "no “Move … Folders” button in the preview"
}
wait_for "Moved ·" "the report never appeared"
sleep 1.5
tree_has "author folders were left empty" || say "note: no folder was left empty by these moves"
shoot organize-report
escape

# ── 3. The export dialogue ───────────────────────────────────────────────────
say "the export dialogue"
front
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"Export Library…\" of menu 1 of menu bar item \"File\" of menu bar 1" >/dev/null 2>&1 \
    || fail "there is no File ▸ Export Library… item"
wait_for "For Calibre" "the export sheet never appeared"
sleep 1.5
tree_has "metadata.opf" || fail "the export sheet has no metadata.opf switch"
shoot export-dialog

# The honest sentence is the reason this sheet is worth a picture: press
# "Just the books" and the dialogue has to say what stays behind.
if click_named "Just the books"; then
    sleep 1
    # The start of the sentence, not the middle of it: an accessibility value
    # is cut at 90 characters, so a phrase further in can never be matched.
    tree_has "The book files alone" \
        || fail "“Just the books” does not say that the ratings and shelves stay behind"
    shoot export-books-only
    say "the honest sentence is on screen ✓"
fi
escape

say "ok – $OUT (nothing was moved, written or exported)"
