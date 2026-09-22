#!/bin/bash
# Photographs Shelf in German, which is the only way to see what a translation
# did to the layout: a word that is half as long again breaks a sidebar row, a
# button, or a column header, and no test can see that.
#
# **It does not change the Mac's language, and since Sprint 7 it does not change
# a preference at all.** `defaults write -g AppleLanguages` would change the
# language for every application and for the login session; writing the same key
# in Shelf's own domain was the next idea and did not reliably work
# (`Scripts/app-language.sh` says why, with the measurement). The language now
# goes on the **command line**, in the argument domain, so it lasts exactly as
# long as the launch. Anything this script writes, it writes under its own
# folder in ~/Library/Caches/Shelf.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
# It never ends a Shelf it did not start.
#
# Usage: Scripts/german-shots.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="$HOME/Library/Caches/Shelf/measure-library-7"
LIB="${1:-$CACHE/online-library}"
OUT="${2:-$ROOT/docs/screenshots/sprint-7}"
WINDOW_RECT="30,40,1440,877"

say() { echo "german-shots: $1"; }
fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "german-shots: FAILED – $1" >&2
    exit 1
}

# Which language this script is written for. `app-language.sh` is shared by
# every window-driving script here.
. "$HERE/app-language.sh"

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – run Scripts/online-library.sh '$CACHE' first"
mkdir -p "$OUT"

PROBE=$(mktemp -t shelf-de).png
if ! screencapture -x "$PROBE" 2>/dev/null || [ ! -s "$PROBE" ]; then
    rm -f "$PROBE"
    fail "screencapture cannot read the display. Grant Screen Recording to this terminal."
fi
rm -f "$PROBE"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app)" || exit 1
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1
require_no_foreign_shelf

pin_app_language de

PID=""
start_shelf() { # [library path, or nothing for the welcome screen]
    if [ -n "${1:-}" ]; then
        open -a "$APP" "$1" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
    else
        open -a "$APP" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
    fi
    sleep 9
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
    [ -n "$PID" ] || return 0
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1
    sleep 3
    PID=""
}

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null; }
# `grep -c`, never `grep -q`: under `pipefail` a match closes the pipe and the
# status becomes 141, so a hit reads as a miss.
tree_has() {
    local n
    n=$(tree | grep -c "$1")
    [ "${n:-0}" -gt 0 ]
}
shoot() {
    front
    swift "$HERE/cursor-park.swift" 1500 8 >/dev/null 2>&1
    sleep 1.5
    screencapture -x -R "$WINDOW_RECT" "/tmp/german-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/german-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/german-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" ${2:-} 2>/dev/null) || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
# The menu titles are German now, which is the point: a script that still found
# "Library" would be proving the window had not been translated.
menu() {
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null 2>&1
}
key() { osascript -e "tell application \"System Events\" to keystroke \"$1\" using $2" >/dev/null 2>&1; }

# ── 1. the welcome screen ────────────────────────────────────────────────────
start_shelf
shoot "welcome-de"
quit_shelf

# ── 2. the library: grid, sidebar, inspector ─────────────────────────────────
start_shelf "$LIB"
tree_has "Alle Bücher" || say "WARNING: the sidebar does not say “Alle Bücher” – is the catalogue in the bundle?"
shoot "grid-de"

click cell 0 >/dev/null 2>&1
sleep 1.5
shoot "inspector-de"

# ── 3. the table ─────────────────────────────────────────────────────────────
key "2" "command down"
sleep 2
shoot "table-de"
key "1" "command down"
sleep 1.5

# ── 4. the shortcut sheet (⌘?) ───────────────────────────────────────────────
# Through the menu item, not the key. The shortcut is declared as ⌘/ and drawn
# as ⌘?, and a posted "?" with command held does not match it — the first run
# photographed the grid and called it the shortcut sheet.
menu "Hilfe" "Tastaturkurzbefehle"
sleep 2
# The groups are drawn in capitals, so the sheet's own title is what to
# look for — the first guard read "Bewegen" and missed "BEWEGEN".
tree_has "Tastaturkurzbefehle" || say "WARNING: the shortcut sheet did not open"
shoot "shortcuts-de"
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
sleep 1

# ── 5. the status bar and the sidebar counts, close up ───────────────────────
shoot "sidebar-de"

quit_shelf
say "done – $OUT"
