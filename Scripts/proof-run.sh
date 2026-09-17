#!/bin/bash
# The Sprint 1 proof run, on the command line.
#
# It measures what can be measured without a window: generating 5 000 synthetic
# EPUBs, importing them with SHA-256 verification, reading the index, rebuilding
# the index from the folders, and – since Sprint 2a – making ten metadata
# changes to one book and checking that the book file survived them byte for
# byte while a rebuilt-from-scratch index still knows the rating.
#
# Section 7 is Sprint 2b's: 200 books get a new title, a new tag and a new
# description, one write each, and the run reports the median and the worst
# case including the search index; then the 200 book files are hashed again,
# the new tag is searched for across the whole library, the index is thrown
# away, and every one of the 200 changes has to come back out of the folders.
#
# Section 8 is Sprint 2c's: twenty shelves in three levels, a thousand books
# distributed over them one assignment at a time, the sidebar's counts checked
# against SQL rather than against themselves, fifty books tagged and undone with
# every file compared byte for byte, and then the index thrown away again to see
# whether a thousand shelf memberships come back out of the folders.
#
# The window's own numbers – how long until every visible cover is on screen,
# and whether a held arrow key stutters – need the app open. `SHELF_TIMING=1`
# and `docs/BACKLOG.md` say how.
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

# Always, not only when the binary is missing. A release build left over from
# an earlier sprint is the worst of both: it runs, it measures something, and it
# does not have the commands this run needs — section 8 failed with "could not
# shelve" against a `shelf-tool` that had never heard of shelves. SwiftPM does
# nothing when it is already up to date.
echo "building shelf-tool in release – a debug build measures the wrong thing"
swift build -c release --scratch-path "$SCRATCH" >/dev/null || {
    echo "could not build shelf-tool" >&2
    exit 1
}
[ -x "$TOOL" ] || { echo "no shelf-tool at $TOOL" >&2; exit 1; }

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

# ── 6. Editing: the folder is still the truth ────────────────────────────────
# The Sprint 2 form of ADR 0001. Ten metadata changes to one book, then three
# questions: did the book file survive them byte for byte, did the metadata.opf
# actually change, and does a rebuilt-from-scratch index still know the rating
# and the read status?
say "ten metadata changes, and what they did and did not touch"
# The empty search term means "the first book in title order", so the same book
# is named before and after the rebuild without knowing what the generator made.
BEFORE_SHOW=$("$TOOL" show "$LIBRARY" "" 2>/dev/null)
TITLE=$(echo "$BEFORE_SHOW" | sed -n 's/^title: *//p')
FOLDER=$(echo "$BEFORE_SHOW" | sed -n 's/^folder: *//p')
BOOK_DIR="$LIBRARY/$FOLDER"
EPUB=$(find "$BOOK_DIR" -name "*.epub" 2>/dev/null | head -1)
if [ -z "$EPUB" ] || [ -z "$TITLE" ]; then
    echo "  no book to edit – skipping"
else
    echo "  book:  $TITLE"
    EPUB_BEFORE=$("$TOOL" digest "$EPUB")
    OPF_BEFORE=$("$TOOL" digest "$BOOK_DIR/metadata.opf")
    echo "  epub before: $EPUB_BEFORE"

    for round in 1 2 3 4 5 6 7 8 9 10; do
        STARS=$((round % 6))
        READ=$([ $((round % 2)) -eq 0 ] && echo yes || echo no)
        "$TOOL" edit "$LIBRARY" "" "$STARS" "$READ" >/dev/null || {
            echo "  edit $round failed" >&2
            exit 1
        }
    done
    # The last round: 10 % 6 = 4 stars, read=yes. That is what has to come back
    # out of a rebuilt index.
    EPUB_AFTER=$("$TOOL" digest "$EPUB")
    OPF_AFTER=$("$TOOL" digest "$BOOK_DIR/metadata.opf")
    echo "  epub after:  $EPUB_AFTER"
    if [ "$EPUB_BEFORE" = "$EPUB_AFTER" ]; then
        echo "  the book file is untouched after ten metadata changes ✓"
    else
        echo "  THE BOOK FILE CHANGED – this must never happen" >&2
        exit 1
    fi
    if [ "$OPF_BEFORE" != "$OPF_AFTER" ]; then
        echo "  metadata.opf changed, as it must ✓"
    else
        echo "  metadata.opf did not change – the edits went nowhere" >&2
        exit 1
    fi

    say "throwing the index away and asking the folders again"
    "$TOOL" rebuild "$LIBRARY" 2>&1 | tail -4
    REBUILT=$("$TOOL" show "$LIBRARY" "")
    echo "$REBUILT" | grep -E "^(title|stars|rating|read):"
    STARS_BACK=$(echo "$REBUILT" | awk '/^stars:/ {print $2}')
    READ_BACK=$(echo "$REBUILT" | awk '/^read:/ {print $2}')
    if [ "$STARS_BACK" = "4" ] && [ "$READ_BACK" = "true" ]; then
        echo "  the rebuilt index found the same rating and read status ✓"
    else
        echo "  the rebuild lost the edit: stars=$STARS_BACK read=$READ_BACK (wanted 4 / true)" >&2
        exit 1
    fi
