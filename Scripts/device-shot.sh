#!/bin/bash
# Sprint 5's evidence at the window: a reader in the sidebar with its free
# space, the transfer sheet choosing a format, the report, and the confirmation
# that names every file before anything is deleted from a device.
#
# The "readers" are disk images made by `Scripts/device-images.sh`, so this runs
# without hardware — and the four pictures are of the app, not of a mock: the
# app finds the volumes through NSWorkspace exactly as it would find a Kobo.
# What is *not* shown here is a real device being plugged in; that is in
# docs/BACKLOG.md under "To check on real hardware".
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
#
# It never ends a Shelf it did not start.
#
# Usage: Scripts/device-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="$HOME/Library/Caches/Shelf/measure-library-5"
LIB="${1:-$CACHE/device-library}"
OUT="${2:-$ROOT/docs/screenshots/sprint-5}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "device-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "device-shot: $1"; }

# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
require_awake_screen "$@"

[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – run the proof run first"
mkdir -p "$OUT"

# Fresh cards, so the transfer sheet has something to send.
"$HERE/device-images.sh" unmount >/dev/null 2>&1
for IMAGE in KOBOeReader Kindle tolino PocketBook; do
    rm -f "$CACHE/device-images/$IMAGE.dmg"
done
"$HERE/device-images.sh" make "$CACHE/device-images" >/dev/null 2>&1 || fail "could not make the disk images"
[ -d /Volumes/KINDLE ] || fail "the Kindle image did not mount"
say "four readers mounted"

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

open -a "$APP" "$LIB" || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 14 2>/dev/null; }
# `grep -c`, never `grep -q`: under `pipefail` a match closes the pipe and the
# status becomes 141, so a hit reads as a miss.
tree_has() {
    local n
    n=$(tree | grep -c "$1")
    [ "${n:-0}" -gt 0 ]
}
# The window's rectangle on screen, not its window id.
#
# `screencapture -l <id>` hands back the window's *backing store*, and for a
# SwiftUI `ScrollView` that store is not redrawn when the view scrolls: the
# sidebar shot came out showing the top of the list however far down the list
# had been scrolled, three runs in a row, while a full-screen capture taken a
# second later showed it correctly. `-R` photographs the screen, which is what
# a person sees.
#
# The window is put at a known place below, so the rectangle is known.
WINDOW_RECT="30,40,1440,877"
shoot() {
    front
    # Out of the way first: `-R` photographs the screen, so a pointer left over
    # a Dock icon puts that icon's tooltip in the picture. One shot came out
    # with exactly that across the bottom of the window.
    swift "$HERE/cursor-park.swift" 1500 8 >/dev/null 2>&1
    sleep 1.5
    screencapture -x -R "$WINDOW_RECT" "/tmp/device-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/device-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/device-shot.png
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
# A menu item whose title carries the device's name, which changes with the
# volume — so it is matched by its beginning rather than spelt out.
menu_starting() {
    osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set theMenu to menu 1 of menu bar item "$1" of menu bar 1
    repeat with anItem in menu items of theMenu
        if name of anItem starts with "$2" then
            click anItem
            return
        end if
    end repeat
    error "no item starting with $2"
end tell
EOF
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
sleep 2

# ── 0. Let the app into the volume ───────────────────────────────────────────
#
# The sandbox grants `files.removable-volumes` for real removable media and
# **not** for a mounted disk image: with the entitlement in place the app can
# read an image's name and free space and cannot list its directory, so a card
# with five books on it showed "0 books". Measured in Sprint 5, and the reason
# this step is here.
#
# Choosing the volume in an open panel is what the sandbox takes as permission,
# and `Device ▸ Treat Volume as Device ▸ Kindle…` is the route a person has for
# a reader Shelf does not recognise anyway. So these pictures are of the real
# feature, taken the long way round — and what has *not* been shown is a device
# detected by its marker and read without a panel. That needs hardware, and it
# is the first line of docs/BACKLOG.md's "To check on real hardware".
# The panel is a window of its own called "Open" (subrole AXDialog), so each
# step waits for the thing it needs instead of sleeping and hoping. The first
# version slept, and lost a run to a panel that took a second longer.
panel_windows() {
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to get name of every window" 2>/dev/null \
        | grep -c "Open" || true
}

front
sleep 1
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    click (first menu item of (menu 1 of (first menu item of (menu 1 of menu bar item "Device" of menu bar 1) whose name is "Treat Volume as Device")) whose name is "Kindle…")
end tell
EOF
WAITED=0
until [ "$(panel_windows)" -gt 0 ]; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 30 ] || fail "the Choose-a-volume panel never opened"
    sleep 1
done
say "the volume panel is up"
sleep 1
osascript -e 'tell application "System Events" to keystroke "g" using {command down, shift down}' >/dev/null 2>&1
sleep 2
osascript -e 'tell application "System Events" to keystroke "/Volumes/KINDLE"' >/dev/null 2>&1
sleep 2
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
sleep 2
osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1
WAITED=0
until [ "$(panel_windows)" -eq 0 ]; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 30 ] || fail "the volume panel never closed"
    sleep 1
