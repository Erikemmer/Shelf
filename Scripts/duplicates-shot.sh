#!/bin/bash
# The two Sprint 6 fixes, photographed: the sidebar's two duplicate rows, and
# what the inspector says about a selection of several books.
#
# Against `measure-library-6/library` — 415 books, of which four really are
# copies (two book folders duplicated the way a person duplicates them) and 394
# only share a title with something. Before this sprint the sidebar said "396".
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
# It never ends a Shelf it did not start.
#
# Usage: Scripts/duplicates-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="${1:-$HOME/Library/Caches/Shelf/measure-library-6/library}"
OUT="${2:-$ROOT/docs/screenshots/sprint-6}"

fail() { echo "duplicates-shot: FAILED – $1" >&2; exit 1; }
say() { echo "duplicates-shot: $1"; }

# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"
[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index"
mkdir -p "$OUT"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    while IFS= read -r candidate; do
        candidate="${candidate#* }"
        [ -x "$candidate/Contents/MacOS/Shelf" ] || continue
        APP="$candidate"; break
    done < <(find ~/Library/Developer/Xcode/DerivedData -name "Shelf.app" -path "*/Build/Products/*" \
        -not -path "*Index.noindex*" -maxdepth 6 -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn)
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1
require_no_foreign_shelf

open -a "$APP" "$LIB" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
sleep 12
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() { osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1; }
tree() { swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null; }
tree_has() { local n; n=$(tree | grep -c "$1"); [ "${n:-0}" -gt 0 ]; }
menu() { osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null 2>&1; }
WINDOW_RECT="30,40,1440,877"
shoot() {
    front
    swift "$HERE/cursor-park.swift" 1500 8 >/dev/null 2>&1
    sleep 1.5
    screencapture -x -R "$WINDOW_RECT" "/tmp/duplicates-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/duplicates-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/duplicates-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}

front
sleep 1
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
EOF
sleep 3

WAITED=0
until tree_has "Possible Duplicates,"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 40 ] || fail "the sidebar never showed the two duplicate rows"
    sleep 1
done
say "$(tree | grep -E 'Duplicates,' | sed 's/^ *//')"

# ── 1. The two rows, with a certain duplicate selected ───────────────────────
#
# The *Duplicates* collection, so the grid shows the four that really are
# copies and the inspector names the rule that found each one.
front
P=$(swift "$HERE/cell-point.swift" "$PID" "text=Duplicates, 4" 2>/dev/null) \
    || P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Books that share a file" 2>/dev/null) \
    || fail "could not find the Duplicates row"
swift "$HERE/click-at.swift" ${P% *} ${P#* }
sleep 3
shoot "duplicates-certain"

# ── 2. Possible duplicates, the other collection ─────────────────────────────
front
P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Books that share only a title" 2>/dev/null) \
    || fail "could not find the Possible Duplicates row"
swift "$HERE/click-at.swift" ${P% *} ${P#* }
sleep 3
shoot "duplicates-possible"

# ── 3. What the inspector says about several books ───────────────────────────
#
# Every book, so the three values that used to be three bare "Mixed" in three
# type sizes are now named rows in Details.
front
P=$(swift "$HERE/cell-point.swift" "$PID" "desc=Show all books" 2>/dev/null) \
    || fail "could not find the All Books row"
swift "$HERE/click-at.swift" ${P% *} ${P#* }
sleep 3
menu "Library" "Select All Books"
sleep 4
tree_has "books selected" || say "warning: the inspector does not say how many are selected"
shoot "selection-details"

osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1
sleep 3
say "done – $OUT"
