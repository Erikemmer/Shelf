#!/bin/bash
# The strict round trip (`docs/adr/0021-…`) against EPUBs nobody here wrote.
#
# Every fixture `EPUBArchiveWriterTests` proves the writer against is built
# by the writer itself – which means none of them was ever compressed by
# anything else, and a real EPUB's `content.opf` always is. This is the
# proof against that gap: six public-domain books from Project Gutenberg
# (`Scripts/real-epubs.sh`), read with `ZipReader`, carried forward through
# `EPUBArchiveWriter` unchanged (`shelf-tool epub-roundtrip`), and checked a
# second way entirely outside Shelf's own code
# (`Scripts/epub-crosscheck.py`, stdlib `zipfile` and `xml.etree`).
#
# Reads-only against the books: nothing here is written back over an
# original, and nothing under ~/Library/Caches/Shelf/real-epubs-10/ is ever
# touched except by Scripts/real-epubs.sh fetching it in the first place.
#
# Usage: Scripts/real-epub-proof.sh [books folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BOOKS="${1:-$HOME/Library/Caches/Shelf/real-epubs-10}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/debug/shelf-tool"
OUTPUT="$BOOKS/roundtripped"

say() { printf '\n══ %s\n' "$1"; }
fail() { echo "real-epub-proof: FAILED – $1" >&2; exit 1; }

say "0. The books"
"$HERE/real-epubs.sh" "$BOOKS" || fail \
    "could not fetch all six books – see above. Re-run once the network is reachable, or pass an existing folder."

say "1. shelf-tool"
[ -x "$TOOL" ] || swift build --package-path "$ROOT" --scratch-path "$SCRATCH" || fail "could not build shelf-tool"

say "2. The strict round trip"
rm -rf "$OUTPUT"
"$TOOL" epub-roundtrip "$BOOKS" "$OUTPUT"
ROUNDTRIP_STATUS=$?

say "3. The cross-check — a different implementation entirely (python3, stdlib zipfile + xml.etree)"
CROSSCHECK_FAILED=0
for original in "$BOOKS"/*.epub; do
    name="$(basename "$original")"
    roundtripped="$OUTPUT/$name"
    [ -f "$roundtripped" ] || {
        echo "  (skipped: $name has no round-tripped copy – the round trip above already reported why)"
        continue
    }
    python3 "$HERE/epub-crosscheck.py" "$original" "$roundtripped" || CROSSCHECK_FAILED=1
done

say "4. epubcheck, if it is already on this Mac"
if command -v epubcheck >/dev/null 2>&1; then
    EPUBCHECK_FAILED=0
    for roundtripped in "$OUTPUT"/*.epub; do
        epubcheck "$roundtripped" || EPUBCHECK_FAILED=1
    done
else
    echo "  not installed – not installing it, per instruction. Skipped."
    EPUBCHECK_FAILED=0
fi

say "Summary"
if [ "$ROUNDTRIP_STATUS" -ne 0 ] || [ "$CROSSCHECK_FAILED" -ne 0 ] || [ "$EPUBCHECK_FAILED" -ne 0 ]; then
    fail "at least one check above did not pass – see the sections it named"
fi
echo "real-epub-proof: every book round-tripped byte-identical per entry, and the cross-check agrees."