done

WAITED=0
until tree_has "KINDLE,"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 40 ] || fail "the Kindle never appeared in the sidebar"
    sleep 1
done
say "the Kindle is in the sidebar"

# ── 1. The transfer sheet, choosing a format ─────────────────────────────────
#
# A Kindle, because it is the device that cannot take every book: the sheet has
# to show both the format it picked and the books it will not send.
front
sleep 0.5
# The menu item, not ⌘A. The shortcut goes to whatever has the keyboard, and
# after an open panel that is not the grid — the first run of this script
# selected one book and photographed a transfer sheet holding one book.
menu "Library" "Select All Books" || fail "there is no Library ▸ Select All Books item"
sleep 2
menu_starting "Device" "Send to" || fail "there is no Device ▸ Send to… item"
WAITED=0
until tree_has "cannot be sent" || tree_has "Nothing to send"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 60 ] || fail "the transfer plan never appeared"
    sleep 1
done
tree_has "Nothing to send" && fail "the plan is empty – the card already holds these books"
# A sheet holding one book is a picture of nothing. The whole point of this
# shot is a device choosing between formats and naming what it cannot take.
# `tree_has`, never `grep -q` on the pipe: under `pipefail` a match closes the
# pipe and the status becomes 141, so a hit reads as a miss. It caught this
# script out once, with the warning about it thirty lines above.
tree_has "cannot be sent" \
    || fail "the plan holds no book the Kindle cannot take – was everything selected?"
say "the transfer plan is up"
shoot devices-transfer-sheet
tree | sed -n '/AXSheet/,$p' | head -50 >"$OUT/ax-devices-transfer.txt"

# ── 3. The report ────────────────────────────────────────────────────────────
click "desc=Send" || fail "no Send button"
WAITED=0
until tree_has "Verified ·"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 300 ] || fail "the transfer never finished"
    sleep 1
done
say "the transfer finished"
shoot devices-report
tree | sed -n '/AXSheet/,$p' | head -40 >"$OUT/ax-devices-report.txt"
click "desc=Close"
sleep 3

