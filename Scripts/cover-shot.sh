#!/bin/bash
# Drives the real window through every way of changing a cover, and
# photographs each one.
#
# The unit tests prove the *rules* — that the old file goes to the Trash, that
# the generation moves, that a rebuild reads it back. None of them can prove
# the thing this feature is actually about: that the picture in the window
# changes. The grid cell and the inspector each hold a decoded image and each
# decides for itself when to ask for another one, and **both of them were wrong
# about that** before this sprint: the grid's task key was book-and-size, and
# the counter the inspector was supposed to watch had no reader at all. So this
# script replaces a cover and then looks at the window, and checks every claim
# against the disk rather than believing the screenshot.
#
# It *writes* into the library it is given, which is why it refuses to start
# unless that library is under ~/Library/Caches/Shelf. It never touches a book
# file, and everything it displaces goes where the app puts it — the Trash.
#
# What it cannot do, and says so rather than pretending: `Download Cover…`
# needs a service to answer, and a synthetic book's title never will.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
#
# It runs in **either language**. `SHELF_SHOT_LANGUAGE=de` pins German and uses
# the German names; anything else is English. Every name this script types is
# in `name_of` below, so a script that drives menus says which language it is
# written for rather than discovering it at run time (the Sprint 7 lesson).
#
# Usage: Scripts/cover-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LANGUAGE="${SHELF_SHOT_LANGUAGE:-en}"
CACHE="$HOME/Library/Caches/Shelf/cover-library-9"
LIB="${1:-$CACHE/library}"
PICTURES="$CACHE/pictures"
DEFAULT_OUT="$ROOT/docs/screenshots/sprint-9"
[ "$LANGUAGE" = "en" ] || DEFAULT_OUT="$DEFAULT_OUT/de"
OUT="${2:-$DEFAULT_OUT}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "cover-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "cover-shot: $1"; }

# Every word this script types at a menu or looks for in the tree, in one
# place. A missing row is a loud failure rather than a silent miss, because a
# menu item asked for by the wrong name reads exactly like a menu item that is
# not there (Scripts/app-language.sh).
name_of() {
    if [ "$LANGUAGE" = "de" ]; then
        case "$1" in
            setCover) echo "Cover festlegen…" ;;
            takeCover) echo "Cover aus der Buchdatei holen" ;;
            download) echo "Cover herunterladen…" ;;
            coverMenu) echo "Das Cover von" ;;
            coverImage) echo "Cover von" ;;
            clearSearch) echo "Die Suche leeren" ;;
            missing) echo "Ohne Cover" ;;
            notAnImage) echo "kein Bild, das Shelf erkennt" ;;
            *) fail "no German name for '$1'" ;;
        esac
    else
        case "$1" in
            setCover) echo "Set Cover…" ;;
            takeCover) echo "Take Cover from Book File" ;;
            download) echo "Download Cover…" ;;
            coverMenu) echo "Change the cover of" ;;
            coverImage) echo "Cover of" ;;
            clearSearch) echo "Clear the search" ;;
            missing) echo "Missing Cover" ;;
            notAnImage) echo "not an image Shelf recognises" ;;
            *) fail "no English name for '$1'" ;;
        esac
    fi
}

. "$HERE/app-language.sh"
pin_app_language "$LANGUAGE"
. "$HERE/screen-awake.sh"
require_awake_screen "$@"

case "$LIB" in
    "$HOME/Library/Caches/Shelf/"*) ;;
    *) fail "this script replaces covers, so it only runs against a throw-away library
       under ~/Library/Caches/Shelf. Build one: Scripts/cover-library.sh" ;;
esac
[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index"
[ -f "$PICTURES/small.png" ] || fail "no test pictures – run Scripts/cover-library.sh"
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

if pgrep -x Shelf >/dev/null; then
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
    sleep 1
    for _ in 1 2 3 4 5; do
        pgrep -x Shelf >/dev/null || break
        osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
        sleep 1.5
    done
    pgrep -x Shelf >/dev/null && fail "a Shelf instance will not quit – close whatever is open in it"
fi

open -a "$APP" "$LIB" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 14 2>/dev/null; }
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
    screencapture -o -x -l "$wid" "/tmp/cover-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/cover-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/cover-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" 2>/dev/null) || return 1
    [ -n "$point" ] || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
# A pop-up NSMenu is not among the application's *windows*, so `cell-point`
# cannot see it at all. `menu-point` walks the application element instead.
click_menu_item() {
    local point
    point=$(swift "$HERE/menu-point.swift" "$PID" "$1" 2>/dev/null) || return 1
    [ -n "$point" ] || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
}
open_cover_menu() {
    click "desc=$(name_of coverMenu)" || fail "there is no cover menu under the picture"
    sleep 1.5
}

