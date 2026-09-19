#!/bin/bash
# What a held arrow key costs, and whether the arrows still work after
# [ADR 0017](../docs/adr/0017-the-arrow-keys-leave-the-menu-bar.md) took them
# off the menu bar.
#
# Two questions, and they need each other. Moving a key out of the menu bar is
# only worth doing if it is cheaper afterwards, and it is only *allowed* if the
# key still moves the selection.
#
# 1. **Does → still move?** Click the first cover, read the title out of the
#    inspector, post → five times, read it again. A different title is the
#    answer; the same title is a failure and says so.
# 2. **What does holding it cost?** `sample` for ten seconds while → is posted
#    as fast as System Events will post it, then count the share of the run
#    spent inside AppKit's menu machinery. ADR 0006 measured 83 % there, of
#    which 31 % was `usleep` inside
#    `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS`.
#
# macOS's own `key down` produces no auto-repeat, so the repeat is generated —
# which is what ADR 0006 did too, and the comparison is only fair like for like.
#
# Needs Accessibility permission and an unlocked screen.
# It never ends a Shelf it did not start.
#
# Usage: Scripts/arrow-key-proof.sh [library folder] [seconds]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="${1:-$HOME/Library/Caches/Shelf/measure-library-7b/library}"
SECONDS_TO_SAMPLE="${2:-10}"

say() { echo "arrow-key-proof: $1"; }
fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "arrow-key-proof: FAILED – $1" >&2
    exit 1
}

. "$HERE/app-language.sh"
pin_app_language en
. "$HERE/screen-awake.sh"
require_awake_screen "$@"

[ -f "$LIBRARY/.shelf/library.sqlite" ] || fail "'$LIBRARY' holds no index"

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

open -a "$APP" "$LIBRARY" || fail "could not launch $APP"
sleep 10
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

cleanup() {
    [ -n "${PID:-}" ] || return
    kill "$PID" >/dev/null 2>&1
    sleep 1
    kill -9 "$PID" >/dev/null 2>&1
}
trap 'cleanup; restore_app_language' EXIT

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
# The title out of the inspector's own field, which is where the selected book
# is named. Read out of the tree rather than off a screenshot, so it is a
# string and not a picture of one.
selected_title() {
    swift "$HERE/ax-dump.swift" "$PID" 16 2>/dev/null \
        | grep 'desc="Title"' | head -1 | sed -n 's/.*value="\([^"]*\)".*/\1/p'
}
press_right() { osascript -e 'tell application "System Events" to key code 124' >/dev/null 2>&1; }

front
sleep 1
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
EOF
sleep 2

