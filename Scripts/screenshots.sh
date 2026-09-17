#!/bin/bash
# Photographs Shelf's four screens at one size, photographs Selector at the same
# size, and reads the same four pixels out of both.
#
# Why it exists: "does it look like Selector?" is the one Sprint 1 claim nobody
# could check, and an opinion about it is worth nothing. Four colours read out
# of two files is worth something.
#
# **It needs Screen Recording permission** for whatever runs it (Terminal, or
# the terminal your editor embeds): System Settings ▸ Privacy & Security ▸
# Screen Recording. Without it `screencapture` refuses with "could not create
# image from display" and this script stops and says so rather than writing
# empty files. Accessibility permission is needed too, for resizing the window.
#
# Selector is only *read*: if it is already running the script photographs that
# instance and leaves it alone; if it is not, the script starts one and quits
# only the instance it started.
#
# Usage: Scripts/screenshots.sh [library folder] [output folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="${1:-$HOME/Library/Caches/Shelf/measure-library}"
OUT="${2:-$HERE/../docs/screenshots/sprint-1}"
WIDTH="${SHOT_WIDTH:-1440}"
HEIGHT="${SHOT_HEIGHT:-900}"
MAX_BYTES=$((500 * 1024))

fail() { echo "screenshots: FAILED – $1" >&2; exit 1; }

mkdir -p "$OUT"

# ── The permission, checked before anything is launched ───────────────────────
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

# ── Helpers ───────────────────────────────────────────────────────────────────
# The window is sized through the accessibility API. macOS clamps it to the
# screen's visible area, so with the Dock showing the height comes out smaller
# than asked; the actual size is printed, and it is the size both apps get.
resize() {
    osascript >/dev/null 2>&1 <<EOF
tell application "$1" to activate
delay 0.6
tell application "System Events" to tell process "$1"
    set position of window 1 to {30, 40}
    delay 0.3
    set size of window 1 to {$WIDTH, $HEIGHT}
end tell
EOF
    sleep 1
    osascript -e "tell application \"System Events\" to tell process \"$1\" to get size of window 1" 2>/dev/null
}

shoot() {
    local process="$1" name="$2"
    osascript -e "tell application \"$process\" to activate" >/dev/null 2>&1
    sleep 1
    local pid wid
    pid=$(pgrep -x "$process" | head -1)
    wid=$(swift "$HERE/window-id.swift" "$pid" 2>/dev/null)
    [ -n "$wid" ] || { echo "screenshots: no window for $process – skipping $name"; return 1; }
    screencapture -o -x -l "$wid" "$OUT/$name.png" || { echo "screenshots: capture failed for $name"; return 1; }
    # PNG first because it is lossless and the pixel readings are taken from it;
    # a shot over the size limit is kept as JPEG instead, and the readings are
    # taken before the conversion.
    local bytes
    bytes=$(stat -f %z "$OUT/$name.png")
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
        sips -s format jpeg -s formatOptions 80 "$OUT/$name.png" --out "$OUT/$name.jpg" >/dev/null 2>&1
        echo "screenshots: $name.png was $((bytes / 1024)) KB – kept as $name.jpg ($(($(stat -f %z "$OUT/$name.jpg") / 1024)) KB)"
    else
        echo "screenshots: $name.png ($((bytes / 1024)) KB)"
    fi
    return 0
}

# ── Shelf ─────────────────────────────────────────────────────────────────────
STARTED_SHELF=0
pgrep -x Shelf >/dev/null || STARTED_SHELF=1
osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1; sleep 2

open -n -F "$APP"; sleep 4
echo "screenshots: window size: $(resize Shelf)"
shoot Shelf welcome

open -a "$APP" "$LIBRARY"; sleep 8
resize Shelf >/dev/null
shoot Shelf library

# The sidebar scrolled down to where tags, authors and series are, so the shot
# shows filled sections rather than only the collections at the top.
osascript >/dev/null 2>&1 <<'EOF'
tell application "System Events" to tell process "Shelf"
    repeat 12 times
        scroll down at {120, 400}
    end repeat
end tell
EOF
sleep 1
shoot Shelf sidebar

# The import sheet, reached the way a person reaches it: ⌘I, then the open panel
# is pointed at the source folder with ⇧⌘G.
osascript >/dev/null 2>&1 <<EOF
tell application "Shelf" to activate
delay 0.5
tell application "System Events"
    keystroke "i" using command down
    delay 2
    keystroke "g" using {command down, shift down}
    delay 1
    keystroke "$HOME/Library/Caches/Shelf/synthetic"
    delay 1
    key code 36
    delay 2
    key code 36
end tell
EOF
sleep 6
shoot Shelf import-sheet

# ── Selector, at the same size ────────────────────────────────────────────────
STARTED_SELECTOR=0
if ! pgrep -x Selector >/dev/null; then
    if [ -n "${SELECTOR_APP:-}" ]; then
        open -n "$SELECTOR_APP" && STARTED_SELECTOR=1 && sleep 6
    else
        open -a Selector >/dev/null 2>&1 && STARTED_SELECTOR=1 && sleep 6
    fi
fi
if pgrep -x Selector >/dev/null; then
    echo "screenshots: Selector window size: $(resize Selector)"
    shoot Selector selector-reference
else
    echo "screenshots: Selector is not running and could not be started – no comparison shot"
fi

# ── The four colours, read out of both ────────────────────────────────────────
# Points inside the three panels and on the selected row, in window points; the
# probe multiplies by 2 for the Retina backing.
echo ""
echo "── pixel comparison (window points, x2 for Retina) ──"
for shot in "$OUT/library.png" "$OUT/selector-reference.png"; do
    [ -f "$shot" ] || continue
    swift "$HERE/pixel-probe.swift" "$shot" --points 2 \
        90,500 700,500 1360,500 90,120
done
echo ""
echo "The four points: sidebar background · main area · inspector background ·"
echo "a sidebar row near the top. The values must be identical in both files."

# ── Only what this script started ─────────────────────────────────────────────
[ "$STARTED_SELECTOR" = "1" ] && osascript -e 'tell application "Selector" to quit' >/dev/null 2>&1
[ "$STARTED_SHELF" = "1" ] && osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
echo ""
echo "screenshots: files in $OUT"