# Selecting a book by name. Clicking a *cell*, because that also puts the
# inspector's scroll position back at the top — and the cover menu is at the
# top of it.
#
# The search is emptied with its own button rather than with ⌘A and a
# keystroke: in a SwiftUI `TextField` the select-all does not take, so the new
# words land *after* the old ones. Measured, and it reads exactly like a book
# that is not in the library: "Long WayedLong Way" matched nothing.
select_book() {
    click "desc=$(name_of clearSearch)" >/dev/null 2>&1
    sleep 1
    click "search" || fail "no search field"
    sleep 0.5
    osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1
    sleep 2
    click "cell" || fail "the search for “$1” found no book"
    sleep 2
}

# What the book's folder holds right now, so the window's claim is checked
# against the disk rather than believed.
folder_of() { dirname "$(grep -rl "<dc:title>$1<" "$LIB" --include=metadata.opf 2>/dev/null | head -1)"; }
cover_of() { find "$1" -maxdepth 1 -name 'cover.*' 2>/dev/null | head -1; }
facts_of() {
    local file
    file=$(cover_of "$1")
    if [ -z "$file" ]; then
        echo "no cover"
        return
    fi
    echo "$(basename "$file") $(sips -g pixelWidth -g pixelHeight "$file" 2>/dev/null | awk '/pixel/ {printf "%sx", $2}' | sed 's/x$//') $(($(stat -f %z "$file") / 1024)) KB"
}
generation_of() {
    grep -o 'shelf:cover_generation" content="[0-9]*' "$1/metadata.opf" 2>/dev/null \
        | grep -o '[0-9]*$' || echo 0
}

front
sleep 0.8
osascript >/dev/null 2>&1 <<POSITION
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
POSITION
sleep 1

# ── 1. What the menu offers ──────────────────────────────────────────────────
# The book with four formats, so the format submenu is in the picture.
BOOK="The Ministry Called Peace #1"
select_book "Ministry Called"
FOLDER=$(folder_of "$BOOK")
[ -d "$FOLDER" ] || fail "no folder for “$BOOK” – is this the library cover-library.sh built?"
say "selected “$BOOK”: $(facts_of "$FOLDER"), generation $(generation_of "$FOLDER")"

open_cover_menu
shoot 1-cover-menu
click_menu_item "$(name_of takeCover)" || fail "no “$(name_of takeCover)” item"
sleep 1.5
shoot 2-format-submenu

# ── 2. Take Cover from Book File, from the PDF ───────────────────────────────
# A PDF's cover is page 1 rendered, which goes down a different reader from the
# EPUB the import took this book's cover from — so the picture must change.
BEFORE=$(facts_of "$FOLDER")
click_menu_item "PDF" || fail "the format submenu does not offer the PDF"
sleep 4
AFTER=$(facts_of "$FOLDER")
[ "$AFTER" != "$BEFORE" ] || fail "the cover on disk did not change
       before: $BEFORE
       after:  $AFTER"
say "from the PDF → $AFTER, generation $(generation_of "$FOLDER")"
shoot 3-from-book-file

# ── 3. Set Cover… from a file, and what the ceiling did to it ────────────────
# `huge.png` is 3 200 × 4 800. `CoverImageRule` brings it down to 1 600 on the
# long edge and writes it again as JPEG, which is what the check below asserts.
#
# The open panel is **invisible to accessibility**: it is a remote view hosted
# by com.apple.appkit.xpc.openAndSavePanelService, so it is in neither Shelf's
# window list nor the service's own. ⇧⌘G and a typed path is the only way to
# drive it, and the disk is the only way to know whether it worked.
BEFORE=$(facts_of "$FOLDER")
open_cover_menu
click_menu_item "$(name_of setCover)" || fail "no “$(name_of setCover)” item"
sleep 3
osascript >/dev/null 2>&1 <<PANEL
tell application "System Events"
    keystroke "g" using {shift down, command down}
    delay 1.5
    keystroke "$PICTURES/huge.png"
    delay 1.2
    keystroke return
    delay 1.5
    keystroke return
end tell
PANEL
sleep 5
AFTER=$(facts_of "$FOLDER")
[ "$AFTER" != "$BEFORE" ] || fail "the open panel did not deliver a cover
       before: $BEFORE
       after:  $AFTER"
case "$AFTER" in
    cover.jpg\ *x1600\ *) ;;
    *) fail "a 3200x4800 picture should have come down to 1600 on the long edge and been
       written again as JPEG. It is: $AFTER" ;;
esac
say "set from a 3200x4800 PNG → $AFTER, generation $(generation_of "$FOLDER")"
shoot 4-set-cover

# ── 4. Undo puts the picture back ────────────────────────────────────────────
front
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "z" using command down' >/dev/null 2>&1
sleep 4
UNDONE=$(facts_of "$FOLDER")
[ "$UNDONE" = "$BEFORE" ] || fail "undo did not restore the previous picture
       was:       $BEFORE
       came back: $UNDONE"
