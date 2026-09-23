#!/bin/bash
# Reproduces, and then proves fixed, the false "Could not read the library
# index" banner that could appear right after an import was cancelled
# (docs/BACKLOG.md: "A visible 'Could not read the library index' /
# CancellationError banner can appear right after quitting cancels an
# import").
#
# Root cause, found by reading the code this script drives rather than
# guessed: `LibraryModel.runImport()` awaited `reload()` inside
# `importRunTask` — the very `Task` a Cancel click (or a quit) had just
# cancelled. GRDB's async reads cooperatively check `Task.isCancelled` and
# throw `CancellationError` *before touching the database at all*, the same
# check Sprint 13, Teil C's Bug 3 found silently losing a write
# (`CHANGELOG.md`). `reload()`'s generic `catch` turned that into a real
# looking, but false, read-failure banner. The index was never actually
# unreadable.
#
# This script drives the real, running app: a real import, auto-started
# through `SHELF_AUTO_IMPORT_SOURCE` (Sprint 13, Teil B/C's own test hook,
# the same one `Scripts/current-shelf-app.sh`'s neighbours use to avoid
# driving the Add Books panel through System Events), against a library
# large enough that it is still copying when a real click lands on Cancel —
# then reads the window's own accessibility tree for the banner's words,
# never assumed from the code. A screenshot is saved either way, named by
# what it shows.
#
# Needs Accessibility and an unlocked screen. Never ends a Shelf it did not
# start.
#
# Usage: Scripts/import-cancel-proof.sh [en|de] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="$HOME/Library/Caches/Shelf/import-cancel-proof"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
LANGUAGE="${1:-en}"
OUT="${2:-$CACHE/shots}"
SOURCE="$CACHE/source"
EMPTY="$CACHE/empty"
LIB="$CACHE/library-$LANGUAGE"
BOOKS=4000
WINDOW_RECT="30,40,1440,877"

say() { echo "import-cancel-proof: $1"; }
fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "import-cancel-proof: FAILED – $1" >&2
    exit 1
}

. "$HERE/app-language.sh"
. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

case "$LANGUAGE" in
    en)
        RUNNING_MARKER="Copying and verifying"
        CANCEL_LABEL="Cancel"
        DONE_LABEL="Done"
        BANNER_MARKER="read the library index"
        ;;
    de)
        RUNNING_MARKER="werden kopiert"
        CANCEL_LABEL="Abbrechen"
        DONE_LABEL="Fertig"
        BANNER_MARKER="Bibliotheksindex"
        ;;
    *)
        fail "unknown language '$LANGUAGE' – use en or de"
        ;;
esac
pin_app_language "$LANGUAGE"
require_no_foreign_shelf

mkdir -p "$OUT" "$EMPTY"
TOOL="$SCRATCH/release/shelf-tool"
if [ ! -x "$TOOL" ]; then
    say "building shelf-tool in release"
    swift build -c release --scratch-path "$SCRATCH" >/dev/null || fail "could not build shelf-tool"
fi
if [ ! -d "$SOURCE" ]; then
    say "synthesising $BOOKS books for the import source (once, reused by both languages)"
    "$TOOL" synthesise "$SOURCE" "$BOOKS" | tail -1
fi

rm -rf "$LIB"
say "creating an empty library at $LIB"
"$TOOL" import "$EMPTY" "$LIB" >/dev/null || fail "could not create the library"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app)" || exit 1
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1

PROBE=$(mktemp -t shelf-import-cancel).png
if ! screencapture -x "$PROBE" 2>/dev/null || [ ! -s "$PROBE" ]; then
    rm -f "$PROBE"
    fail "screencapture cannot read the display. Grant Screen Recording to this terminal."
fi
rm -f "$PROBE"

say "launching with SHELF_AUTO_IMPORT_SOURCE=$SOURCE (Sprint 13's own test hook)"
open --env "SHELF_AUTO_IMPORT_SOURCE=$SOURCE" -a "$APP" "$LIB" "$SOURCE" ${SHELF_LANGUAGE_ARGS:-} \
    || fail "could not launch $APP"
sleep 8
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() { osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1; }
tree() { swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null; }
tree_has() { local n; n=$(tree | grep -c "$1"); [ "${n:-0}" -gt 0 ]; }
click() { local p; p=$(swift "$HERE/cell-point.swift" "$PID" "$1" ${2:-} 2>/dev/null) || return 1; swift "$HERE/click-at.swift" ${p% *} ${p#* }; }
quit_shelf() {
    [ -n "${PID:-}" ] || return 0
    osascript -e "tell application \"System Events\" to tell (first application process whose unix id is $PID) to keystroke \"q\" using command down" >/dev/null 2>&1
    sleep 3
    PID=""
}
position_window() {
    osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
EOF
}
shoot() {
    front
    swift "$HERE/cursor-park.swift" 1500 8 >/dev/null 2>&1
    sleep 1
    screencapture -x -R "$WINDOW_RECT" "/tmp/import-cancel-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/import-cancel-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f "/tmp/import-cancel-shot.png"
    say "screenshot: $OUT/$1.jpg"
}

front
sleep 1
position_window

# Wait for the import sheet to actually be *copying*, not merely examining or
# planning — a click on Cancel before the run has started would cancel
# nothing real, and the whole point is a real, in-flight cancellation.
say "waiting for the import to start copying"
WAITED=0
until tree_has "$RUNNING_MARKER"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 40 ] || { quit_shelf; fail "the import never reached the copying phase – raise BOOKS or check SHELF_AUTO_IMPORT_SOURCE"; }
    sleep 0.5
done
say "copying – clicking Cancel for real"
click "desc=$CANCEL_LABEL" || { quit_shelf; fail "could not find the $CANCEL_LABEL button"; }
say "clicked. tree right after:"
tree | grep -E "Copying|kopiert|Cancel|Abbrechen|Done|Fertig" | head -5

# The cancelled run still flushes its short last batch and finishes; the
# sheet moves to its "finished" state on its own. Bounded generously (a
# large in-flight backlog's own flush is not instant – CHANGELOG.md, Sprint
# 13, Teil C).
WAITED=0
until tree_has "$DONE_LABEL"; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 90 ] || { quit_shelf; fail "the sheet never reached its finished state after Cancel"; }
    sleep 1
done
sleep 1
say "clicking $DONE_LABEL to dismiss the sheet"
click "desc=$DONE_LABEL" || { quit_shelf; fail "could not find the $DONE_LABEL button"; }
sleep 2

if tree_has "$BANNER_MARKER"; then
    say "the window shows the banner: $(tree | grep "$BANNER_MARKER" | head -1)"
    RESULT="banner"
else
    say "no banner in the window's own accessibility tree ✓"
    RESULT="clean"
fi
shoot "$LANGUAGE-$RESULT"

quit_shelf
say "done – result: $RESULT"
[ "$RESULT" = "clean" ]
