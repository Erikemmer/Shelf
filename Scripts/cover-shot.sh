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
# `Download Cover…` needs a service to answer, and a synthetic book's title
# never will. `SHELF_ONLINE_LIBRARY` names a second library whose books carry
# real ISBNs (`Scripts/online-library.sh` builds one); without it that stage is
# **skipped and said to be skipped**, rather than quietly missing.
#
# Needs Screen Recording and Accessibility, and an unlocked screen.
#
# It runs in **either language**. `SHELF_SHOT_LANGUAGE=de` pins German and uses
# the German names; anything else is English. Every name this script types is
# in `name_of` below, so a script that drives menus says which language it is
# written for rather than discovering it at run time (the Sprint 7 lesson).
#
# Usage: Scripts/cover-shot.sh [library] [output folder]
#        SHELF_SHOT_LANGUAGE=de SHELF_ONLINE_LIBRARY=… Scripts/cover-shot.sh
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
ONLINE="${SHELF_ONLINE_LIBRARY:-$CACHE/online-library}"

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
            edit) echo "Bearbeiten" ;;
            setCover) echo "Cover festlegen…" ;;
            takeCover) echo "Cover aus der Buchdatei holen" ;;
            download) echo "Cover herunterladen…" ;;
            coverMenu) echo "Das Cover von" ;;
            coverImage) echo "Cover von" ;;
            clearSearch) echo "Suche leeren" ;;
            searchField) echo "Suchen" ;;
            missing) echo "Ohne Cover" ;;
            notAnImage) echo "kein Bild, das Shelf erkennt" ;;
            replace) echo "Cover ersetzen" ;;
            cancel) echo "Abbrechen" ;;
            *) fail "no German name for '$1'" ;;
        esac
    else
        case "$1" in
            edit) echo "Edit" ;;
            setCover) echo "Set Cover…" ;;
            takeCover) echo "Take Cover from Book File" ;;
            download) echo "Download Cover…" ;;
            coverMenu) echo "Change the cover of" ;;
            coverImage) echo "Cover of" ;;
            clearSearch) echo "Clear the search" ;;
            searchField) echo "Search" ;;
            missing) echo "Missing Cover" ;;
            notAnImage) echo "not an image Shelf recognises" ;;
            replace) echo "Replace Cover" ;;
            cancel) echo "Cancel" ;;
            *) fail "no English name for '$1'" ;;
        esac
    fi
}

. "$HERE/app-language.sh"
pin_app_language "$LANGUAGE"
. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
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

