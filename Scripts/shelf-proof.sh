#!/bin/bash
# Makes shelves in the real window, drags a book onto one, and then throws the
# index away to see whether the books are still on their shelves.
#
# This is ADR 0008's claim tested where it has to hold: not on a `Book` value in
# a unit test, but through a window, a real drag, a `metadata.opf` on disk, and
# a rebuild that has nothing but the folders and `library.json` to go on.
#
# What it checks, in order:
#   1. a shelf can be made and named from the sidebar
#   2. a shelf dragged onto another goes inside it
#   3. a book dragged onto a shelf lands on it – and it is the *book's own file*
#      that says so, read off the disk
#   4. the sidebar's count agrees with the file
#   5. the index can be deleted and rebuilt, and the book is back on its shelf
#   6. an empty shelf survives that, because `library.json` remembers it
#
# Needs Accessibility permission. It never ends a Shelf it did not start, and it
# writes only inside the library it is given.
#
# Usage: Scripts/shelf-proof.sh [library folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIBRARY="${1:-$HOME/Library/Caches/Shelf/measure-library-2c}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
INDEX="$LIBRARY/.shelf/library.sqlite"

# Every failure here asks first whether the screen locked mid-run, because a
# locked screen makes the app look as though it stopped answering. The check
# is defined in screen-awake.sh, which is sourced below; `command -v` keeps
# this working if a failure happens before that line.
fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "shelf-proof: FAILED – $1" >&2
    exit 1
}
say() { echo "shelf-proof: $1"; }

# A locked screen breaks everything below without failing any of it – see
# `screen-awake.sh`, which also holds the display awake for the run.
. "$HERE/screen-awake.sh"
require_awake_screen "$@"

[ -f "$INDEX" ] || fail "'$LIBRARY' holds no index – import a library there first"

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

quit_shelf() {
    pgrep -x Shelf >/dev/null || return 0
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Shelf >/dev/null || return 0
        osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
        sleep 1
    done
    fail "a Shelf instance will not quit – close whatever is open in it"
}

