#!/bin/bash
# Sprint 6's evidence at the window: the candidate list, the field-by-field
# comparison with its boxes ticked, the cover preview, and what a network
# failure looks like.
#
# The library is twelve generated EPUBs carrying the bibliographic details of
# twelve real books — real titles, real authors, real ISBNs — because a lookup
# cannot be photographed against invented ones. The *files* are synthetic
# throughout; no borrowed book is in this repository or in the cache
# (CLAUDE.md). `Scripts/online-library.sh` builds it.
#
# **The last shot really goes to the network and really fails.** Nothing on the
# Mac is switched off for it: `SHELF_ONLINE_HOST=metadata.invalid` sends the
# lookups at the name RFC 2606 reserves as never-resolvable, which is a line in
# this script rather than a change to anybody's system settings.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
# It never ends a Shelf it did not start.
#
# Usage: Scripts/online-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="$HOME/Library/Caches/Shelf/measure-library-6"
LIB="${1:-$CACHE/online-library}"
OUT="${2:-$ROOT/docs/screenshots/sprint-6}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "online-shot: FAILED – $1" >&2
    [ -n "${PID:-}" ] && osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1
    exit 1
}
say() { echo "online-shot: $1"; }

# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
require_awake_screen "$@"

[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – run Scripts/online-library.sh first"
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
pgrep -x Shelf >/dev/null && fail "a Shelf is already running – close it yourself, then run this again"

WINDOW_RECT="30,40,1440,877"

# Through `open`, never by running the binary. A directly executed bundle is
# not registered with the window server the way LaunchServices registers one:
# it draws its window and the accessibility API answers "no windows for pid …",
# so every lookup in this script fails for a reason that has nothing to do with
# the app. Measured, once, at the cost of a run.
start_shelf() { # [env assignment]
    if [ -n "${1:-}" ]; then
        open -a "$APP" --env "$1" "$LIB" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
    else
        open -a "$APP" "$LIB" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
    fi
    sleep 10
    PID=$(pgrep -x Shelf | head -1)
    [ -n "$PID" ] || fail "Shelf did not start"
    say "pid $PID"
    front
    sleep 0.8
    osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
EOF
    sleep 2
}

quit_shelf() {
    [ -n "${PID:-}" ] || return 0
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1
    sleep 3
    PID=""
}

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null; }
# `grep -c`, never `grep -q`: under `pipefail` a match closes the pipe and the
# status becomes 141, so a hit reads as a miss. It cost a whole run once.
tree_has() {
    local n
    n=$(tree | grep -c "$1")
    [ "${n:-0}" -gt 0 ]
}
wait_for() { # pattern seconds what
    local waited=0
    until tree_has "$1"; do
        waited=$((waited + 1))
        [ "$waited" -lt "$2" ] || return 1
        sleep 1
    done
    return 0
}
shoot() {
    front
    swift "$HERE/cursor-park.swift" 1500 8 >/dev/null 2>&1
    sleep 1.5
    screencapture -x -R "$WINDOW_RECT" "/tmp/online-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/online-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/online-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" ${2:-} 2>/dev/null) || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
menu() {
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null 2>&1
}
# Picks a book by typing its title into the search field and clicking the one
# cell that is left. Typing beats clicking a coordinate: the grid's order is
# the library's, and a book that moves takes the coordinate with it.
pick_book() {
    # ⌘F rather than a click on the field: after a sheet closes the click
    # sometimes lands before the window has the keyboard back, and what gets
    # typed is appended to the search that is already there — "Left HandClean
    # Code" matches nothing and the failure blames the grid. The menu item
    # cannot miss.
    front
    menu "Library" "Search"
    sleep 1
    osascript -e "tell application \"System Events\" to keystroke \"a\" using command down" >/dev/null 2>&1
    sleep 0.3
    osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1
    sleep 2.5
    local waited=0
    until click cell 0 2>/dev/null; do
        waited=$((waited + 1))
        [ "$waited" -lt 8 ] || fail "no book called “$1” in the grid"
        sleep 1
    done
    sleep 1
}

# ── 1. The candidate list ────────────────────────────────────────────────────
#
# A book with **no ISBN**, so the question is title-and-author and the answer is
# a list. Asked by ISBN both services answer one record, the sheet opens it
# straight away, and there is no list to photograph — which is the behaviour
# that is wanted and not the picture that is wanted.
say "the candidate list, against the live services"
start_shelf
pick_book "Left Hand"
menu "File" "Fetch Metadata…"
wait_for "Fetch Metadata" 20 || fail "the sheet never opened"
wait_for "Candidate:" 60 || {
    shoot "online-nothing-came-back"
    fail "no candidate ever appeared – see online-nothing-came-back.jpg"
}
shoot "online-candidates"
osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1
sleep 2

# ── 2. Old beside new, with the cover the service has ────────────────────────
#
# A book with an ISBN: one record, one candidate, and the sheet opens it. The
# picture is the whole point of the sprint — every field, what the book says,
# what the service says, and a box that is ticked only where the book has
# nothing.
say "the comparison, field by field"
pick_book "Clean Code"
menu "File" "Fetch Metadata…"
wait_for "Take over" 60 || fail "the comparison never appeared"
shoot "online-comparison"
osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1
sleep 2

# ── 3. The cover, on a book that has none ────────────────────────────────────
say "a book with no cover file, and the cover the service has"
pick_book "Fantastic"
menu "File" "Fetch Metadata…"
wait_for "Take over" 60 || fail "no candidate for the cover shot"
wait_for "Use This Cover" 25 || say "no cover offered – the shot will say so"
shoot "online-cover"
osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1
sleep 1
quit_shelf

# ── 4. What a network failure looks like ─────────────────────────────────────
say "the same lookup with the services pointed at a name that cannot resolve"
start_shelf "SHELF_ONLINE_HOST=metadata.invalid"
pick_book "Dune"
menu "File" "Fetch Metadata…"
wait_for "Network note" 60 || fail "the failure never reached the window"
shoot "online-network-error"
# And the same line in the status bar, with the sheet out of the way: the claim
# is that a network failure is *quiet*, and a sheet is not quiet.
osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1
sleep 2
shoot "online-network-error-status-bar"
quit_shelf

say "done – $OUT"
