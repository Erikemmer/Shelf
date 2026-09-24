#!/bin/bash
# The accessibility evidence: the tree VoiceOver walks, one file per view, and
# a picture of each with the focus ring visible.
#
# It is not a dump. `Scripts/ax-judge.py` reads every tree and fails on three
# things: a control with no name, a name that is an SF Symbol's identifier
# ("book.closed"), and a view that does not hold the button it was told to hold.
# A dozen text files nobody compares are not evidence; a run that goes red is.
#
# What it cannot answer is on the report at the end: whether the *order* things
# are read in makes sense is a judgement, and it needs an ear.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
# It never ends a Shelf it did not start.
#
# Usage: Scripts/ax-proof.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="$HOME/Library/Caches/Shelf/measure-library-7b"
LIB="${1:-$CACHE/library}"
OUT="${2:-$ROOT/docs/accessibility}"
SHOTS="$ROOT/docs/screenshots/sprint-7"
WINDOW_RECT="30,40,1440,877"

say() { echo "ax-proof: $1"; }
fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "ax-proof: FAILED – $1" >&2
    exit 1
}

# Every menu name below is English, so the run says which language it is
# written for (Scripts/app-language.sh, Sprint 7).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – see docs/RUNBOOK.md for how to build one"
mkdir -p "$OUT" "$SHOTS"

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
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1
    sleep 2
    kill "$PID" >/dev/null 2>&1
}
trap 'cleanup; restore_app_language' EXIT

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null; }
tree_has() {
    local n
    n=$(tree | grep -c "$1")
    [ "${n:-0}" -gt 0 ]
}
# Every key and every menu click makes the window frontmost first. A posted
# keystroke goes to whatever is frontmost, and after a screenshot or a panel
# that is not reliably Shelf — one run lost the ⌘? sheet, the import sheet and
# the Calibre sheet to exactly this, and reported all three as "did not open".
key() {
    front
    sleep 0.4
    osascript -e "tell application \"System Events\" to keystroke \"$1\" using $2" >/dev/null 2>&1
}
plain_key() {
    front
    sleep 0.3
    osascript -e "tell application \"System Events\" to key code $1" >/dev/null 2>&1
}
# The same two, without making the window frontmost: an open panel is a window
# of this process, and asking the *process* to come forward makes the main
# window key again and takes the keystroke away from the panel. That is how
# two sheets were lost the first time `front` was added.
raw_key() {
    osascript -e "tell application \"System Events\" to keystroke \"$1\" using $2" >/dev/null 2>&1
}
raw_plain_key() {
    osascript -e "tell application \"System Events\" to key code $1" >/dev/null 2>&1
}

menu() {
    front
    sleep 0.6
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null 2>&1
}

# Polls until no sheet is up any more. Escape starts a sheet closing and does
# not finish it, and the next step's menu click lands on a window that is still
# modal — which is how the Calibre protocol was reported as "did not open"
# while it was simply next in a queue.
wait_for_no_sheet() {
    local waited=0
    while tree_has "AXSheet"; do
        waited=$((waited + 1))
        [ "$waited" -lt 15 ] || return 1
        sleep 1
    done
    sleep 0.5
    return 0
}