fi

# ── 7. Sprint 2b: 200 books edited, and what it cost ─────────────────────────
# The questions the Sprint 2b brief asks about a full library, in order: what
# does a change cost including the search index, did the book files survive,
# how long does a search over 5 000 books take, and does a rebuilt-from-scratch
# index still know every change.
#
# 200 books rather than one, because the interesting number is not the average
# but the worst case, and one write cannot have one.
EDIT_COUNT="${EDIT_COUNT:-200}"
say "$EDIT_COUNT books: title, tags and description each"

DIGESTS_BEFORE="$ROOT/epub-digests-before.txt"
DIGESTS_AFTER="$ROOT/epub-digests-after.txt"
"$TOOL" epub-digests "$LIBRARY" "$EDIT_COUNT" > "$DIGESTS_BEFORE"
echo "  hashed $(wc -l < "$DIGESTS_BEFORE" | tr -d ' ') book files before touching anything"

"$TOOL" bulk-edit "$LIBRARY" "$EDIT_COUNT" || { echo "the bulk edit failed" >&2; exit 1; }

say "are those $EDIT_COUNT book files still byte for byte what they were?"
"$TOOL" epub-digests "$LIBRARY" "$EDIT_COUNT" > "$DIGESTS_AFTER"
if diff -q "$DIGESTS_BEFORE" "$DIGESTS_AFTER" >/dev/null; then
    echo "  every one of them is unchanged ✓"
else
    echo "  A BOOK FILE CHANGED – this must never happen" >&2
    diff "$DIGESTS_BEFORE" "$DIGESTS_AFTER" | head -20 >&2
    exit 1
fi

say "searching the whole library for a tag that did not exist five seconds ago"
"$TOOL" search-time "$LIBRARY" proof-run-2b 20

say "throwing the index away again, and asking the folders about all $EDIT_COUNT"
"$TOOL" rebuild "$LIBRARY" 2>&1 | tail -3
"$TOOL" verify-edits "$LIBRARY" "$EDIT_COUNT" || exit 1

# ── 8. Sprint 2c: shelves, at a thousand books ───────────────────────────────
# Twenty shelves in three levels, because the interesting cases are a shelf
# inside a shelf inside a shelf (does the stored path survive a rebuild?) and a
# shelf with nothing on it (only `library.json` can remember that one).
SHELVED="${SHELVED:-1000}"
say "twenty shelves, three levels deep, and $SHELVED books spread over them"

"$TOOL" unshelve "$LIBRARY" >/dev/null

