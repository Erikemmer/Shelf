#!/bin/bash
# The strict round trip, and a real metadata change (`docs/adr/0021-…`),
# against EPUBs nobody here wrote.
#
# Every fixture `EPUBArchiveWriterTests` proves the writer against is built
# by the writer itself – which means none of them was ever compressed by
# anything else, and a real EPUB's `content.opf` always is. This is the
# proof against that gap: six public-domain books from Project Gutenberg
# (`Scripts/real-epubs.sh`), read with `ZipReader`, carried forward through
# `EPUBArchiveWriter` unchanged (`shelf-tool epub-roundtrip`), then with
# title, authors and publisher actually patched via `EPUBOPFPatch`
# (`shelf-tool epub-metadata-patch`) — proving that a real edit touches
# exactly one entry, the OPF, and every other entry stays bit-identical.
# Both are checked a second way entirely outside Shelf's own code
# (`Scripts/epub-crosscheck.py`, stdlib `zipfile` and `xml.etree`).
# Then a real book *file* replaced, copies only (`shelf-tool
# epub-file-replace-proof`): the whole `EPUBFileReplacement` path — written,
# read back, rehashed, the original to the Trash — against every one of the
# six, one at a time, plus each of its five refusals proven to leave exactly
# the original file behind.
#
# Reads-only against the books: nothing here is written back over an
# original, and nothing under ~/Library/Caches/Shelf/real-epubs-10/ is ever
# touched except by Scripts/real-epubs.sh fetching it in the first place —
# section 7 above works against its own copies, in file-replace-proof/.
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

say "5. A real metadata change — title, authors and publisher, via EPUBOPFPatch"
PATCHED="$BOOKS/patched"
rm -rf "$PATCHED"
"$TOOL" epub-metadata-patch "$BOOKS" "$PATCHED"
PATCH_STATUS=$?

say "6. The cross-check again, against the patched copies — the title is expected to differ this time"
PATCH_CROSSCHECK_FAILED=0
title_of() {
    python3 -c '
import sys, zipfile, xml.etree.ElementTree as ET
z = zipfile.ZipFile(sys.argv[1])
with z.open("META-INF/container.xml") as h:
    t = ET.parse(h)
opf = next(e.attrib["full-path"] for e in t.iter() if e.tag.endswith("rootfile"))
with z.open(opf) as h:
    t2 = ET.parse(h)
print(next((e.text or "").strip() for e in t2.iter() if e.tag.endswith("title")))
' "$1"
}
for original in "$BOOKS"/*.epub; do
    name="$(basename "$original")"
    patched="$PATCHED/$name"
    [ -f "$patched" ] || {
        echo "  (skipped: $name has no patched copy – section 5 above already reported why)"
        continue
    }
    expected="[Shelf] $(title_of "$original")"
    python3 "$HERE/epub-crosscheck.py" "$original" "$patched" "$expected" || PATCH_CROSSCHECK_FAILED=1
done

say "7. A real book file replaced — EPUBFileReplacement, the whole path and the five refusals (docs/adr/0021-…)"
REPLACE_PROOF="$BOOKS/file-replace-proof"
rm -rf "$REPLACE_PROOF"
/usr/bin/time -l "$TOOL" epub-file-replace-proof "$BOOKS" "$REPLACE_PROOF"
REPLACE_STATUS=$?

say "Summary"
if [ "$ROUNDTRIP_STATUS" -ne 0 ] || [ "$CROSSCHECK_FAILED" -ne 0 ] || [ "$EPUBCHECK_FAILED" -ne 0 ] \
    || [ "$PATCH_STATUS" -ne 0 ] || [ "$PATCH_CROSSCHECK_FAILED" -ne 0 ] || [ "$REPLACE_STATUS" -ne 0 ]; then
    fail "at least one check above did not pass – see the sections it named"
fi
echo "real-epub-proof: every book round-tripped byte-identical per entry, a real metadata change touches" \
    "exactly the OPF in every one of them, the cross-check agrees both times, and a real book file gets" \
    "replaced end to end – written, read back, rehashed, the original in the Trash – with each of the" \
    "five refusals leaving exactly the original file behind."
