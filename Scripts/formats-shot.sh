#!/bin/bash
# Sprint 4's evidence at the window: the formats, the DRM badges, several files
# on one book, Quick Look, and what a CBR says on this Mac.
#
# The import is driven through the *app* rather than through `shelf-tool`, and
# that is the point of the script. The tool has no PDFKit, so a PDF imported by
# it has no cover; a screenshot taken of that would be a picture of the tool's
# limitation rather than of the app's behaviour.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
#
# It never ends a Shelf it did not start: if one is already running it stops and
# says so, rather than quitting somebody's window.
#
# Usage: Scripts/formats-shot.sh [source folder] [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="$HOME/Library/Caches/Shelf/measure-library-4"
SOURCE="${1:-$CACHE/formats-shots-source}"
LIB="${2:-$CACHE/formats-shots}"
OUT="${3:-$ROOT/docs/screenshots/sprint-4}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "formats-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "formats-shot: $1"; }

# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
require_awake_screen "$@"

[ -d "$SOURCE" ] || fail "'$SOURCE' is not a folder"
[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – make the library first"
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

# Never end a process this script did not start.
pgrep -x Shelf >/dev/null && fail "a Shelf is already running – close it yourself, then run this again"

open -a "$APP" "$LIB" || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 12 2>/dev/null; }
# `grep -c`, never `grep -q`: under `pipefail` a match closes the pipe and the
# status becomes 141, so a hit reads as a miss.
tree_has() {
    local n
    n=$(tree | grep -c "$1")
    [ "${n:-0}" -gt 0 ]
}
# Which cell holds a book with several files, counted from the cells' own
# descriptions.
#
# Two wrong turns got here, and both produced a *green* run with a wrong
# picture. `tree_has "AZW3"` matched the sidebar's own Formats section, so the
# first cell always passed and the shot showed a comic with one format. Scoping
# to the text after "FORMATS" did not help either: the sidebar's heading is
# spelled the same and comes first.
#
# A grid cell's help string is "Title ⏎ Author ⏎ [Series ⏎] FORMAT · FORMAT",
# so the cells that hold more than one file are the ones whose help has a "·"
# in that last line. That is the question being asked, asked directly.
multi_format_cell() {
    tree | grep -o 'AXImage help="[^"]*"' \
        | awk -F'⏎ ' '{ print NR - 1, $NF }' \
        | grep " · " \
        | head -1 \
        | cut -d" " -f1
}
shoot() {
    front
    sleep 1.5
    local wid
    wid=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
    [ -n "$wid" ] || fail "no window to photograph"
    screencapture -o -x -l "$wid" "/tmp/formats-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/formats-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/formats-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" ${2:-} 2>/dev/null) || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
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

# ── The import, through the window ───────────────────────────────────────────
front
sleep 0.5
osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"Add Books…\" of menu 1 of menu bar item \"File\" of menu bar 1" >/dev/null 2>&1 \
    || fail "there is no File ▸ Add Books… item"
sleep 3
osascript -e 'tell application "System Events" to keystroke "g" using {command down, shift down}' >/dev/null 2>&1
sleep 2
osascript -e "tell application \"System Events\" to keystroke \"$SOURCE\"" >/dev/null 2>&1
sleep 1.5
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
say "chose $(basename "$SOURCE")"

WAITED=0
until tree_has "new book" || tree_has "Nothing to Import"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 60 ] || fail "the plan never appeared in the sheet"
    sleep 1
done
tree_has "Nothing to Import" && fail "the library already holds all of these – use a fresh one"
say "the plan is up"
shoot formats-plan

click "desc=Import" || fail "no Import button"
WAITED=0
until tree_has "Verified"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 120 ] || fail "the import never finished"
    sleep 1
done
say "the import finished"
shoot formats-report
tree | sed -n '/AXSheet/,$p' | head -40 >"$OUT/ax-formats-report.txt"
click "desc=Done"
sleep 3

# ── The grid, with a DRM badge on it ─────────────────────────────────────────
front
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "f" using command down' >/dev/null 2>&1
sleep 1
osascript -e 'tell application "System Events" to keystroke "Protected"' >/dev/null 2>&1
sleep 3
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
tree_has "DRM" || fail "no DRM badge anywhere after searching for the protected books.
       'shelf-tool orphans' is not the check here — look at the import report:
       the protected files must have been recognised at import."