POINT=$(swift "$HERE/cell-point.swift" "$PID" cell 0 2>/dev/null) || fail "could not find the first cover"
swift "$HERE/click-at.swift" ${POINT% *} ${POINT#* }
sleep 2

# Braces everywhere a value is followed by a curly quote below: bash reads
# the quote's own bytes as part of the name otherwise, and says "unbound
# variable" about a variable that is plainly set.
BEFORE=$(selected_title)
[ -n "$BEFORE" ] || fail "no book is selected after clicking the first cover"
say "before: “${BEFORE}”"

for _ in 1 2 3 4 5; do
    press_right
    sleep 0.35
done
sleep 1
AFTER=$(selected_title)
say "after five →: “${AFTER}”"
[ -n "$AFTER" ] || fail "nothing is selected after pressing →"
[ "$BEFORE" != "$AFTER" ] || fail "→ did not move the selection — it is still on “${BEFORE}”"
say "→ moves the selection"

# ── What holding it costs ────────────────────────────────────────────────────
SAMPLE=$(mktemp -t shelf-arrow)
say "sampling for ${SECONDS_TO_SAMPLE} s while → is posted as fast as it will go"
# `/usr/bin/sample`, spelt out. A Python installation on this Mac puts a script
# called `sample` earlier on the PATH, and it answers with a traceback about a
# missing module — which reads as "sampling is not allowed here" and is not.
/usr/bin/sample "$PID" "$SECONDS_TO_SAMPLE" -file "$SAMPLE" >/dev/null 2>&1 &
SAMPLER=$!
# One `osascript` that loops, not one per press. Starting `osascript` costs
# about 150 ms, so a shell loop managed 60 presses in ten seconds where ADR
# 0006's measurement had 626 — and a key pressed six times a second is not a
# held key. The repeat count is generous; the sampler is what ends the run.
osascript >/dev/null 2>&1 <<EOF &
repeat 2000 times
    tell application "System Events" to key code 124
end repeat
EOF
PRESSER=$!
wait "$SAMPLER" 2>/dev/null
# Stopped, and its death announcement kept out of the report: this shell
# started it, so ending it is this session's own business (CLAUDE.md).
kill "$PRESSER" >/dev/null 2>&1
wait "$PRESSER" 2>/dev/null
say "the sample is over; the presser was this session's own and has been stopped"

[ -s "$SAMPLE" ] || fail "sample wrote nothing — is this terminal allowed to sample other processes?"

# The sample count of the first line naming a frame.
#
# `sample` draws the call graph with `+ ! : |` characters in front of every
# line, so the count is **not** at the start of the line — it is the first
# number on it. The first version of this anchored at the start, which meant
# every deep frame read 0: a check that can only ever report "nothing here" is
# worse than no check, because it reports success.
samples_at() { # a frame name
    grep -m1 "$1" "$SAMPLE" | sed -n 's/^[^0-9]*\([0-9][0-9]*\) .*/\1/p'
}

# The main thread's total, and how much of it is inside the menu machinery.
#
# `sample` writes the call graph as one line per frame with that frame's sample
# count in front of it, so the first line naming a frame carries its whole
# share. The main thread's own total is the line that names it.
TOTAL=$(grep -m1 "Main Thread" "$SAMPLE" | sed -n 's/^[^0-9]*\([0-9][0-9]*\) .*/\1/p')
[ -n "$TOTAL" ] || fail "could not read the main thread's sample count out of $SAMPLE"
say "samples on the main thread: $TOTAL"

# Proof that the reading below can see a deep frame at all. `NSApplicationMain`
# is nine levels in and is in every sample there has ever been; if it reads 0,
# the parsing is broken and every "0.0 %" under it is a lie rather than a
# finding.
CONTROL=$(samples_at "NSApplicationMain")
[ "${CONTROL:-0}" -gt 0 ] || fail "the sample parser reads 0 for NSApplicationMain, so it reads 0 for everything"
say "the parser can see a deep frame: NSApplicationMain has $CONTROL samples"

report() { # a frame name, and what to call it
    local count share
    count=$(samples_at "$1")
    count=${count:-0}
    # `LC_ALL=C`, because awk formats in the user's locale and on this Mac
    # that writes 0,7 — a number no reader of this project's reports expects
    # and the same trap `make smoke` documents for `ps`.
    share=$(LC_ALL=C awk -v a="$count" -v b="$TOTAL" 'BEGIN { printf "%.1f", (b > 0 ? 100 * a / b : 0) }')
    printf "  %-52s %7s  %6s %%\n" "$2" "$count" "$share"
}
printf "  %-52s %7s  %8s\n" "where the main thread was" "samples" "share"
report "performKeyEquivalent" "-[NSMenu performKeyEquivalent:]   ADR 0006: 83 %"
report "NSMENU_IS_THROTTLING" "NSMENU_IS_THROTTLING -> usleep   ADR 0006: 31 %"
report "_NSHighlightMenu" "_NSHighlightMenu -> layout       ADR 0006: 27 %"
report "EditingKeyMonitor" "the monitor, and the move under it"
say "the whole sample is at $SAMPLE — it is not deleted, so the numbers can be checked"
