#!/bin/bash
# Drives the real window through Library ▸ Find Orphaned Folders… and
# photographs both steps.
#
# The command line proves the arithmetic (`shelf-tool orphans`, and section 9 of
# `proof-run.sh`); this proves the *window* offers it and that the confirmation
# names every file before anything can move — which is the promise, and a
# different claim from "the core can list them".
#
# It stops at the confirmation. The button that moves folders to the Trash is
# deliberately not pressed: this script's job is evidence, and putting a few
# hundred files into somebody's Trash as a side effect of taking a screenshot is
# not its business.
#
# Needs Screen Recording and Accessibility, and an unlocked screen. It never
# ends a Shelf it did not start.
#
# Usage: Scripts/orphan-shot.sh [library with orphans] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="${1:-$HOME/Library/Caches/Shelf/measure-library-4/shots-library}"
OUT="${2:-$ROOT/docs/screenshots/sprint-4}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "orphan-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "orphan-shot: $1"; }

# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
require_awake_screen "$@"

[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index"
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

# Never end a Shelf this script did not start: if one is running, say so and
# stop, rather than photographing somebody else's window.
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
# `grep -c`, never `grep -q`: under `pipefail` a match closes the pipe, the
# other side dies of SIGPIPE, the status becomes 141 and a hit reads as a miss.
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
    screencapture -o -x -l "$wid" "/tmp/orphan-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/orphan-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/orphan-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}

front
sleep 0.8
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
EOF
sleep 1

# The menu item, not a shortcut: it has none, and clicking is what a person does.
front
sleep 0.5
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"Find Orphaned Folders…\" of menu 1 of menu bar item \"Library\" of menu bar 1" >/dev/null 2>&1 \
    || fail "there is no Library ▸ Find Orphaned Folders… item"

WAITED=0
until tree_has "Orphaned Folders"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 30 ] || fail "the sheet never appeared"
    sleep 1
done
sleep 2
tree_has "no book in this library" \
    || fail "the sheet is up but found no orphans — give this script a library that has some.
       'shelf-tool orphans <library>' says whether one does."
say "the list is up"
shoot orphans-found
tree | sed -n '/AXSheet/,$p' | head -50 >"$OUT/ax-orphans-found.txt"

# ── The confirmation, which is the part that matters ─────────────────────────
# The rule is a confirmation that names every file (CONCEPT §8.3's rule applied
# here). This is the step that has to show file names, not just a count.
P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Move to Trash…" 2>/dev/null) \
    || fail "no 'Move to Trash…' button in the sheet"
swift "$HERE/click-at.swift" ${P% *} ${P#* }
WAITED=0
until tree_has "Move These to the Trash"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 20 ] || fail "the confirmation never appeared"
    sleep 1
done
sleep 1.5
tree_has "metadata.opf" \
    || fail "the confirmation does not name the files it would move.
       Naming every one of them is the whole point of this step."
say "the confirmation names the files"
shoot orphans-confirm
tree | sed -n '/AXSheet/,$p' | head -60 >"$OUT/ax-orphans-confirm.txt"

# Back out. Nothing is moved by this script.
P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Back" 2>/dev/null) && swift "$HERE/click-at.swift" ${P% *} ${P#* }
sleep 1
P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Done" 2>/dev/null) && swift "$HERE/click-at.swift" ${P% *} ${P#* }

say "ok – $OUT (nothing was moved)"
