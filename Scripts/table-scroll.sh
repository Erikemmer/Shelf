#!/bin/bash
# Scrolls the table through a five-thousand-book library and reads the main
# thread while it does.
#
# The one measurement Sprint 2c owed and could not take: the table is a SwiftUI
# `Table`, which recycles rows, and nothing in a row reads a file — but that is
# an argument, and the brief asked for a measurement. `sample` is the
# measurement. What it has to show is that while the table is being scrolled the
# main thread is in AppKit and SwiftUI and **not** in a cover decode or a file
# read: either of those on the main thread is what a stutter is made of.
#
# It also reads the peak memory of the process while that happens, which is the
# number Sprint 2c took with the screen locked and therefore could not keep.
#
# Needs Accessibility permission and an unlocked screen. It never ends a Shelf
# it did not start.
#
# Usage: Scripts/table-scroll.sh [library folder] [seconds of sampling]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIBRARY="${1:-$HOME/Library/Caches/Shelf/measure-library-3}"
SECONDS_TO_SAMPLE="${2:-10}"
OUT="${OUT:-$ROOT/docs/screenshots/sprint-2c}"

fail() {
    command -v fail_if_locked_now >/dev/null 2>&1 && fail_if_locked_now
    echo "table-scroll: FAILED – $1" >&2
    exit 1
}
say() { echo "table-scroll: $1"; }

# Shelf speaks two languages now and follows the Mac's. Every menu name in
# this script is English, so the run says so (Scripts/app-language.sh).
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

if pgrep -x Shelf >/dev/null; then
    osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
    sleep 3
    pgrep -x Shelf >/dev/null && fail "a Shelf instance will not quit"
fi

BOOKS=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "SELECT COUNT(*) FROM books")
say "library: $(basename "$LIBRARY"), $BOOKS books"

open -a "$APP" "$LIBRARY" || fail "could not launch $APP"
sleep 12
PID=$(pgrep -x Shelf | head -1)
[ -n "$PID" ] || fail "Shelf did not start"
say "pid $PID"

front() {
    osascript -e "tell application \"System Events\" to set frontmost of (first application process whose unix id is $PID) to true" >/dev/null 2>&1
}
# **Three levels deep, not fourteen.** A full accessibility dump of a window
# showing five thousand books walks every cell and every one of their children;
# the first version of this script asked for one in a loop and sat there for ten
# minutes without printing a line. Everything this needs is at the top: the
# view-mode control is the third element in the window, and the segment that is
# switched on carries `value="1"`.
mode() { swift "$HERE/ax-dump.swift" "$PID" 3 2>/dev/null; }
# `grep -c`, never `grep -q`, behind a pipe – see the note in shots-2c.sh.
table_is_up() { local n; n=$(mode | grep -c 'value="1" desc="Table"'); [ "${n:-0}" -gt 0 ]; }

# The window goes to a known place and a known size, so two runs are comparable
# and so the memory figure is not a reading of whatever size it was left at.
front; sleep 0.8
osascript >/dev/null 2>&1 <<EOF
tell application "System Events" to tell (first application process whose unix id is $PID)
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {1440, 877}
end tell
EOF
sleep 1
front; sleep 1
osascript -e 'tell application "System Events" to keystroke "2" using command down' >/dev/null 2>&1
WAITED=0
until table_is_up; do
    WAITED=$((WAITED + 1))
    [ "$WAITED" -lt 20 ] || fail "⌘2 did not show the table"
    sleep 1
done
say "the table is up, over $BOOKS books"

# ── Scroll, and sample while it scrolls ──────────────────────────────────────
# **Page Down, not the scroll wheel.** `Scripts/scroll-at.swift` posts scroll
# wheel events at a point and reports success, and the SwiftUI `Table` does not
# move for them - measured: the window is byte for byte identical after twenty
# clicks at a point plainly inside it, and changes at once for one Page Down.
# The wheel drives the cover grid, which is what that script was written for.
#
# This is therefore a measurement of **keyboard-driven scrolling**, and says so.
# It exercises the same row recycling, which is what the question is about; it
# is not an answer to "is trackpad scrolling smooth", which is its own open item
# in the backlog and needs a person's hand.
mkdir -p "$OUT"
SAMPLE="$OUT/table-scroll-sample.txt"

