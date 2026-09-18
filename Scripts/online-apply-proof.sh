#!/bin/bash
# The claim Sprint 6 rests on, measured at the window rather than asserted:
#
#   a field taken over from the net is written to `metadata.opf` and to the
#   index, the **book file is not touched**, and ⌘Z puts it back exactly.
#
# It drives the real app against the live services, reads the files off the
# disk before and after, and compares. Nothing is mocked and nothing is
# inspected through the app's own eyes.
#
# Needs the network, Accessibility, and an unlocked screen.
# It never ends a Shelf it did not start.
#
# Usage: Scripts/online-apply-proof.sh [library]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HOME/Library/Caches/Shelf/measure-library-6"
LIB="${1:-$CACHE/online-library}"
TITLE="Clean Code"

fail() { echo "online-apply-proof: FAILED – $1" >&2; exit 1; }
say() { echo "online-apply-proof: $1"; }

. "$HERE/screen-awake.sh"
require_awake_screen "$@"
[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – run Scripts/online-library.sh first"

FOLDER=$(grep -rl "<dc:title>$TITLE</dc:title>" "$LIB" --include=metadata.opf | head -1)
[ -n "$FOLDER" ] || fail "no book called “$TITLE” in $LIB"
FOLDER=$(dirname "$FOLDER")
OPF="$FOLDER/metadata.opf"
BOOK=$(find "$FOLDER" -name '*.epub' | head -1)
[ -n "$BOOK" ] || fail "no EPUB in $FOLDER"

say "book:  $(basename "$FOLDER")"
BOOK_BEFORE=$(shasum -a 256 "$BOOK" | cut -d' ' -f1)
OPF_BEFORE=$(shasum -a 256 "$OPF" | cut -d' ' -f1)
DATE_BEFORE=$(grep -c "<dc:date>" "$OPF")
say "epub before: $BOOK_BEFORE"
say "opf  before: $OPF_BEFORE · <dc:date> elements: $DATE_BEFORE"
[ "$DATE_BEFORE" = "0" ] || fail "the book already has a date – the proof needs an empty field to fill"

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
pgrep -x Shelf >/dev/null && fail "a Shelf is already running – close it yourself, then run this again"

open -a "$APP" "$LIB" || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() { osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1; }
tree() { swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null; }
tree_has() { local n; n=$(tree | grep -c "$1"); [ "${n:-0}" -gt 0 ]; }
menu() { osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu item \"$2\" of menu 1 of menu bar item \"$1\" of menu bar 1" >/dev/null 2>&1; }
click() { local p; p=$(swift "$HERE/cell-point.swift" "$PID" "$1" ${2:-} 2>/dev/null) || return 1; swift "$HERE/click-at.swift" ${p% *} ${p#* }; }
wait_for() { local w=0; until tree_has "$1"; do w=$((w+1)); [ "$w" -lt "$2" ] || return 1; sleep 1; done; }
quit_shelf() {
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to key code 53" >/dev/null 2>&1
    sleep 1
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1
    sleep 3
}

front
sleep 1
# ⌘F rather than a click on the field, and a retry rather than one attempt: a
# click can land before the window has the keyboard, and the grid needs a moment
# to narrow to one book.
menu "Library" "Search"
sleep 1
osascript -e "tell application \"System Events\" to keystroke \"a\" using command down" >/dev/null 2>&1
sleep 0.3
osascript -e "tell application \"System Events\" to keystroke \"$TITLE\"" >/dev/null 2>&1
sleep 3
WAITED=0
until click cell 0 2>/dev/null; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 8 ] || { quit_shelf; fail "could not select “$TITLE” in the grid"; }
    sleep 1
done
sleep 1

front
menu "File" "Fetch Metadata…"
wait_for "Take over" 60 || { quit_shelf; fail "no candidate came back – the services may be refusing"; }
say "the comparison is up"

# **Nothing is ticked**, and that is the point being proved as much as the write
# is: the only line that fills a gap here is the date, and it comes from a
# work-level record, which is never pre-ticked (ADR 0015). So this ticks it, the
# way a person would, and only then applies.
click "desc=Take over Published" || { quit_shelf; fail "no Published line in the comparison"; }
sleep 1
# The button's title lands in the accessibility *description*, not in AXTitle —
# SwiftUI puts a `Button("…")`'s label there. `desc=` is the prefix match, and
# the title carries a count ("Apply 1 field") that a script cannot know.
click "desc=Apply" || { quit_shelf; fail "could not find the Apply button"; }
sleep 3
osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1
sleep 2

BOOK_AFTER=$(shasum -a 256 "$BOOK" | cut -d' ' -f1)
OPF_AFTER=$(shasum -a 256 "$OPF" | cut -d' ' -f1)
DATE_AFTER=$(grep -c "<dc:date>" "$OPF")
say "epub after:  $BOOK_AFTER"
say "opf  after:  $OPF_AFTER · <dc:date> elements: $DATE_AFTER"

[ "$BOOK_BEFORE" = "$BOOK_AFTER" ] || { quit_shelf; fail "THE BOOK FILE CHANGED"; }
say "the book file is unchanged, byte for byte ✓"
[ "$OPF_BEFORE" != "$OPF_AFTER" ] || { quit_shelf; fail "metadata.opf did not change – nothing was applied"; }
[ "$DATE_AFTER" = "1" ] || { quit_shelf; fail "expected one <dc:date>, found $DATE_AFTER"; }
say "metadata.opf gained the date: $(grep -o '<dc:date>[^<]*</dc:date>' "$OPF") ✓"

# What ⌘Z is about to undo, in the Edit menu's own words.
#
# The menu has to be **opened** first: macOS updates an item's title when its
# menu is shown, so reading it cold gives the title from the last time it was
# drawn — a bare "Undo", which reads exactly like "nothing is registered" and
# was mistaken for that once.
front
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    click menu bar item "Edit" of menu bar 1
end tell
EOF
sleep 1
UNDO=$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to get name of menu item 1 of menu 1 of menu bar item \"Edit\" of menu bar 1" 2>/dev/null)
osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1
sleep 1
say "the Edit menu offers: $UNDO"
osascript -e "tell application \"System Events\" to keystroke \"z\" using command down" >/dev/null 2>&1
sleep 3

OPF_UNDONE=$(shasum -a 256 "$OPF" | cut -d' ' -f1)
DATE_UNDONE=$(grep -c "<dc:date>" "$OPF")
say "opf  undone: $OPF_UNDONE · <dc:date> elements: $DATE_UNDONE"
[ "$DATE_UNDONE" = "0" ] || { quit_shelf; fail "UNDO DID NOT REMOVE THE DATE"; }
say "⌘Z put the field back ✓"
# The OPF's own modification stamp moves with every write, so the file is not
# expected to be byte-identical again — the *field* is what undo restores, and
# that is what is checked above. Said out loud so the next reader does not add
# a digest comparison here and watch it fail for the right reason.
[ "$OPF_UNDONE" = "$OPF_BEFORE" ] && say "and the file is byte-identical as well"

quit_shelf
say "done"
