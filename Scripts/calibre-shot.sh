#!/bin/bash
# Drives the real window through a Calibre import and photographs it.
#
# Sprint 3's evidence at the window: the counting protocol before anything is
# copied, and the report afterwards. The command line proves the same thing
# against 2 000 books (`shelf-tool calibre-dry` / `calibre-import`); this proves
# the *window* shows it, which is a different claim and the one CONCEPT §7.3
# actually makes.
#
# Needs Screen Recording and Accessibility, and an unlocked screen. It never
# ends a Shelf it did not start.
#
# Usage: Scripts/calibre-shot.sh [target library] [calibre library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="${1:-$HOME/Library/Caches/Shelf/calibre-sheet-target-3}"
CAL="${2:-$HOME/Library/Caches/Shelf/calibre-fixture-3}"
OUT="${3:-$ROOT/docs/screenshots/sprint-3}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "calibre-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "calibre-shot: $1"; }

# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

[ -d "$CAL" ] || fail "'$CAL' is not a folder"
[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index"
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

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 12 2>/dev/null; }
tree_has() { local n; n=$(tree | grep -c "$1"); [ "${n:-0}" -gt 0 ]; }
shoot() {
    front; sleep 1.5
    local wid; wid=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
    [ -n "$wid" ] || fail "no window to photograph"
    screencapture -o -x -l "$wid" "/tmp/calibre-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/calibre-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/calibre-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}

front; sleep 0.8
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
EOF
sleep 1

# **The menu item, not ⌘⌥I.** System Events does deliver an option-modified
# command shortcut to some apps and did not deliver this one: the panel simply
# never appeared, with no error anywhere. Clicking the item is what a person
# does anyway, and it fails loudly.
front; sleep 0.5
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"Import from Calibre…\" of menu 1 of menu bar item \"File\" of menu bar 1" >/dev/null 2>&1 \
    || fail "there is no File ▸ Import from Calibre… item"
sleep 3
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to get name of window \"Open\"" >/dev/null 2>&1 \
    || fail "the open panel did not appear"

# ⇧⌘G takes a path in any open panel.
osascript -e 'tell application "System Events" to keystroke "g" using {command down, shift down}' >/dev/null 2>&1
sleep 2
osascript -e "tell application \"System Events\" to keystroke \"$CAL\"" >/dev/null 2>&1
sleep 1.5
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
say "chose $(basename "$CAL")"

WAITED=0
until tree_has "IN THE CALIBRE LIBRARY"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 30 ] || fail "the counting protocol never appeared in the sheet"
    sleep 1
done
say "the counting protocol is up"
shoot calibre-sheet
tree | sed -n '/AXSheet/,$p' | head -40 > "$OUT/ax-calibre-sheet.txt"

# ── And then actually import ─────────────────────────────────────────────────
P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Import" 2>/dev/null) \
    || fail "no Import button — the sheet most likely reads \"Nothing to Import\".
       The target library already holds these books, which is the importer doing
       its job. Give this script a library that does not."
swift "$HERE/click-at.swift" ${P% *} ${P#* }
WAITED=0
until tree_has "Verified"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 60 ] || fail "the import never finished"
    sleep 1
done
say "the import finished"
shoot calibre-report
tree | sed -n '/AXSheet/,$p' | head -40 > "$OUT/ax-calibre-report.txt"

# ── And the columns, in the inspector ───────────────────────────────────
# The half that is easy to believe and was wrong: the values reached every
# book's OPF and the inspector showed nothing, because the window wrote its own
# older `library.json` back over the one the import had just written, taking the
# columns' names with it. Nothing failed.
P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Done" 2>/dev/null) && swift "$HERE/click-at.swift" ${P% *} ${P#* }
sleep 2
front; sleep 0.5
osascript -e 'tell application "System Events" to keystroke "f" using command down' >/dev/null 2>&1
sleep 1
osascript -e 'tell application "System Events" to keystroke "wall"' >/dev/null 2>&1
sleep 3
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
P=$(swift "$HERE/cell-point.swift" "$PID" "cell" 0 2>/dev/null) || fail "the search found no imported book"
swift "$HERE/click-at.swift" ${P% *} ${P#* }
sleep 2.5
tree_has "FROM CALIBRE" \
    || fail "the inspector shows no Calibre columns for an imported book.
       The values are in the book's OPF either way — what is missing is the
       library's record of what the columns are called (library.json)."
say "the inspector shows the Calibre columns"
shoot calibre-inspector
tree | grep -A8 "FROM CALIBRE" > "$OUT/ax-calibre-inspector.txt"

say "ok – $OUT"