quit_shelf
open -a "$APP" "$LIBRARY" || fail "could not launch $APP"
sleep 9
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID, library $(basename "$LIBRARY")"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
point() { swift "$HERE/cell-point.swift" "$PID" "$1" "${2:-0}" 2>/dev/null; }
click() { local p; p=$(point "$1" "${2:-0}") || return 1; swift "$HERE/click-at.swift" ${p% *} ${p#* }; }
rightClick() {
    local p; p=$(point "$1" "${2:-0}") || return 1
    swift "$HERE/click-at.swift" ${p% *} ${p#* } right
}
drag() {
    local a b
    a=$(point "$1" "${3:-0}") || return 1
    b=$(point "$2" "${4:-0}") || return 1
    swift "$HERE/drag-at.swift" ${a% *} ${a#* } ${b% *} ${b#* }
}
type_text() { osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1; }
enter() { osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1; }
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

# Typed one character at a time. `keystroke "Fiction"` sends the whole word at
# once and the first letters land before the new row's text field has taken
# focus – the shelf came out called "Fictin". A person types slower than
# AppleScript does.
slow_type() {
    osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
    repeat with c in characters of "$1"
        keystroke c
        delay 0.06
    end repeat
end tell
EOF
}

select_all() { osascript -e 'tell application "System Events" to keystroke "a" using command down' >/dev/null 2>&1; }

make_shelf() {
    front; sleep 0.4
    click "desc=New shelf" || fail "no + button in the Shelves heading"
    # Long enough for the row to become a text field and for that field to take
    # focus, which happens a run loop turn later on purpose (see ShelvesSection).
    sleep 2
    # The field comes up holding "New Shelf"; select it so the typing replaces
    # it rather than being appended to it.
    select_all; sleep 0.3
    slow_type "$1"; enter; sleep 1.5
    tree_has "\"$1, [0-9]* book" || fail "the shelf was not named $1 – the sidebar says:
       $(tree | grep -o 'value="[^"]*, [0-9]* books"' | tr '\n' ' ')"
    say "made a shelf: $1"
}

# ── 1: three shelves ──────────────────────────────────────────────────────────
make_shelf "Fiction"
make_shelf "Sci-Fi"
make_shelf "Someday"

# ── 2: one dragged inside another ────────────────────────────────────────────
front; sleep 0.4
drag "desc=Show Sci-Fi —" "desc=Show Fiction —" || fail "could not drag Sci-Fi onto Fiction"
sleep 1.5
tree_has 'help="Show Fiction/Sci-Fi' \
    || fail "Sci-Fi did not go inside Fiction (the tree still shows it at the top)"
say "dragged Sci-Fi inside Fiction"

# ── 3: a book dragged onto a shelf ───────────────────────────────────────────
front; sleep 0.4
# Its help text now names the *path*, because it is inside Fiction. That change
# is itself part of what step 2 proved.
drag "cell" "desc=Show Fiction/Sci-Fi —" || fail "could not drag a book onto Fiction/Sci-Fi"
sleep 2
say "dragged the first book in the grid onto Fiction/Sci-Fi"

# The book's own file is the evidence, not the window.
OPF=$(grep -rl "shelf:shelves" "$LIBRARY" --include=metadata.opf 2>/dev/null | head -1)
[ -n "$OPF" ] || fail "no metadata.opf in the library carries a shelf:shelves"
grep -q 'shelf:shelves" content="\[&quot;Fiction/Sci-Fi&quot;\]"' "$OPF" \
    || fail "the OPF does not say Fiction/Sci-Fi: $(grep -o 'shelf:shelves[^/]*' "$OPF")"
say "the book's own metadata.opf says Fiction/Sci-Fi"
say "  ${OPF#"$LIBRARY"/}"

# ── 4: the sidebar agrees with the file ──────────────────────────────────────
# Matched without naming the attribute: a shelf with children comes out of the
# accessibility tree as a button carrying its label in `desc`, and one without
# as static text carrying it in `value`.
tree_has '"Sci-Fi, 1 book"' || fail "the sidebar does not count the book on Sci-Fi"
tree_has '"Fiction, 1 book"' \
    || fail "Fiction does not count the book on the shelf inside it"
say "the sidebar counts 1 on Sci-Fi and 1 on Fiction, which contains it"

# ── 5: removing a shelf takes the grouping, never the books ──────────────────
BOOKS_BEFORE=$(sqlite3 "$INDEX" "SELECT COUNT(*) FROM books")
front; sleep 0.4
rightClick "desc=Show Fiction —" || fail "could not open the menu on Fiction"
sleep 1
click "text=Remove Shelf…" || fail "the menu has no Remove Shelf… item"
sleep 1
# The confirmation has to name the shelf and how many books come off it.
QUESTION=$(tree | grep -o 'value="Remove “[^"]*"' | head -1)
text_has "$QUESTION" "Fiction" || fail "the confirmation does not name the shelf: $QUESTION"
[ "$(printf '%s' "$QUESTION" | grep -cE 'One book|[0-9]+ books')" -gt 0 ] \
    || fail "the confirmation does not say how many books come off: $QUESTION"
say "the confirmation says: $(echo "$QUESTION" | sed 's/^value="//; s/"$//')"
click "desc=Remove Shelf" || fail "could not confirm the removal"
sleep 2
BOOKS_AFTER=$(sqlite3 "$INDEX" "SELECT COUNT(*) FROM books")
[ "$BOOKS_BEFORE" = "$BOOKS_AFTER" ] || fail "removing a shelf changed the number of books:
       $BOOKS_BEFORE before, $BOOKS_AFTER after"
say "removed Fiction and the shelf inside it; the library still holds $BOOKS_AFTER books"

# And the book it held is out of the shelf in its own file, not only in the
# index – which is the half a rebuild would otherwise put straight back.
grep -q 'shelf:shelves' "$OPF" && fail "the book's OPF still names a shelf that is gone"
say "the book's metadata.opf no longer names a shelf"

# ── 6: throw the index away ─────────────────────────────────────────────────
# Someday is still there and still empty, which is the interesting case: no book
# remembers it, so only `library.json` can.
quit_shelf
BEFORE_BYTES=$(stat -f %z "$INDEX")
rm -f "$INDEX" "$INDEX-wal" "$INDEX-shm"
say "deleted the index ($((BEFORE_BYTES / 1024)) KB) – only the folders and library.json are left"

(cd "$ROOT" && swift run --scratch-path "$SCRATCH" shelf-tool rebuild "$LIBRARY" 2>&1) | sed 's/^/  /'

[ "$(sqlite3 "$INDEX" "SELECT COUNT(*) FROM shelves WHERE name = 'Someday'")" = "1" ] \
    || fail "the empty shelf did not survive the rebuild"
REBUILT_BOOKS=$(sqlite3 "$INDEX" "SELECT COUNT(*) FROM books")
[ "$REBUILT_BOOKS" = "$BOOKS_AFTER" ] || fail "the rebuild found $REBUILT_BOOKS books, not $BOOKS_AFTER"
say "after the rebuild: $REBUILT_BOOKS books, and the empty shelf is still there"

# Leave the library as it was found, so the script can be run again.
(cd "$ROOT" && swift run --scratch-path "$SCRATCH" shelf-tool unshelve "$LIBRARY" >/dev/null 2>&1) \
    || say "note – could not tidy the proof shelves away; remove them by hand before running again"
say "ok"