# Only ever the instance this run's own $PID names — never rediscovered by
# `pgrep -x Shelf`, which by the time this fires could be a *different* Shelf
# if something else was started in between. Runs on every exit, including a
# `fail` partway through, so a run that stops early does not leave its own
# instance behind for the next run's `require_no_foreign_shelf` to trip over.
cleanup() {
    [ -n "${PID:-}" ] || return
    osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
    sleep 2
    kill -0 "$PID" 2>/dev/null && kill "$PID" 2>/dev/null
}
trap 'cleanup; restore_app_language' EXIT

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
# The same, cropped to a rectangle of the window.
#
# **Only the open panel needs this, and the reason is a rule rather than
# taste.** A sandboxed open panel draws the *machine's* Favorites down its left
# side — Downloads, Desktop, and whatever folders this particular Mac has been
# told to keep there. One of them on this Mac carries the former company name,
# and CLAUDE.md says that name appears nowhere in this project. Cropping is the
# only reliable answer: the panel is a remote view, so its sidebar cannot be
# collapsed from here, and it is invisible to accessibility so its parts cannot
# be located and blanked.
#
# The offsets are fixed because the window is: `place_window` puts it at
# (30, 40) at 1440 × 877 before anything is photographed.
shoot_cropped() {
    front
    sleep 1.5
    local wid
    wid=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
    [ -n "$wid" ] || fail "no window to photograph"
    screencapture -o -x -l "$wid" "/tmp/cover-shot.png" || fail "capture failed for $1"
    sips --cropOffset "$3" "$2" -c "$5" "$4" "/tmp/cover-shot.png" --out "/tmp/cover-crop.png" >/dev/null 2>&1 \
        || fail "could not crop $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/cover-crop.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/cover-shot.png /tmp/cover-crop.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB, cropped past the panel's Favorites)"
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

# Dragging a file out of the Finder onto the cover in the inspector.
#
# **The Finder has to be brought forward first, every time.** Shelf's window is
# 1440 × 877 at (30, 40) and the Finder's is inside that rectangle, so once
# anything calls `front` the Finder window is *behind* Shelf. `cell-point` goes
# on reporting the file's coordinates perfectly happily — the accessibility API
# does not care what is on top — and the drag then starts on whatever part of
# Shelf is at that point. Nothing fails; the cover simply does not change, and
# the reason is invisible. The second drop in this run did exactly that.
drag_onto_cover() {
    osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1
    sleep 1.5
    local source target
    source=$(swift "$HERE/cell-point.swift" "$FINDER" "starts=$1" 2>/dev/null) \
        || fail "$1… is not visible in the Finder window"
    target=$(swift "$HERE/cell-point.swift" "$PID" "desc=$(name_of coverImage)" 2>/dev/null) \
        || fail "no cover image in the inspector to drop onto"
    swift "$HERE/drag-at.swift" ${source% *} ${source#* } ${target% *} ${target#* } 40
    sleep 4
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
    # `desc=`, not `cell-point`'s own "search": that case matches the English
    # help text ("Search titles…") and finds nothing in a German window, which
    # is the Sprint 7 lesson in a shared tool rather than in this script.
    click "desc=$(name_of searchField)" || fail "no search field"
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

# Quitting and starting again, which two of the stages need: the restart shot,
# and the switch to the library whose books have real ISBNs. Only ever a Shelf
# this script started — the guard at the top refuses to run at all if one was
# already open.
relaunch_on() {
    osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
    for _ in 1 2 3 4 5; do
        pgrep -x Shelf >/dev/null || break
        sleep 1.5
    done
    open -a "$APP" "$1" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP on $1"
    sleep 11
    PID=$(pgrep -x Shelf | head -1)
    [ -n "$PID" ] || fail "Shelf did not start on $1"
    place_window
}
place_window() {
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
[ -d "$FOLDER" ] || fail "no folder for “${BOOK}” – is this the library cover-library.sh built?"
say "selected “${BOOK}”: $(facts_of "$FOLDER"), generation $(generation_of "$FOLDER")"

open_cover_menu
shoot 1-cover-before
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
# ⇧⌘G, the path, and **one** Return: that navigates to the file and selects it,
# which is the state worth photographing. The second Return opens it.
#
# Photographed only after the path has been typed, never before: the panel
# opens on wherever the person last was, and this Mac's last place is a real
# eBook library whose folder names are nobody's business but Erik's.
osascript >/dev/null 2>&1 <<PANEL
tell application "System Events"
    keystroke "g" using {shift down, command down}
    delay 1.5
    keystroke "$PICTURES/huge.png"
    delay 1.2
    keystroke return
end tell
PANEL
sleep 3
# x y width height, in the captured image's own pixels.
shoot_cropped 4-file-panel 900 420 1430 900
osascript -e 'tell application "System Events" to keystroke return' >/dev/null 2>&1
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
shoot 5-cover-after

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
shoot 6-after-undo

# ── 4a. ⇧⌘Z puts it forward again ─────────────────────────────────────────────
# Not obvious from the picture alone that this ever worked: a redo that lands
# on the *undo* stack instead of the redo stack looks, from a screenshot,
# exactly like a redo that landed on the redo stack — the picture comes back
# either way. What actually distinguishes them is the Edit menu (captured
# below) and a second round trip, which a wrongly-registered redo fails
# differently. Trash count is read through Finder because `ls ~/.Trash`
# cannot: TCC hides its contents from a plain directory read.
TRASH_BEFORE=$(osascript -e 'tell application "Finder" to return count of items of trash' 2>/dev/null)
front
sleep 0.5
osascript -e 'tell application "System Events" to keystroke "z" using {command down, shift down}' >/dev/null 2>&1
sleep 4
REDONE=$(facts_of "$FOLDER")
[ "$REDONE" = "$AFTER" ] || fail "redo did not restore the picture that was undone
       expected: $AFTER
       came back: $REDONE"
say "⇧⌘Z → $REDONE, generation $(generation_of "$FOLDER")"
shoot 13-after-redo
TRASH_AFTER=$(osascript -e 'tell application "Finder" to return count of items of trash' 2>/dev/null)
say "Trash: $TRASH_BEFORE → $TRASH_AFTER items (undo and redo each displace a file; neither one is ever removeItem)"
# The Edit menu itself, cropped, so "Undo Cover" (not "Redo") after a redo is
# on the record rather than only asserted in prose.
front
sleep 0.3
EDIT_NAME="$(name_of edit)"
EDIT_POS=$(osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to return position of menu bar item \"$EDIT_NAME\" of menu bar 1" 2>/dev/null)
if [ -n "$EDIT_POS" ]; then
    EX=$(echo "$EDIT_POS" | cut -d, -f1 | tr -d ' ')
    EY=$(echo "$EDIT_POS" | cut -d, -f2 | tr -d ' ')
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to click menu bar item \"$EDIT_NAME\" of menu bar 1" >/dev/null 2>&1
    sleep 1.2
    screencapture -o -x -R "$EX,$((EY + 20)),320,90" "/tmp/cover-shot-edit.png" 2>/dev/null
    sips -s format jpeg -s formatOptions 75 "/tmp/cover-shot-edit.png" --out "$OUT/13-edit-menu.jpg" >/dev/null 2>&1
    rm -f /tmp/cover-shot-edit.png
    osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
    say "13-edit-menu.jpg — the Edit menu right after ⇧⌘Z"
fi

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
drag_onto_cover "not-a"
[ "$(facts_of "$FOLDER")" = "$BEFORE" ] || fail "dropping a text file changed the cover"
front
sleep 1
tree_has "$(name_of notAnImage)" || fail "nothing in the window says why the drop was refused"
say "a dropped text file was refused, and the window says so"
shoot 7-not-an-image

# ── 6. An image dragged in ───────────────────────────────────────────────────
BEFORE=$(facts_of "$FOLDER")
drag_onto_cover "small"
AFTER=$(facts_of "$FOLDER")
[ "$AFTER" != "$BEFORE" ] || fail "dropping a picture did not change the cover"
say "dropped small.png → $AFTER, generation $(generation_of "$FOLDER")"
shoot 8-dropped

# ── 7. The first cover on a book that had none, and undoing that ─────────────
# Undoing a *first* cover has to take the file away again: a folder that keeps
# the picture while the book says it has none is the worst of both.
COVERLESS="The Long Way Gods #1"
select_book "Long Way Gods"
EMPTY=$(folder_of "$COVERLESS")
[ -d "$EMPTY" ] || fail "no folder for “${COVERLESS}”"
[ -z "$(cover_of "$EMPTY")" ] || fail "“${COVERLESS}” already has a cover – rebuild the library"
MISSING_BEFORE=$(tree | grep -o "$(name_of missing), [0-9]*" | head -1)
open_cover_menu
click_menu_item "$(name_of takeCover)" || fail "no “$(name_of takeCover)” item"
sleep 4
[ -n "$(cover_of "$EMPTY")" ] || fail "the book still has no cover"
MISSING_AFTER=$(tree | grep -o "$(name_of missing), [0-9]*" | head -1)
[ "$MISSING_AFTER" != "$MISSING_BEFORE" ] || fail "the sidebar still says “${MISSING_BEFORE}”"
say "first cover → $(facts_of "$EMPTY"); sidebar: $MISSING_BEFORE → $MISSING_AFTER"
shoot 9-first-cover

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

# ── 9. Download Cover… over a cover that is already there ────────────────────
# The one stage that needs the network *and* a book a service has heard of.
# Skipped loudly rather than quietly when there is no such library.
RESTART_LIBRARY="$LIB"
RESTART_BOOK="Ministry Called"
if [ -f "$ONLINE/.shelf/library.sqlite" ]; then
    say "switching to $ONLINE for the download"
    relaunch_on "$ONLINE"
    select_book "Nineteen"
    ONLINE_FOLDER=$(dirname "$(grep -rl "<dc:title>Nineteen Eighty-Four<" "$ONLINE" --include=metadata.opf 2>/dev/null | head -1)")
    [ -d "$ONLINE_FOLDER" ] || fail "no Nineteen Eighty-Four in $ONLINE"
    BEFORE=$(facts_of "$ONLINE_FOLDER")
    open_cover_menu
    click_menu_item "$(name_of download)" || fail "no “$(name_of download)” item"
    # The services are given time to answer, and the run says so if they do not.
    WAITED=0
    until tree_has "$(name_of replace)"; do
        WAITED=$((WAITED + 1))
        if [ "$WAITED" -ge 30 ]; then
            P=$(swift "$HERE/cell-point.swift" "$PID" "desc=$(name_of cancel)" 2>/dev/null) \
                && swift "$HERE/click-at.swift" ${P% *} ${P#* }
            fail "no service offered a cover within 30 s, so “$(name_of replace)” never appeared.
       Open Library answers most ISBNs; Google Books has answered 429 to every
       request this project has ever made. Nothing was written."
        fi
        sleep 1
    done
    # **This is the picture that matters**: a cover already beside the book, a
    # preview of what would replace it, and a button that says *replace* rather
    # than *use*. The warning is the wording; the evidence is above it.
    say "the sheet offers “$(name_of replace)” over an existing cover"
    shoot 10-replace-cover
    click "desc=$(name_of replace)" || fail "could not press “$(name_of replace)”"
    sleep 8
    AFTER=$(facts_of "$ONLINE_FOLDER")
    [ "$AFTER" != "$BEFORE" ] || fail "the download did not replace the cover
       before: $BEFORE
       after:  $AFTER
       Most likely the book already has exactly the picture the service offers,
       because an earlier run of this script put it there — `applyCover`
       deliberately does nothing when the new bytes equal the old ones, which is
       right and makes this stage unprovable. Build the library again:
           Scripts/online-library.sh $CACHE"
    say "downloaded → $AFTER, generation $(generation_of "$ONLINE_FOLDER")"
    shoot 11-downloaded
    P=$(swift "$HERE/cell-point.swift" "$PID" "desc=$(name_of cancel)" 2>/dev/null) \
        && swift "$HERE/click-at.swift" ${P% *} ${P#* }
    sleep 2
    RESTART_LIBRARY="$ONLINE"
    RESTART_BOOK="Nineteen"
else
    say "SKIPPED: Download Cover… — no library with real ISBNs at $ONLINE."
    say "         Build one: Scripts/online-library.sh $CACHE"
fi

# ── 10. And it is still there after the app has been started again ───────────
# The claim the generation exists to make. Quit, relaunch, look.
relaunch_on "$RESTART_LIBRARY"
select_book "$RESTART_BOOK"
say "restarted on $(basename "$RESTART_LIBRARY")"
shoot 12-after-restart

say "ok – $OUT"
