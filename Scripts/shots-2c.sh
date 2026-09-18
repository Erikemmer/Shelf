#!/bin/bash
# The Sprint 2c evidence at the window: four screenshots and two accessibility
# trees, of the things this sprint added.
#
# Separate from `Scripts/screenshots.sh`, which photographs the four screens
# Sprint 1 compares against Selector at a fixed size. This one arranges a
# library first — shelves with books on them, a table sorted by a column, a
# selection of several books — because a screenshot of an empty feature shows
# nothing.
#
# **It needs Screen Recording permission** (System Settings ▸ Privacy &
# Security ▸ Screen Recording) and Accessibility. Without the first,
# `screencapture` refuses and this stops and says so rather than writing empty
# files. It never ends a Shelf it did not start.
#
# Usage: Scripts/shots-2c.sh [library folder] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIBRARY="${1:-$HOME/Library/Caches/Shelf/measure-library-2c}"
OUT="${2:-$ROOT/docs/screenshots/sprint-2c}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
WIDTH="${SHOT_WIDTH:-1440}"
HEIGHT="${SHOT_HEIGHT:-900}"
MAX_BYTES=$((500 * 1024))

# Every failure here asks first whether the screen locked mid-run, because a
# locked screen makes the app look as though it stopped answering. The check
# is defined in screen-awake.sh, which is sourced below; `command -v` keeps
# this working if a failure happens before that line.
fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "shots-2c: FAILED – $1" >&2
    exit 1
}
say() { echo "shots-2c: $1"; }

mkdir -p "$OUT"

# ── Is anybody looking at this screen? ───────────────────────────────────────
# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
require_awake_screen "$@"

PROBE=$(mktemp -t shelf-shot).png
if ! screencapture -x "$PROBE" 2>/dev/null || [ ! -s "$PROBE" ]; then
    rm -f "$PROBE"
    fail "screencapture cannot read the display.
       Grant Screen Recording to this terminal in
       System Settings ▸ Privacy & Security ▸ Screen Recording,
       quit and reopen the terminal, then run this again."
fi
rm -f "$PROBE"

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
[ -d "$LIBRARY" ] || fail "'$LIBRARY' is not a folder"

# ── Arrange the library, before anything is launched ─────────────────────────
# Through `shelf-tool`, so the window opens on a library that already has
# something to show. A screenshot of an empty Shelves section is a screenshot of
# nothing.
say "arranging shelves in $(basename "$LIBRARY")"
# From a known view, not from whatever the library was last left in. The first
# run of this script photographed the table three times because `library.json`
# remembered `mode: table` and the ⌘1 that should have switched back never
# arrived — see `shoot`, which now refuses to write the same picture twice.
python3 - "$LIBRARY/.shelf/library.json" <<'RESET'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["view"] = {"mode": "grid", "order": {"field": "title", "ascending": True}}
path.write_text(json.dumps(data, indent=2))
RESET
(cd "$ROOT" && swift run --scratch-path "$SCRATCH" shelf-tool unshelve "$LIBRARY" >/dev/null 2>&1)
# Separated by `|`, not by spaces: a shelf path has spaces in it, and word
# splitting turned "Fiction/Science Fiction" into two arguments.
while IFS='|' read -r SHELF COUNT OFFSET; do
    [ -n "$SHELF" ] || continue
    (cd "$ROOT" && swift run --scratch-path "$SCRATCH" shelf-tool shelve "$LIBRARY" "$SHELF" "$COUNT" "$OFFSET" \
        >/dev/null 2>&1) || fail "could not put books on $SHELF"
done <<'SHELVES'
Fiction/Science Fiction|14|0
Fiction/Crime|9|14
Non-Fiction/History|7|23
To Read|11|30
SHELVES
say "  Fiction ▸ Science Fiction, Fiction ▸ Crime, Non-Fiction ▸ History, To Read"

# ── The instance ─────────────────────────────────────────────────────────────
if pgrep -x Shelf >/dev/null; then
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Shelf >/dev/null || break
        osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
        sleep 1
    done
    pgrep -x Shelf >/dev/null && fail "a Shelf instance will not quit – close whatever is open in it"