# Polls the tree until it holds `$1`, for up to `${2:-15}` seconds. A fixed
# sleep is a guess about a machine's speed; this is a question with an answer.
wait_for_tree() {
    local waited=0
    until tree_has "$1"; do
        waited=$((waited + 1))
        [ "$waited" -lt "${2:-15}" ] || return 1
        sleep 1
    done
    return 0
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" ${2:-} 2>/dev/null) || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
shoot() {
    front
    swift "$HERE/cursor-park.swift" 1500 8 >/dev/null 2>&1
    sleep 1.2
    screencapture -x -R "$WINDOW_RECT" "/tmp/ax-proof.png" || return 1
    sips -s format jpeg -s formatOptions 75 "/tmp/ax-proof.png" --out "$SHOTS/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/ax-proof.png
    say "$1.jpg ($(($(stat -f %z "$SHOTS/$1.jpg") / 1024)) KB)"
}

FAILURES=0
DUMPED=()
SKIPPED=()

# Dumps the tree into `$OUT/<name>.txt` and judges it. Everything after the
# name is handed to `ax-judge.py`, so a view can say what it must contain.
capture() { # name, then judge arguments
    local name="$1"
    shift
    front
    sleep 0.6
    tree > "$OUT/$name.txt"
    if [ ! -s "$OUT/$name.txt" ]; then
        SKIPPED+=("$name (the tree came back empty)")
        return 1
    fi
    # A dump whose first window is the system's Open panel is a dump of the
    # wrong thing, whatever the guard that led here believed.
    if head -1 "$OUT/$name.txt" | grep -q 'AXDialog] title="Open"'; then
        SKIPPED+=("$name (the open panel was still in front — nothing was written)")
        rm -f "$OUT/$name.txt"
        return 1
    fi
    if python3 "$HERE/ax-judge.py" "$OUT/$name.txt" "$@"; then
        DUMPED+=("$name")
    else
        DUMPED+=("$name")
        FAILURES=$((FAILURES + 1))
    fi
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

# ── 1. The grid, the sidebar and the inspector ───────────────────────────────
#
# One tree: the three columns are one window, and reading them apart would say
# nothing about the order they are read in, which is half the question.
capture "grid" \
    --expect-button "All Books" --expect-button "Unread" --expect-button "Fiction" \
    --expect "Search" --expect "Cover size" --expect "Covers"

# The focus ring, photographed. Tab moves the keyboard through the window's
# focusable things; the first stop after the grid is a sidebar row, which is the
# one that had no ring at all before SlateKit 0.4.0.
front
plain_key 48
sleep 0.5
plain_key 48
sleep 0.8
shoot "focus-ring-sidebar"

# ── 2. A book selected: the inspector filled in ──────────────────────────────
click cell 0 >/dev/null 2>&1
sleep 1.5
# The section headings are drawn in capitals, so that is what to look for —
# the same trap `tree_has "Bewegen"` fell into in Sprint 7.
capture "inspector" --expect "Title" --expect "Rating" --expect "Read" --expect "FORMATS"
front
plain_key 48
sleep 0.5
shoot "focus-ring-inspector"

# ── 3. The table ─────────────────────────────────────────────────────────────
key "2" "command down"
sleep 2
capture "table" --expect "Title" --expect "Author"
shoot "table-ax"
key "1" "command down"
sleep 1.5

# ── 4. The ⌘? sheet ──────────────────────────────────────────────────────────
#
# Through the menu item, not the key: the shortcut is declared ⌘/ and drawn ⌘?,
# and a posted "?" with command held does not match it.
menu "Help" "Keyboard Shortcuts"
if wait_for_tree "Keyboard Shortcuts"; then
    capture "sheet-shortcuts" --expect "Keyboard Shortcuts" --expect "Close"
    shoot "sheet-shortcuts"
else
    SKIPPED+=("sheet-shortcuts (the sheet did not open)")
fi
plain_key 53
wait_for_no_sheet

# ── 5. Find Orphaned Folders… ────────────────────────────────────────────────
menu "Library" "Find Orphaned Folders…"
if wait_for_tree "Orphaned" 25; then
    capture "sheet-orphans" --expect "Orphaned"
    shoot "sheet-orphans"
else
    SKIPPED+=("sheet-orphans (the sheet did not open)")
fi
plain_key 53
wait_for_no_sheet

# ── 6. Fetch Metadata ────────────────────────────────────────────────────────
#
# It asks two services over the network. The sheet is up long before either
# answers, which is all this needs — and it is also the state a person spends
# the most time looking at.
click cell 0 >/dev/null 2>&1
sleep 1
key "e" "command down"
if wait_for_tree "Fetch Metadata"; then
    capture "sheet-fetch-metadata" --expect "Fetch Metadata"
    shoot "sheet-fetch-metadata"
else
    SKIPPED+=("sheet-fetch-metadata (the sheet did not open)")
fi
plain_key 53
wait_for_no_sheet

# ── 7. The import sheet ──────────────────────────────────────────────────────
#
# Reached through the open panel, which is the only way in: nothing on the
# command line presents it, and a drop from the Finder cannot be posted. The
# panel is driven the way `Scripts/device-shot.sh` drives its own — ⇧⌘G, a
# path, ⏎ — which is the one route that has proved reliable here.
panel_windows() {
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to get name of every window" 2>/dev/null \
        | grep -c "Open" || true
}
choose_in_panel() { # a path
    local waited=0
    until [ "$(panel_windows)" -gt 0 ]; do
        waited=$((waited + 1))
        [ "$waited" -lt 30 ] || return 1
        sleep 1
    done
    sleep 1
    raw_key "g" "{command down, shift down}"
    sleep 1.5
    osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1
    sleep 1.5
    raw_plain_key 36
    sleep 1.5
    raw_plain_key 36
    # **Wait for the panel to go**, rather than sleeping and hoping. A dump
    # taken while it is still up is a dump of the panel — a system window with
    # unnamed buttons of its own — and the guard below it passed anyway,
    # because "Add Books" is also the toolbar button behind it. One run wrote
    # the Open panel into `sheet-import.txt` and reported four findings against
    # a view Shelf does not own.
    local waited=0
    until [ "$(panel_windows)" -eq 0 ]; do
        waited=$((waited + 1))
        [ "$waited" -lt 20 ] || return 1
        sleep 1
    done
    sleep 2
    return 0
}

SOURCE="$CACHE/source"
if [ -d "$SOURCE" ]; then
    menu "File" "Add Books…"
    if ! [ "$(panel_windows)" -gt 0 ]; then
        sleep 3
        menu "File" "Add Books…"
    fi
    if choose_in_panel "$SOURCE"; then
        # The **path that was chosen**, which the sheet prints and nothing else
        # in the window does. "Add Books" is also the toolbar button behind the
        # sheet, so a guard on that passed while the open panel was still up;
        # "Choose books or a folder" is only the sheet's *idle* phase and this
        # folder goes straight to a plan.
        if wait_for_tree "$SOURCE" 25; then
            capture "sheet-import" --expect "$SOURCE" --expect "Cancel"
            shoot "sheet-import"
        else
            SKIPPED+=("sheet-import (the sheet did not open after the panel)")
        fi
        plain_key 53
        wait_for_no_sheet
    else
        SKIPPED+=("sheet-import (the open panel never appeared)")
    fi
else
    SKIPPED+=("sheet-import (no folder of books at $SOURCE)")
fi

# ── 8. The Calibre import protocol ───────────────────────────────────────────
CALIBRE="$CACHE/calibre"
if [ -f "$CALIBRE/metadata.db" ]; then
    menu "File" "Import from Calibre…"
    if ! [ "$(panel_windows)" -gt 0 ]; then
        sleep 3
        menu "File" "Import from Calibre…"
    fi
    if choose_in_panel "$CALIBRE"; then
        # The heading of the counting protocol, drawn in capitals like every
        # section heading — and **not** the path: a Calibre import names the
        # library, not the folder it was chosen from, so a guard on the path
        # waited forty seconds for a sheet that was already open.
        if wait_for_tree "IN THE CALIBRE LIBRARY" 40; then
            capture "sheet-calibre" --expect "IN THE CALIBRE LIBRARY" --expect "Cancel"
            shoot "sheet-calibre"
        else
            SKIPPED+=("sheet-calibre (the sheet did not open after the panel)")
        fi
        plain_key 53
        wait_for_no_sheet
    else
        SKIPPED+=("sheet-calibre (the open panel never appeared)")
    fi
else
    SKIPPED+=("sheet-calibre (no Calibre library at $CALIBRE)")
fi

# ── 9. The three device sheets ───────────────────────────────────────────────
#
# The "reader" is a disk image (Scripts/device-images.sh). The sandbox does not
# let a sandboxed app list a mounted image's directory without the volume having
# been chosen in a panel, so the way in is `Device ▸ Treat Volume as Device`,
# exactly as in Sprint 5's screenshot run.
if [ "${AX_PROOF_DEVICES:-1}" = "1" ]; then
    "$HERE/device-images.sh" make "$CACHE/device-images" >/dev/null 2>&1
    if [ -d /Volumes/KINDLE ]; then
        front
        sleep 1
        osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    click (first menu item of (menu 1 of (first menu item of (menu 1 of menu bar item "Device" of menu bar 1) whose name is "Treat Volume as Device")) whose name is "Kindle…")
end tell
EOF
        if choose_in_panel "/Volumes/KINDLE"; then
            WAITED=0
            until tree_has "KINDLE,"; do
                WAITED=$((WAITED + 1))
                [ "$WAITED" -lt 30 ] || break
                sleep 1
            done
        fi
        if tree_has "KINDLE,"; then
            click cell 0 >/dev/null 2>&1
            sleep 1
            key "s" "{command down, shift down}"
            if wait_for_tree "Send to Device" 25; then
                capture "sheet-send-to-device" --expect "Send to Device"
                shoot "sheet-send-to-device"
            else
                SKIPPED+=("sheet-send-to-device (the sheet did not open)")
            fi
            plain_key 53
            wait_for_no_sheet

            menu "Device" "Show What Is on the Device…"
            if wait_for_tree "On “KINDLE”" 25; then
                capture "sheet-device-contents" --expect "KINDLE"
                shoot "sheet-device-contents"
            else
                SKIPPED+=("sheet-device-contents (the sheet did not open)")
            fi
            plain_key 53
            wait_for_no_sheet

            # The confirmation that names every file is **not** reached here,
            # and saying so is the point: it only exists once there is
            # something on the card to delete, and this run sends nothing —
            # a script that deleted from a device to photograph the dialogue
            # asking whether to delete from a device would be a strange thing
            # to have written. Its tree is in `docs/screenshots/sprint-5/`,
            # photographed by `Scripts/device-shot.sh` against a card with
            # books on it (ADR 0014).
            SKIPPED+=("sheet-delete-from-device (nothing was sent, so there is nothing to delete)")
        else
            SKIPPED+=("the three device sheets (the Kindle never reached the sidebar)")
        fi
        "$HERE/device-images.sh" unmount >/dev/null 2>&1
    else
        SKIPPED+=("the three device sheets (the disk images did not mount)")
    fi
else
    SKIPPED+=("the three device sheets (AX_PROOF_DEVICES=0)")
fi

# ── The report ───────────────────────────────────────────────────────────────
echo
say "trees written to $OUT: ${#DUMPED[@]}"
# DUMPED can genuinely be empty – every capture() call could fail before a
# single tree is judged (a run against a broken environment, say) – so this
# needs the form that survives that under set -u (Sprint 16, Teil F).
for name in ${DUMPED[@]+"${DUMPED[@]}"}; do echo "    $name"; done
if [ "${#SKIPPED[@]}" -gt 0 ]; then
    say "not reached, and why: ${#SKIPPED[@]}"
    # never empty under set -u: the "-gt 0" above already proved it, so
    # protecting the plain "${SKIPPED[@]}" too would claim a risk this
    # guard already ruled out.
    for note in "${SKIPPED[@]}"; do echo "    $note"; done
fi
echo
say "what this run cannot answer, and a person has to:"
echo "    - whether the order things are read in makes sense"
echo "    - whether a label says the useful thing rather than merely a thing"
echo "    - whether the focus ring is where the keyboard actually is"

if [ "$FAILURES" -gt 0 ]; then
    fail "$FAILURES view(s) have findings – see the lines above"
fi
say "ok – every tree named every control, and none of them announced a symbol's name"
