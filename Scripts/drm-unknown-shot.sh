#!/bin/bash
# Photographs the "DRM unknown" badge Sprint 17, Teil A added: a book whose
# only file is a format Shelf never opens (KFX) must not look like a book
# that was checked and found clean — an empty corner would say exactly that.
#
# Runs against a KFX-only fixture built with `shelf-tool import`, never a
# borrowed book (CLAUDE.md). The import itself is not what is being proven
# here (that is `formats-shot.sh`'s job); this is the window's own
# rendering of a file it never opened.
#
# Needs Screen Recording and Accessibility, and an unlocked screen. It runs
# in **either language**: SHELF_SHOT_LANGUAGE=de pins German. It never ends
# a Shelf it did not start.
#
# Usage: Scripts/drm-unknown-shot.sh [library] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LANGUAGE="${SHELF_SHOT_LANGUAGE:-en}"
CACHE="$HOME/Library/Caches/Shelf/drm-unknown-17"
LIB="${1:-$CACHE/library}"
DEFAULT_OUT="$ROOT/docs/screenshots/sprint-17"
[ "$LANGUAGE" = "en" ] || DEFAULT_OUT="$DEFAULT_OUT/de"
OUT="${2:-$DEFAULT_OUT}"
BADGE_TEXT="DRM unknown"
FORMATS_HEADER="FORMATS"
if [ "$LANGUAGE" != "en" ]; then
    BADGE_TEXT="DRM unbekannt"
    FORMATS_HEADER="FORMATE"
fi

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "drm-unknown-shot: FAILED – $1" >&2
    exit 1
}
say() { echo "drm-unknown-shot: $1"; }

. "$HERE/app-language.sh"
pin_app_language "$LANGUAGE"

. "$HERE/screen-awake.sh"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
require_awake_screen "$@"

[ -f "$LIB/.shelf/library.sqlite" ] || fail "'$LIB' holds no index – run 'shelf-tool import <source> $LIB' first"
mkdir -p "$OUT"

APP="${SHOT_APP:-}"
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app)" || exit 1
fi
[ -n "$APP" ] || fail "no built Shelf.app – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1

# Never end a Shelf this script did not start.
require_no_foreign_shelf

open -a "$APP" "$LIB" ${SHELF_LANGUAGE_ARGS:-} || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
tree() { swift "$HERE/ax-dump.swift" "$PID" 12 2>/dev/null; }
# `grep -c`, never `grep -q`: under `pipefail` a match closes the pipe and
# the status becomes 141, so a hit reads as a miss.
tree_has() {
    local n
    n=$(tree | grep -c -- "$1")
    [ "${n:-0}" -gt 0 ]
}
shoot() {
    front
    sleep 1.5
    local wid
    wid=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
    [ -n "$wid" ] || fail "no window to photograph"
    screencapture -o -x -l "$wid" "/tmp/drm-unknown-shot.png" || fail "capture failed for $1"
    sips -s format jpeg -s formatOptions 75 "/tmp/drm-unknown-shot.png" --out "$OUT/$1.jpg" >/dev/null 2>&1
    rm -f /tmp/drm-unknown-shot.png
    say "$1.jpg ($(($(stat -f %z "$OUT/$1.jpg") / 1024)) KB)"
}
click() {
    local point
    point=$(swift "$HERE/cell-point.swift" "$PID" "$1" ${2:-} 2>/dev/null) || return 1
    swift "$HERE/click-at.swift" ${point% *} ${point#* }
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
sleep 1

# ── The grid: the corner nobody's unchecked book should leave empty ─────────
front
sleep 1
tree_has "$BADGE_TEXT" \
    || fail "no '$BADGE_TEXT' badge on the grid – the fixture library holds only the KFX-only
       book, so it must be there. Run 'shelf-tool import' against a fresh source first."
say "the '$BADGE_TEXT' badge is on the grid"
shoot drm-unknown-grid

# ── The inspector: the same file, and why ────────────────────────────────────
click "cell" 0 || fail "no book in the grid to select"
sleep 2
# The window is 1440 × 877 at (30, 40) and the inspector is its right 280 pt
# (formats-shot.sh's own reasoning): the Formats section sits below the fold,
# so the panel is scrolled down before the shot.
swift "$HERE/scroll-at.swift" 1330 500 -14 3 >/dev/null 2>&1
sleep 1.5
tree_has "$BADGE_TEXT" || fail "the inspector shows no '$BADGE_TEXT' badge on the KFX file"
say "the inspector shows the badge and the caption"
shoot drm-unknown-inspector
tree | sed -n "/$FORMATS_HEADER/,\$p" | head -40 >"$OUT/ax-drm-unknown.txt"

say "ok – $OUT"