fi
open -a "$APP" "$LIBRARY" || fail "could not launch $APP"
sleep 9
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
resize() {
    front; sleep 0.6
    osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {$WIDTH, $HEIGHT}
end tell
EOF
    sleep 1
}
point() { swift "$HERE/cell-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null; }
click() { local p; p=$(point "$1" "${2:-0}") || return 1; swift "$HERE/click-at.swift" ${p% *} ${p#* }; }
shiftClick() {
    local p; p=$(point "$1" "${2:-0}") || return 1
    osascript -e 'tell application "System Events" to key down shift' >/dev/null 2>&1
    swift "$HERE/click-at.swift" ${p% *} ${p#* }
    osascript -e 'tell application "System Events" to key up shift' >/dev/null 2>&1
}
keys() { osascript -e "tell application \"System Events\" to keystroke \"$1\" using command down" >/dev/null 2>&1; }
tree() { swift "$HERE/ax-dump.swift" "$PID" 14 2>/dev/null; }

# `grep -c`, never `grep -q`, on the far side of a pipe from something that is
# still writing — the same trap `screen-awake.sh` documents for `ioreg`, and it
# was in four more places here.
#
# Every one of these scripts runs under `set -o pipefail`. `grep -q` stops at
# the first match, so the accessibility dump on the other side of the pipe gets
# SIGPIPE, the *pipeline* reports 141, and a successful match reads as a
# failure. Measured in bash, three runs out of three, against a tree that
# plainly contained the pattern:
#
#     tree | grep -q "AXOutlineRow"   ->  status 141
#     tree | grep -c "AXOutlineRow"   ->  status 0, count 120
#
# It hid for a whole run of screenshots as "⌘2 did not show the table". The
# table was there; the question could not be asked. It also hides depending on
# how much the producer had written when grep quit, which is why the same
# pattern of code passes in one place and fails in another.
#
# A first check of this ran in zsh, where it came back 0 and looked fine. The
# scripts are bash.
tree_has() {
    local count
    count=$(tree | grep -c "$1")
    [ "${count:-0}" -gt 0 ]
}

# The same, for a string already in hand — no pipe, so no trap, but one way of
# asking is better than two.
text_has() {
    case "$1" in (*"$2"*) return 0 ;; esac
    return 1
}

# Wait for the window to show something, rather than asking once and believing
# the answer. A fixed `sleep` is a guess about a machine's mood: the first run
# of this script with the screen awake read the tree 2.5 s after ⌘2 and found no
# table, and the very same ⌘2 sent by hand a moment later showed one with 120
# rows in it. The keystroke was not lost; the question was asked too early.
#
# Dumping the tree takes about a second on its own, so this is a handful of
# attempts rather than a tight loop.
#
#   await_tree <pattern> <seconds> <what was expected>
await_tree() {
    local pattern="$1" seconds="$2" what="$3" waited=0
    while [ "$waited" -lt "$seconds" ]; do
        tree_has "$pattern" && return 0
        sleep 1
        waited=$((waited + 1))
    done
    tree > "/tmp/shots-2c-tree-$$.txt" 2>&1
    fail "$what
       Waited ${seconds}s for something matching: $pattern
       What the window did show is in /tmp/shots-2c-tree-$$.txt"
}

# Every picture this script has taken, so the same one cannot be written twice
# under two names. Sprint 2b shipped a `sidebar.png` that was a byte-for-byte
# copy of `library.png`, because the scroll that was supposed to happen between
# them silently did not — and two identical files with different names are worse
# than one missing file, since nobody looks twice at a file that is there.
SEEN=""

shoot() {
    local name="$1"
    front; sleep 1
    local wid
    wid=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
    [ -n "$wid" ] || { echo "shots-2c: no window for pid $PID – skipping $name"; return 1; }
    screencapture -o -x -l "$wid" "$OUT/$name.png" || { echo "shots-2c: capture failed for $name"; return 1; }
    local digest
    digest=$(shasum "$OUT/$name.png" | cut -d" " -f1)
    case " $SEEN " in
        *" $digest "*)
            rm -f "$OUT/$name.png"
            fail "$name is byte for byte a picture already taken.
       The window did not change between two shots – a keystroke or a click did
       not arrive. Nothing was written."
            ;;
    esac
    SEEN="$SEEN $digest"

    local bytes
    bytes=$(stat -f %z "$OUT/$name.png")
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
        local quality jbytes=0
        for quality in 80 60 40; do
            sips -s format jpeg -s formatOptions "$quality" "$OUT/$name.png" --out "$OUT/$name.jpg" >/dev/null 2>&1
            jbytes=$(stat -f %z "$OUT/$name.jpg" 2>/dev/null || echo 0)
            [ "$jbytes" -le "$MAX_BYTES" ] && break
        done
        rm -f "$OUT/$name.png"
        say "$name.jpg ($((jbytes / 1024)) KB, quality $quality) – the PNG was $((bytes / 1024)) KB"
    else
        say "$name.png ($((bytes / 1024)) KB)"
    fi
}

resize
SIZE=$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to get size of window 1" 2>/dev/null)
[ -n "$SIZE" ] || fail "System Events cannot see the window – is Accessibility granted to this terminal?"
say "window size: $SIZE"

# The accessibility tree is what every step below reads; if it is not there,
# nothing that follows means anything. The first run of this script found it in
# a state where the application element contained only itself, and every lookup
# quietly answered nothing.
tree_has "AXWindow" || fail "the accessibility tree has no window in it – nothing below could be checked"

# ── 1: the sidebar, with nested shelves and their counts ─────────────────────
tree_has 'value="Science Fiction, 14 books"' || fail "the sidebar does not show the shelves"
shoot shelves

# ── 2: the table, sorted by a column ─────────────────────────────────────────
front; sleep 0.4
keys "2"
await_tree "AXOutlineRow" 15 "⌘2 did not show the table"
P=$(point "text=Author") || fail "the table has no Author column header"
swift "$HERE/click-at.swift" ${P% *} ${P#* }
await_tree 'value="Author ' 15 "clicking the Author header did not change the sort order"
shoot table
tree | grep -E "AXSortButton|AXOutlineRow" -A3 | head -40 > "$OUT/ax-table.txt"
{
    echo ""
    echo "The sort menu above the table, which reads the same BookOrder the"
    echo "header arrow does:"
    tree | grep "Sort order"
} >> "$OUT/ax-table.txt"
say "ax-table.txt"

# ── 3: several books selected, and the inspector saying Mixed ────────────────
front; sleep 0.4
keys "1"
await_tree "AXOpaqueProviderGrid" 15 "⌘1 did not show the grid"
click "cell" 0; sleep 0.8
shiftClick "cell" 7
await_tree "books selected" 15 "⇧-click did not extend the selection"
await_tree "Mixed" 15 "the inspector shows no Mixed value for the selection"
shoot selection
{
    echo "The inspector with several books selected."
    echo ""
    tree | sed -n '/books selected/,/FORMATS/p'
} > "$OUT/ax-selection.txt"
say "ax-selection.txt"

# ── 4: the context menu on a book ────────────────────────────────────────────
front; sleep 0.4
P=$(point "cell" 0) && swift "$HERE/click-at.swift" ${P% *} ${P#* } right
await_tree "Add to Shelf" 15 "the context menu did not open"
# The menu is its own window, so the whole screen is photographed rather than
# the app's window: a menu is drawn outside it.
screencapture -o -x "$OUT/menu-full.png" 2>/dev/null
sips -Z 1400 -s format jpeg -s formatOptions 60 "$OUT/menu-full.png" --out "$OUT/menu.jpg" >/dev/null 2>&1
rm -f "$OUT/menu-full.png"
say "menu.jpg ($(($(stat -f %z "$OUT/menu.jpg" 2>/dev/null || echo 0) / 1024)) KB)"
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1

# ── The shelf tree, as the accessibility tree has it ─────────────────────────
{
    echo "The Shelves section of the sidebar, as VoiceOver walks it."
    echo ""
    tree | sed -n '/value="SHELVES"/,/value="TAGS"/p' | head -20
} > "$OUT/ax-shelves.txt"
say "ax-shelves.txt"

say "done – $OUT"