# Four top shelves, twelve in the second level, four in the third: twenty.
# `shelve` makes whatever levels are missing, so the tree is built by using it.
# Ten paths, which make sixteen shelves — the intermediate levels (`Fiction`,
# `Non-Fiction`, `Reference`) come into being on the way. The two empty pairs
# below bring it to twenty.
SHELF_PATHS=(
    "Fiction/Science Fiction/Space Opera"
    "Fiction/Science Fiction/Hard SF"
    "Fiction/Crime/Nordic"
    "Fiction/Crime/Cosy"
    "Fiction/Literary"
    "Non-Fiction/History/Ancient"
    "Non-Fiction/Science"
    "Non-Fiction/Biography"
    "Reference/Dictionaries"
    "To Read"
)
PER_SHELF=$((SHELVED / ${#SHELF_PATHS[@]}))
OFFSET=0
ASSIGN_LOG="$ROOT/shelf-timings.txt"
: > "$ASSIGN_LOG"
for path in "${SHELF_PATHS[@]}"; do
    "$TOOL" shelve "$LIBRARY" "$path" "$PER_SHELF" "$OFFSET" >> "$ASSIGN_LOG" || {
        echo "could not shelve onto $path" >&2
        exit 1
    }
    OFFSET=$((OFFSET + PER_SHELF))
done
# The empty ones, which no book can remember: only `library.json` can, which is
# the clearest single reason the shape is kept in a file of its own.
"$TOOL" shelve "$LIBRARY" "Someday/Maybe" 0 0 >> "$ASSIGN_LOG"
"$TOOL" shelve "$LIBRARY" "Archive/Boxed" 0 0 >> "$ASSIGN_LOG"

SHELF_COUNT=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "SELECT COUNT(*) FROM shelves")
EMPTY_SHELVES=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" \
    "SELECT COUNT(*) FROM shelves WHERE id NOT IN (SELECT shelf_id FROM book_shelves)")
DEEPEST=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "
    WITH RECURSIVE depth(id, level) AS (
        SELECT id, 1 FROM shelves WHERE parent_id IS NULL
        UNION ALL SELECT s.id, depth.level + 1 FROM shelves s JOIN depth ON s.parent_id = depth.id
    ) SELECT MAX(level) FROM depth")
echo "  shelves: $SHELF_COUNT, deepest nesting: $DEEPEST levels, with nothing on them: $EMPTY_SHELVES"

# One line per batch comes back from `shelve`; this reduces them to the three
# numbers worth reading. The worst single assignment is the one a person
# actually notices, so it is not averaged away.
WORST=$(grep "slowest" "$ASSIGN_LOG" | sed 's/.*slowest: //; s/ ms//' | sort -rn | head -1)
MEDIANS=$(grep "median" "$ASSIGN_LOG" | sed 's/.*median: //; s/ ms//' | sort -n)
MID=$(echo "$MEDIANS" | awk '{ v[NR]=$1 } END { print v[int((NR+1)/2)] }')
OVER=$(grep -c "over the 20 ms target: 0 of" "$ASSIGN_LOG")
BATCHES=$(grep -c "median" "$ASSIGN_LOG")
echo "  one assignment, over $SHELVED of them in $BATCHES batches (target under 20 ms):"
echo "    median of the batch medians: $MID ms"
echo "    worst single assignment:     $WORST ms"
echo "    batches with nothing over 20 ms: $OVER of $BATCHES"

say "does the sidebar's arithmetic agree with SQL?"
# The sidebar counts a shelf by walking the books it has in memory; this asks
# the database the same question a different way. Two answers that agree are
# worth something; the sidebar agreeing with itself is worth nothing.
for path in "Fiction" "Fiction/Science Fiction" "Non-Fiction" "To Read"; do
    VIA_SQL=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "
        WITH RECURSIVE ancestry(id, path) AS (
            SELECT id, name FROM shelves WHERE parent_id IS NULL
            UNION ALL SELECT s.id, ancestry.path || '/' || s.name
            FROM shelves s JOIN ancestry ON s.parent_id = ancestry.id
        )
        SELECT COUNT(DISTINCT bs.book_id) FROM book_shelves bs
        JOIN ancestry ON ancestry.id = bs.shelf_id
        WHERE ancestry.path = '$path' OR ancestry.path LIKE '$path/%'")
    echo "  $path: $VIA_SQL books (this shelf and everything inside it)"
done
TOTAL_SHELVED=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "SELECT COUNT(DISTINCT book_id) FROM book_shelves")
NOT_SHELVED=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" \
    "SELECT COUNT(*) FROM books WHERE id NOT IN (SELECT book_id FROM book_shelves)")
INDEXED=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "SELECT COUNT(*) FROM books")
echo "  on a shelf: $TOTAL_SHELVED · on none: $NOT_SHELVED · sum: $((TOTAL_SHELVED + NOT_SHELVED)) of $INDEXED"
[ "$((TOTAL_SHELVED + NOT_SHELVED))" = "$INDEXED" ] || {
    echo "  the two do not add up to the library" >&2
    exit 1
}

say "fifty books tagged at once, then undone – every file compared"
"$TOOL" bulk-tag-undo "$LIBRARY" 50 proof-run-2c || exit 1

say "throwing the index away, and asking the folders about $SHELVED shelvings"
"$TOOL" rebuild "$LIBRARY" 2>&1 | tail -4
SHELVED_BACK=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "SELECT COUNT(DISTINCT book_id) FROM book_shelves")
SHELVES_BACK=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "SELECT COUNT(*) FROM shelves")
EMPTY_BACK=$(sqlite3 "$LIBRARY/.shelf/library.sqlite" "SELECT COUNT(*) FROM shelves WHERE name = 'Maybe'")
echo "  books back on a shelf: $SHELVED_BACK of $TOTAL_SHELVED"
echo "  shelves back: $SHELVES_BACK of $SHELF_COUNT (the empty one among them: $EMPTY_BACK)"
if [ "$SHELVED_BACK" = "$TOTAL_SHELVED" ] && [ "$SHELVES_BACK" = "$SHELF_COUNT" ] \
    && [ "$EMPTY_BACK" = "1" ]; then
    echo "  every shelving came back out of the folders, and the empty shelf out of library.json ✓"
else
    echo "  THE REBUILD LOST SHELVES" >&2
    exit 1
fi

say "done"
echo "source:  $SOURCE"
echo "library: $LIBRARY"
echo ""
echo "To measure the window: make app, then open $LIBRARY in Shelf."
echo "To clean up: make synthetic-clean"