# **Did it scroll?** Without this the whole run measures an idle app and calls
# it a clean main thread — which is exactly what the first working version of
# this script did, and it read beautifully: nought decodes, nought file reads,
# and a main thread 8 213 samples out of 8 440 deep in `mach_msg`. Nothing had
# moved. The window's own picture before and after is the cheapest honest
# answer: if the bytes are the same, there was nothing to measure.
WINDOW_ID=$(swift "$HERE/window-id.swift" "$PID" 2>/dev/null)
[ -n "$WINDOW_ID" ] || fail "no window to scroll"
screencapture -o -x -l "$WINDOW_ID" /tmp/table-before.png 2>/dev/null
BEFORE=$(shasum /tmp/table-before.png | cut -d" " -f1)

# Key code 121 is Page Down, 116 is Page Up. Down mostly, up sometimes, so a run
# long enough to reach the end of the library keeps having somewhere to go.
( for round in $(seq 1 "$((SECONDS_TO_SAMPLE * 6))"); do
      if [ "$((round % 40))" -lt 30 ]; then CODE=121; else CODE=116; fi
      osascript -e "tell application \"System Events\" to key code $CODE" >/dev/null 2>&1
      sleep 0.12
  done ) &
SCROLLER=$!

PEAK_RSS=0
( while kill -0 "$SCROLLER" 2>/dev/null; do
      RSS=$(LC_ALL=C ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
      [ -n "$RSS" ] && echo "$RSS"
      sleep 0.5
  done ) > /tmp/table-scroll-rss.txt &
WATCHER=$!

say "sampling the main thread for ${SECONDS_TO_SAMPLE}s while the table scrolls"
# `/usr/bin/sample`, spelled out. A Python distribution on this Mac installs a
# script of its own called `sample` earlier on the PATH, and it answers with a
# `ModuleNotFoundError` and exit 1 — both of which went to /dev/null, so the run
# reported "sample wrote nothing" and looked like a permissions problem.
/usr/bin/sample "$PID" "$SECONDS_TO_SAMPLE" -file "$SAMPLE" >/dev/null 2>&1
wait "$SCROLLER" 2>/dev/null
wait "$WATCHER" 2>/dev/null

PEAK_RSS=$(sort -rn /tmp/table-scroll-rss.txt 2>/dev/null | head -1)
rm -f /tmp/table-scroll-rss.txt
[ -s "$SAMPLE" ] || fail "sample wrote nothing – is it allowed to attach to another process?"

screencapture -o -x -l "$WINDOW_ID" /tmp/table-after.png 2>/dev/null
AFTER=$(shasum /tmp/table-after.png | cut -d" " -f1)
rm -f /tmp/table-before.png /tmp/table-after.png
[ "$BEFORE" != "$AFTER" ] || fail "the window is byte for byte what it was before the scroll.
       Nothing scrolled, so the sample would be a measurement of an idle app.
       Is Shelf frontmost, and is the screen unlocked?"
say "the window changed while it scrolled, so there was something to measure"

# ── What the sample says ─────────────────────────────────────────────────────
# The main thread is thread 1 in every sample `sample` writes.
MAIN=$(awk '/^ *[0-9]+ Thread_/{keep=0} /^ *[0-9]+ Thread_.*DispatchQueue_1|Main Thread/{keep=1} keep' "$SAMPLE")
[ -n "$MAIN" ] || MAIN=$(cat "$SAMPLE")

count_in_main() { printf '%s' "$MAIN" | grep -ci "$1"; }

DECODE=$(count_in_main 'CGImageSourceCreateImage\|CoverDecoder\|ImageIO\|JPEGDecode\|AppleJPEG')
FILEIO=$(count_in_main '__read\|__pread\|read_nocancel\|CoverDiskCache\|Data.init(contentsOf\|FileHandle')
SQLITE=$(count_in_main 'sqlite3_step\|GRDB')

say "peak memory while scrolling: $((PEAK_RSS / 1024)) MB"
say "main-thread frames mentioning a cover decode: $DECODE"
say "main-thread frames mentioning file I/O:       $FILEIO"
say "main-thread frames mentioning SQLite:         $SQLITE"
say "the whole sample is in ${SAMPLE#"$ROOT"/}"

osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1

if [ "$DECODE" -gt 0 ] || [ "$FILEIO" -gt 0 ]; then
    fail "the main thread was decoding or reading files while the table scrolled.
       That is what a stutter is made of. The sample names the frames."
fi
say "ok – no decode and no file I/O on the main thread while $BOOKS rows scrolled"
say "   (driven by Page Down; trackpad scrolling is a separate question)"
