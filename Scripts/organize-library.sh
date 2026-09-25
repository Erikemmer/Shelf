#!/bin/bash
# Builds the library the Sprint 8 screenshots are taken against.
#
# Small — 16 books — because a screenshot has to be readable, and because the
# arithmetic is proved against 5 000 books by `proof-run.sh` section 12 rather
# than here. What this library has that a generated one does not is the *mess*:
# one author under three spellings, a shelf tree, a few books read, and a
# folder sitting exactly where a book wants to go.
#
# Sixteen and not thirty for a reason found by taking the pictures: the sidebar
# caps each section at twelve rows, and with thirty books the tag list alone was
# eleven of them, which put the Authors section — the one the merge is opened
# from — *below the window*. A right-click below the window opens nothing, and
# says nothing about having opened nothing.
#
# Everything lands under ~/Library/Caches/Shelf, never under ~/Documents.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$HOME/Library/Caches/Shelf/measure-library-8/shots}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/release/shelf-tool"

echo "building shelf-tool in release"
swift build -c release --scratch-path "$SCRATCH" >/dev/null || {
    echo "could not build shelf-tool" >&2
    exit 1
}

SOURCE="$ROOT/source"
LIBRARY="$ROOT/library"
rm -rf "$ROOT"
mkdir -p "$ROOT"

echo "── 16 books"
"$TOOL" synthesise "$SOURCE" 16 | tail -1
"$TOOL" import "$SOURCE" "$LIBRARY" | tail -1

echo "── one author, three spellings, over nine books"
SPELLINGS=("Marek Voss" "Voss, Marek" "M. Voss")
N=0
while IFS= read -r TITLE; do
    "$TOOL" set-author "$LIBRARY" "$TITLE" "${SPELLINGS[$((N % 3))]}" >/dev/null 2>&1
    N=$((N + 1))
done < <("$TOOL" first-titles "$LIBRARY" 9)
"$TOOL" names "$LIBRARY" author | grep Voss | sed 's/^/  /'

echo "── shelves, and a few books read"
"$TOOL" shelve "$LIBRARY" "Fiction/Sci-Fi" 5 >/dev/null 2>&1
"$TOOL" shelve "$LIBRARY" "To Read" 3 10 >/dev/null 2>&1
while IFS= read -r TITLE; do
    "$TOOL" edit "$LIBRARY" "$TITLE" 4 yes >/dev/null 2>&1
done < <("$TOOL" first-titles "$LIBRARY" 4)

echo "── something in the way of a move, so the preview has an obstacle to name"
# The authors have just been changed, so those books' folders are now stale and
# an organise wants to move them. One of them gets a folder put in its way.
"$TOOL" make-collision "$LIBRARY" exact 2>&1 | sed 's/^/  /'

echo ""
"$TOOL" organize "$LIBRARY" 2>&1 | grep -E "folds case|^plan" | sed 's/^/  /'
echo ""
echo "library: $LIBRARY"
echo "Now: make app, then Scripts/organize-shot.sh"
