#!/bin/bash
# The Sprint 1 proof run, on the command line.
#
# It measures what can be measured without a window: generating 5 000 synthetic
# EPUBs, importing them with SHA-256 verification, reading the index, and
# rebuilding the index from the folders. The window's own numbers – how long
# until every visible cover is on screen, and whether a held arrow key stutters
# – have to be measured with the app open; `docs/BACKLOG.md` says how.
#
# Everything lands under ~/Library/Caches/Shelf, never under ~/Documents: that
# folder is synced, and 5 000 generated books would be uploaded to iCloud.
set -uo pipefail

ROOT="${1:-$HOME/Library/Caches/Shelf/synthetic}"
COUNT="${COUNT:-5000}"
SOURCE="$ROOT/source"
LIBRARY="$ROOT/library"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/release/shelf-tool"

if [ ! -x "$TOOL" ]; then
    echo "building shelf-tool in release – a debug build measures the wrong thing"
    swift build -c release --scratch-path "$SCRATCH" >/dev/null || {
        echo "could not build shelf-tool" >&2
        exit 1
    }
fi

say() {
    echo ""
    echo "══ $1"
}

# ── 1. Generate ───────────────────────────────────────────────────────────────
say "generating $COUNT synthetic EPUBs"
rm -rf "$SOURCE" "$LIBRARY"
"$TOOL" synthesise "$SOURCE" "$COUNT" | tail -1
echo "source size: $(LC_ALL=C du -sh "$SOURCE" | awk '{print $1}')"

# ── 2. Import ─────────────────────────────────────────────────────────────────
say "importing into a fresh library"
/usr/bin/time -l "$TOOL" import "$SOURCE" "$LIBRARY" 2>&1 | grep -Ev "^  *[0-9]+  " | tail -30
echo "library size: $(LC_ALL=C du -sh "$LIBRARY" | awk '{print $1}')"

# ── 3. Digests against an outside tool ────────────────────────────────────────
# The app's own SHA-256 checked against /usr/bin/shasum, which knows nothing
# about this code. Three files, because the point is agreement, not coverage.
say "digests against /usr/bin/shasum"
FAILED=0
while IFS= read -r file; do
    OURS=$("$TOOL" digest "$file")
    THEIRS=$(shasum -a 256 "$file" | awk '{print $1}')
    if [ "$OURS" = "$THEIRS" ]; then
        echo "  match: $(basename "$file")"
    else
        echo "  MISMATCH: $(basename "$file") ($OURS vs $THEIRS)"
        FAILED=1
    fi
done < <(find "$LIBRARY" -name "*.epub" | head -3)
[ "$FAILED" = "0" ] || { echo "digests disagree – stopping" >&2; exit 1; }

# ── 4. The source is untouched ────────────────────────────────────────────────
# The promise the whole design exists to earn, checked rather than assumed.
say "is the source untouched?"
NEWER=$(find "$SOURCE" -newer "$LIBRARY/.shelf/library.json" -type f | wc -l | tr -d ' ')
echo "  files in the source modified since the import began: $NEWER"
echo "  files in the source: $(find "$SOURCE" -type f | wc -l | tr -d ' ')"

# ── 5. Rebuild ────────────────────────────────────────────────────────────────
# The proof behind ADR 0001: the index is a cache, and this is what makes that
# claim true rather than hopeful.
say "erasing the index and rebuilding it from the folders"
/usr/bin/time -l "$TOOL" rebuild "$LIBRARY" 2>&1 | grep -Ev "^  *[0-9]+  " | tail -15

say "done"
echo "source:  $SOURCE"
echo "library: $LIBRARY"
echo ""
echo "To measure the window: make app, then open $LIBRARY in Shelf."
echo "To clean up: make synthetic-clean"