# ── 3. The sidebar, with a reader on it ──────────────────────────────────────
#
# Taken *after* the transfer, so the row says how many books are on the card as
# well as how much room is left — which is what somebody looks at the row for.
#
# Devices is the last section, under Tags, Authors, Series and Formats, so on a
# library with a couple of hundred authors it starts below the fold. The sidebar
# is the window's left 260 pt, so its middle is about (160, 500).
# Scrolled until the row is really *on screen*, and checked by its position.
#
# `tree_has "free"` is not that check and looked like it: the accessibility
# tree lists the rows of a scroll view whether or not they are visible, so the
# first version of this passed while photographing the Tags section. A
# screenshot captioned "the sidebar with a device on it" that shows no device
# is worse than no screenshot.
# The sidebar's own scroll bar, which is the first one in the tree. A position
# read off an element does not work here: the accessibility API clamps the
# frame of a row that is scrolled out of view to the scroll area's own, so a
# row far below the fold reports a position inside the window and every check
# built on it passes while the picture shows the Tags section.
sidebar_scroll() { tree | grep -m1 "AXScrollBar" | sed -n 's/.*value="\([^"]*\)".*/\1/p'; }
for ATTEMPT in 1 2 3 4 5 6; do
    [ "$(sidebar_scroll)" = "1" ] && break
    swift "$HERE/scroll-at.swift" 160 500 -20 5 >/dev/null 2>&1
    sleep 1
done
[ "$(sidebar_scroll)" = "1" ] || fail "the sidebar never scrolled to the bottom"
tree_has "free" || fail "the device rows do not say how much room is left"
say "the sidebar is scrolled to the bottom, where the devices are"
shoot devices-sidebar
tree | grep -B1 -A3 "free" | head -30 >"$OUT/ax-devices-sidebar.txt"

# ── 4. The delete confirmation, naming every file ────────────────────────────
menu "Device" "Show What Is on the Device…" || fail "there is no Device ▸ Show What Is on the Device… item"
WAITED=0
until tree_has "On “"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 60 ] || fail "the device contents sheet never appeared"
    sleep 1
done
sleep 1
shoot devices-contents
# Tick a handful rather than all of them, so the confirmation's list is a list
# somebody can read in one picture.
#
# The checkboxes are ticked through the accessibility API rather than by
# clicking a computed point: the list scrolls, and a point worked out from the
# sheet's frame lands on whatever happens to be under it. `cell-point.swift`
# knows about grid covers and table rows and not about these.
TICKED=$(osascript <<EOF 2>/dev/null
tell application "System Events" to tell (first application process whose unix id is $PID)
    set boxes to every checkbox of scroll area 1 of group 1 of sheet 1 of window 1
    set n to 0
    repeat with aBox in boxes
        if n is 4 then exit repeat
        click aBox
        set n to n + 1
    end repeat
    return n
end tell
EOF
)
[ "${TICKED:-0}" -gt 0 ] || fail "could not tick anything in the device contents sheet"
say "ticked $TICKED files"
sleep 1
click "desc=Delete from Device…" || fail "no Delete from Device… button"
WAITED=0
until tree_has "Delete "; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 30 ] || fail "the delete confirmation never appeared"
    sleep 1
done
sleep 1
tree_has "library is not touched" || fail "the confirmation does not say the library is safe"
say "the confirmation is up, and it names the files"
shoot devices-delete-confirmation
tree | sed -n '/AXSheet/,$p' | head -50 >"$OUT/ax-devices-delete.txt"

# Nothing is deleted by this script: the picture is the point, and the
# behaviour behind it is measured in proof-run.sh section 11.
click "desc=Cancel" >/dev/null 2>&1

# Quit, not kill. macOS restores the windows an app had when it was *killed*,
# and a script that SIGTERMs it a dozen times leaves a saved state that brings
# them all back: `make smoke` went from "1 real window" to twelve, on the
# welcome screen, with nothing wrong with the app. A proper quit put it back to
# one. This one is Shelf's own process — the script started it — so ending it
# is this session's to do (CLAUDE.md), and ending it *properly* is the part
# that was learned here.
say "quitting the Shelf this script started"
osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
WAITED=0
while pgrep -x Shelf >/dev/null; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 15 ] || { kill "$PID" 2>/dev/null; break; }
    sleep 1
done
sleep 2
"$HERE/device-images.sh" unmount >/dev/null 2>&1
say "done – $OUT"