say "⌘Z → $UNDONE, generation $(generation_of "$FOLDER") (a generation counts up, never back)"
shoot 5-after-undo

# ── 5. Something that is not a picture ───────────────────────────────────────
# Refused before the old cover is touched, and the folder is left exactly as it
# was. Dragged rather than chosen, because that is how a wrong file arrives.
BEFORE=$(facts_of "$FOLDER")
osascript >/dev/null 2>&1 <<FINDERWINDOW
tell application "Finder"
    activate
    set target of front Finder window to (POSIX file "$PICTURES" as alias)
end tell
FINDERWINDOW
sleep 2
osascript >/dev/null 2>&1 <<'FINDERPLACE'
tell application "System Events" to tell process "Finder"
    set position of window 1 to {60, 500}
    delay 0.3
    set size of window 1 to {620, 380}
end tell
FINDERPLACE
sleep 1.5
FINDER=$(pgrep -x Finder | head -1)
TARGET=$(swift "$HERE/cell-point.swift" "$PID" "desc=$(name_of coverImage)" 2>/dev/null) \
    || fail "no cover image in the inspector to drop onto"
SOURCE=$(swift "$HERE/cell-point.swift" "$FINDER" "starts=not-a" 2>/dev/null) \
    || fail "not-a.txt is not visible in the Finder window"
swift "$HERE/drag-at.swift" ${SOURCE% *} ${SOURCE#* } ${TARGET% *} ${TARGET#* } 40
sleep 4
[ "$(facts_of "$FOLDER")" = "$BEFORE" ] || fail "dropping a text file changed the cover"
front
sleep 1
tree_has "$(name_of notAnImage)" || fail "nothing in the window says why the drop was refused"
say "a dropped text file was refused, and the window says so"
shoot 6-not-an-image

# ── 6. An image dragged in ───────────────────────────────────────────────────
BEFORE=$(facts_of "$FOLDER")
SOURCE=$(swift "$HERE/cell-point.swift" "$FINDER" "starts=small" 2>/dev/null) \
    || fail "small.png is not visible in the Finder window"
TARGET=$(swift "$HERE/cell-point.swift" "$PID" "desc=$(name_of coverImage)" 2>/dev/null)
swift "$HERE/drag-at.swift" ${SOURCE% *} ${SOURCE#* } ${TARGET% *} ${TARGET#* } 40
sleep 4
AFTER=$(facts_of "$FOLDER")
[ "$AFTER" != "$BEFORE" ] || fail "dropping a picture did not change the cover"
say "dropped small.png → $AFTER, generation $(generation_of "$FOLDER")"
shoot 7-dropped

# ── 7. The first cover on a book that had none, and undoing that ─────────────
# Undoing a *first* cover has to take the file away again: a folder that keeps
# the picture while the book says it has none is the worst of both.
COVERLESS="The Long Way Gods #1"
select_book "Long Way Gods"
EMPTY=$(folder_of "$COVERLESS")
[ -d "$EMPTY" ] || fail "no folder for “$COVERLESS”"
[ -z "$(cover_of "$EMPTY")" ] || fail "“$COVERLESS” already has a cover – rebuild the library"
MISSING_BEFORE=$(tree | grep -o "$(name_of missing), [0-9]*" | head -1)
open_cover_menu
click_menu_item "$(name_of takeCover)" || fail "no “$(name_of takeCover)” item"
sleep 4
[ -n "$(cover_of "$EMPTY")" ] || fail "the book still has no cover"
MISSING_AFTER=$(tree | grep -o "$(name_of missing), [0-9]*" | head -1)
[ "$MISSING_AFTER" != "$MISSING_BEFORE" ] || fail "the sidebar still says “$MISSING_BEFORE”"
say "first cover → $(facts_of "$EMPTY"); sidebar: $MISSING_BEFORE → $MISSING_AFTER"
shoot 8-first-cover

front
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "z" using command down' >/dev/null 2>&1
sleep 4
[ -z "$(cover_of "$EMPTY")" ] || fail "undoing the first cover left the file behind"
say "⌘Z took it away again, and the sidebar says $(tree | grep -o "$(name_of missing), [0-9]*" | head -1)"

# ── 8. The tree, for whoever reads the window without seeing it ──────────────
select_book "Ministry Called"
tree | grep -A 2 "$(name_of coverImage)" | head -12 >"$OUT/ax-inspector-cover.txt"
say "ax-inspector-cover.txt"

say "ok – $OUT"
say "not photographed here: Download Cover… needs a service to answer, which a"
say "synthetic book's title never will. Scripts/online-library.sh builds a"
say "library with real ISBNs for that one."