say "the DRM badges are up"
shoot formats-drm-grid
tree | grep -B2 -A2 "DRM" | head -30 >"$OUT/ax-formats-drm.txt"

# ── The inspector, with several files on one book ────────────────────────────
click "cell" 0 || fail "the search found no protected book"
sleep 2.5
shoot formats-inspector-drm

# Clear the search and pick a book that has four formats.
front
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "f" using command down' >/dev/null 2>&1
sleep 1
osascript -e 'tell application "System Events" to key code 51 using {command down}' >/dev/null 2>&1
osascript -e 'tell application "System Events" to keystroke "Desolation"' >/dev/null 2>&1
sleep 3
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
# The search returns the comic *and* the four-format book, and which comes
# first is a matter of sorting rather than of intent. So: try the first few
# cells and keep the one whose inspector actually shows a second format. A
# screenshot captioned "several formats" showing one format is worse than no
# screenshot.
FOUND=$(multi_format_cell)
[ -n "$FOUND" ] || fail "no book in this library has more than one file"
click "cell" "$FOUND" || fail "could not select cell $FOUND"
sleep 2.5
# The Formats section is the *last* block of the inspector and sits below the
# fold on a book with a series and a publisher. The first version of this shot
# selected the right book and photographed the top of the panel, which shows
# everything except the thing it was taken for.
#
# The window is 1440 × 877 at (30, 40) and the inspector is its right 280 pt, so
# the middle of that panel is about (1330, 500) in screen points.
swift "$HERE/scroll-at.swift" 1330 500 -14 3 >/dev/null 2>&1
sleep 1.5
say "the inspector shows several formats (cell $FOUND)"
shoot formats-inspector-many
tree | sed -n '/FORMATS/,$p' | head -40 >"$OUT/ax-formats-inspector.txt"

# ── The CBR line ─────────────────────────────────────────────────────────────
front
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "f" using command down' >/dev/null 2>&1
sleep 1
osascript -e 'tell application "System Events" to key code 51 using {command down}' >/dev/null 2>&1
osascript -e 'tell application "System Events" to keystroke "Saga"' >/dev/null 2>&1
sleep 3
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
if click "cell" 0; then
    sleep 2.5
    swift "$HERE/scroll-at.swift" 1330 500 -14 3 >/dev/null 2>&1
    sleep 1.5
    if tree_has "libarchive"; then
        say "the inspector names this Mac's libarchive for the CBR"
        shoot formats-cbr
        tree | grep -A3 "libarchive" | head -20 >"$OUT/ax-formats-cbr.txt"
    else
        say "NOTE: no libarchive line — the CBR was not imported or is not selected"
    fi
else
    say "NOTE: no CBR in this library, so there is nothing to photograph"
fi

# ── Quick Look over a PDF ────────────────────────────────────────────────────
front
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "f" using command down' >/dev/null 2>&1
sleep 1
osascript -e 'tell application "System Events" to key code 51 using {command down}' >/dev/null 2>&1
osascript -e 'tell application "System Events" to keystroke "Desolation"' >/dev/null 2>&1
sleep 3
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
# The book with several files, not whichever cell came first: Quick Look shows
# the *file* for a PDF and the cover for everything else, and a shot of a comic
# would be a shot of the second rule while claiming to be the first.
QL_CELL=$(multi_format_cell)
click "cell" "${QL_CELL:-0}" || fail "nothing to Quick Look"
sleep 1.5
front
osascript -e 'tell application "System Events" to keystroke " "' >/dev/null 2>&1
sleep 4
# Quick Look draws its own window, so this one is a full-screen capture.
screencapture -o -x "/tmp/formats-ql.png" || fail "capture failed for Quick Look"
sips -s format jpeg -s formatOptions 70 --resampleWidth 1800 "/tmp/formats-ql.png" --out "$OUT/formats-quicklook.jpg" >/dev/null 2>&1
rm -f /tmp/formats-ql.png
say "formats-quicklook.jpg ($(($(stat -f %z "$OUT/formats-quicklook.jpg") / 1024)) KB)"
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1

say "ok – $OUT"
