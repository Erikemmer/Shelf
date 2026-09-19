#!/bin/bash
# Builds the library the cover screenshots are taken against.
#
# Small — a handful of books — because a screenshot has to be readable. What
# this library has that a plain generated one does not is the three starting
# states the cover actions have to be photographed from:
#
#   * a book with a cover, to be replaced
#   * a book with *no* cover, so the first-cover case can be seen
#   * books in several formats, because `Take Cover from Book File` has to
#     ask which format when a book has more than one, and a PDF's page 1 and
#     a CBZ's first image go down two different readers
#
# It also writes the pictures the run drops and chooses: a big one, to prove
# the size ceiling does something, and a HEIC-shaped case is left to the
# report rather than faked here.
#
# Everything lands under ~/Library/Caches/Shelf, never under ~/Documents, and
# only in the folder named below — which this script creates and is therefore
# allowed to replace (CLAUDE.md).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$HOME/Library/Caches/Shelf/cover-library-9}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/release/shelf-tool"

echo "building shelf-tool in release"
swift build -c release --scratch-path "$SCRATCH" >/dev/null || {
    echo "could not build shelf-tool" >&2
    exit 1
}

SOURCE="$ROOT/source"
LIBRARY="$ROOT/library"
PICTURES="$ROOT/pictures"
rm -rf "$ROOT"
mkdir -p "$ROOT" "$PICTURES"

echo "── six books, each an EPUB with a cover"
"$TOOL" synthesise "$SOURCE" 6 | tail -1
"$TOOL" import "$SOURCE" "$LIBRARY" | tail -1

# `synthesise-mixed` is the deliberately-broken corpus — truncated files, wrong
# bytes, DRM — and most of it is the wrong material for a screenshot. One book
# in it is not broken and is the only one here that exists as four formats at
# once, which is the case `Take Cover from Book File` has to ask a question
# about. Only that one is imported.
echo "── and one book that is an EPUB, an AZW3, a MOBI and a PDF at once"
MIXED="$ROOT/mixed"
"$TOOL" synthesise-mixed "$MIXED" 2 >/dev/null 2>&1
FOUR="$ROOT/four-formats"
mkdir -p "$FOUR"
cp "$MIXED"/"The Ministry Called Peace #1 - Jane Le Guin".* "$FOUR"/ 2>/dev/null
"$TOOL" import "$FOUR" "$LIBRARY" | tail -1
rm -rf "$MIXED" "$FOUR"

echo "── one book loses its cover, so the first-cover case can be photographed"
FIRST_COVER="$(find "$LIBRARY" -name 'cover.*' -not -path '*/.shelf/*' | sort | head -1)"
if [ -n "$FIRST_COVER" ]; then
    rm -f "$FIRST_COVER"
    echo "  removed $(basename "$(dirname "$FIRST_COVER")")/$(basename "$FIRST_COVER")"
fi

echo "── the pictures the run sets as covers"
# Drawn here rather than borrowed: no picture that is not this project's own
# goes into this repository or into a run of it (CLAUDE.md).
/usr/bin/swift "$HERE/cover-pictures.swift" "$PICTURES" || {
    echo "could not draw the test pictures" >&2
    exit 1
}

echo
echo "library:  $LIBRARY"
echo "pictures: $PICTURES"
ls -l "$PICTURES" | tail -n +2 | awk '{printf "  %-22s %8.1f KB\n", $9, $5/1024}'
echo "books with a cover: $(find "$LIBRARY" -name 'cover.*' -not -path '*/.shelf/*' | wc -l | tr -d ' ') of $(find "$LIBRARY" -name 'metadata.opf' | wc -l | tr -d ' ')"
