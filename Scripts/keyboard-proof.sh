#!/bin/bash
# Does a click on a cover take the keyboard back from the search field?
#
# Sprint 2b shipped with this in the backlog: after a search, pressing 3 typed a
# "3" into the search box instead of rating the book, and three attempted fixes
# each improved it without settling it. The cause was two `@FocusState`
# bindings – one on the grid, one on the field – asking SwiftUI to focus two
# things at once. Sprint 2c replaced them with one binding holding an enum.
#
# A fix for a race has to be shown, not argued. This drives the real window:
# type a search, click a real cover (its position read out of the accessibility
# tree, not guessed from a margin), press R, and look in the index to see
# whether the book's read status actually changed. Then the same again with
# Escape instead of the click, because Escape is the other way out.
#
# It reads the library's SQLite file from outside the app. That is a read of a
# cache, and the app is the only writer.
#
# Needs Accessibility permission for whatever runs it. It never ends a Shelf it
# did not start.
#
# Usage: Scripts/keyboard-proof.sh [library folder] [rounds]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="${1:-$HOME/Library/Caches/Shelf/measure-library-2c}"
ROUNDS="${2:-5}"
QUERY="${KEYBOARD_PROOF_QUERY:-ancillary}"
INDEX="$LIBRARY/.shelf/library.sqlite"

# Every failure here asks first whether the screen locked mid-run, because a
# locked screen makes the app look as though it stopped answering. The check
# is defined in screen-awake.sh, which is sourced below; `command -v` keeps
# this working if a failure happens before that line.
fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "keyboard-proof: FAILED – $1" >&2
    exit 1
}

# A locked screen breaks everything below without failing any of it – see
# `screen-awake.sh`, which also holds the display awake for the run.
# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
. "$HERE/app-language.sh"
pin_app_language en

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

[ -f "$INDEX" ] || fail "'$LIBRARY' holds no index – import a library there first"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app)" || exit 1
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1

# ── The instance ──────────────────────────────────────────────────────────────
# Never an instance this script did not start itself (Scripts/no-foreign-shelf.sh).
STARTED_IT=0
require_no_foreign_shelf
open -a "$APP" "$LIBRARY" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
STARTED_IT=1
sleep 9
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
echo "keyboard-proof: pid $PID, library $(basename "$LIBRARY")"

cleanup() {
    [ "$STARTED_IT" = "1" ] || return
    osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
}
trap cleanup EXIT

front() {
    osascript >/dev/null 2>&1 <<EOF
tell application "System Events"
    set frontmost of (first application process whose unix id is $PID) to true
end tell
EOF
}

type_keys() { osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1; }
press_escape() { osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; }
command_f() {
    osascript -e 'tell application "System Events" to keystroke "f" using command down' >/dev/null 2>&1
}

read_count() { sqlite3 "$INDEX" "SELECT COUNT(*) FROM books WHERE is_read = 1" 2>/dev/null; }

# Whether the grid is still narrowed, read off the status line in the sidebar's
# footer: "120 books · 97 authors" when nothing is filtering, "7 of 120 books"
# when something is.
#
# Not the search field's own text. A SwiftUI `TextField` publishes its value to
# the accessibility tree only while it has focus, so asking an unfocused search
# box what it holds answers "" whatever it holds – and this script duly reported
# "field empty" for a build whose Escape did not clear the field at all. A
# measurement that cannot fail is not a measurement.
status_line() {
    swift "$HERE/ax-dump.swift" "$PID" 14 2>/dev/null \
        | grep -o 'value="[^"]*books[^"]*"' | head -1
}

# ── The rounds ────────────────────────────────────────────────────────────────
CLICK_OK=0
ESCAPE_OK=0

for round in $(seq 1 "$ROUNDS"); do
    # A: search, then click a cover, then R.
    front; sleep 0.4
    command_f; sleep 0.5
    type_keys "$QUERY"; sleep 1.2
    POINT=$(swift "$HERE/cell-point.swift" "$PID" cell 0 2>/dev/null)
    if [ -z "$POINT" ]; then
        echo "keyboard-proof: round $round – the search matched no cover; skipping the click"
    else
        BEFORE=$(read_count)
        # shellcheck disable=SC2086
        swift "$HERE/click-at.swift" $POINT
        sleep 0.5
        type_keys "r"
        sleep 1.2
        AFTER=$(read_count)
        if [ "$BEFORE" != "$AFTER" ]; then
            CLICK_OK=$((CLICK_OK + 1))
            echo "keyboard-proof: round $round · click  · read books $BEFORE → $AFTER · ok"
        else
            echo "keyboard-proof: round $round · click  · read books stayed at $BEFORE · FAILED"
        fi
    fi
    press_escape; sleep 0.6

    # B: search, then Escape, then R. Escape has to empty the field *and* hand
    # the keyboard on, or the person is out of the box and still cannot reach
    # their books.
    front; sleep 0.3
    command_f; sleep 0.5
    type_keys "$QUERY"; sleep 1.2
    BEFORE=$(read_count)
    NARROWED=$(status_line)
    press_escape; sleep 1.0
    WIDE=$(status_line)
    type_keys "r"
    sleep 1.2
    AFTER=$(read_count)
    # "… of …" is what the status line says while anything is narrowing the
    # view, so its absence is the search having been cleared.
    CLEARED=no
    case "$WIDE" in *" of "*) CLEARED=no ;; *books*) CLEARED=yes ;; esac
    if [ "$BEFORE" != "$AFTER" ] && [ "$CLEARED" = "yes" ]; then
        ESCAPE_OK=$((ESCAPE_OK + 1))
        echo "keyboard-proof: round $round · escape · read books $BEFORE → $AFTER ·" \
            "$NARROWED → $WIDE · ok"
    else
        echo "keyboard-proof: round $round · escape · read books $BEFORE → $AFTER ·" \
            "$NARROWED → $WIDE · FAILED"
    fi
    sleep 0.4
done

echo "keyboard-proof: click then R: $CLICK_OK of $ROUNDS"
echo "keyboard-proof: escape then R: $ESCAPE_OK of $ROUNDS"
[ "$CLICK_OK" = "$ROUNDS" ] && [ "$ESCAPE_OK" = "$ROUNDS" ] || fail "not every round worked – see above"
echo "keyboard-proof: ok"
