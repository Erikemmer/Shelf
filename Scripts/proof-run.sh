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
# Section 10 is Sprint 4's other half: a library of every format Shelf reads —
# EPUB, MOBI, AZW3, PDF and CBZ, with DRM-marked and deliberately damaged files
# among them — imported in one run, then the index thrown away and rebuilt. No
# CBR: nothing on this Mac can write a RAR, so none was measured.
#
# Section 9 is Sprint 4's: an import is killed in the middle, resumed, and the
# library has to end with one folder per book and nothing nobody points at.
#
# Section 8 is Sprint 2c's: twenty shelves in three levels, a thousand books
# distributed over them one assignment at a time, the sidebar's counts checked
# against SQL rather than against themselves, fifty books tagged and undone with
# every file compared byte for byte, and then the index thrown away again to see
# whether a thousand shelf memberships come back out of the folders.
#
# Section 11 is Sprint 5's: four e-readers made out of disk images (hdiutil,
# FAT32 and HFS+), detected by their markers, sent 200 books with SHA-256 read
# back off the device, interrupted and resumed, filled up, read back from a
# synthetic KoboReader.sqlite, and finally deleted from — on a confirmation that
# names every file. The library is checked afterwards with `find -newer` and
# sample hashes: nothing Shelf does to a device may touch it. What still needs
# real hardware is in docs/BACKLOG.md under "To check on real hardware".
#
# The window's own numbers – how long until every visible cover is on screen,
# and whether a held arrow key stutters – need the app open. `SHELF_TIMING=1`
# and `docs/BACKLOG.md` say how.
#
# Everything lands under ~/Library/Caches/Shelf, never under ~/Documents: that
# folder is synced, and 5 000 generated books would be uploaded to iCloud.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
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

# ── 9. An interrupted import, and the folders it must not leave behind ───────
# Sprint 4's. A killed import leaves book folders the index never heard of, and
# before this section existed the next run planned those books again and gave
# them *second* folders — 23 of them in the Sprint 3 measuring run. Nothing was
# lost, which is exactly why nobody noticed.
#
# The kill is real: SHELF_EXIT_AFTER makes the process leave in the middle of
# the run, without unwinding and without writing its short last batch. Cancelling
# would be the tidy path, which leaves no orphans and would prove nothing.
say "an import killed in the middle, then resumed"
RESUME_SOURCE="$ROOT/resume-source"
RESUME_LIBRARY="$ROOT/resume-library"
RESUME_COUNT="${RESUME_COUNT:-400}"
rm -rf "$RESUME_SOURCE" "$RESUME_LIBRARY"
"$TOOL" synthesise "$RESUME_SOURCE" "$RESUME_COUNT" | tail -1

echo "  run 1, killed after 250 files:"
SHELF_EXIT_AFTER=250 "$TOOL" import "$RESUME_SOURCE" "$RESUME_LIBRARY" >/dev/null 2>&1
KILLED_STATUS=$?
echo "    the process left with status $KILLED_STATUS"

# What the kill left: folders on disk, fewer books in the index.
FOLDERS_AFTER_KILL=$(find "$RESUME_LIBRARY" -mindepth 2 -maxdepth 2 -type d -not -path "*/.shelf/*" | wc -l | tr -d ' ')
INDEXED_AFTER_KILL=$(sqlite3 "$RESUME_LIBRARY/.shelf/library.sqlite" "SELECT COUNT(*) FROM books")
ORPHANS_AFTER_KILL=$("$TOOL" orphans "$RESUME_LIBRARY" | grep "^orphaned folders:" | awk '{print $3}')
echo "    folders on disk: $FOLDERS_AFTER_KILL"
echo "    books in the index: $INDEXED_AFTER_KILL"
echo "    folders no book points at: $ORPHANS_AFTER_KILL"
if [ "${ORPHANS_AFTER_KILL:-0}" -lt 1 ]; then
    echo "  the kill left nothing behind – this section proves nothing as it stands" >&2
    exit 1
fi

echo "  run 2, the resume:"
"$TOOL" import "$RESUME_SOURCE" "$RESUME_LIBRARY" 2>&1 | grep -E "orphaned folders found|plan:|Verified|new book" | sed "s/^/    /"

FOLDERS_AFTER=$(find "$RESUME_LIBRARY" -mindepth 2 -maxdepth 2 -type d -not -path "*/.shelf/*" | wc -l | tr -d ' ')
INDEXED_AFTER=$(sqlite3 "$RESUME_LIBRARY/.shelf/library.sqlite" "SELECT COUNT(*) FROM books")
ORPHANS_AFTER=$("$TOOL" orphans "$RESUME_LIBRARY" | grep "^orphaned folders:" | awk '{print $3}')
# A doubled book would show up as two rows with the same title and author.
DOUBLED=$(sqlite3 "$RESUME_LIBRARY/.shelf/library.sqlite" \
    "SELECT COUNT(*) FROM (SELECT title FROM books GROUP BY title HAVING COUNT(*) > 1)")
echo "    folders on disk: $FOLDERS_AFTER (expected $RESUME_COUNT)"
echo "    books in the index: $INDEXED_AFTER (expected $RESUME_COUNT)"
echo "    folders no book points at: $ORPHANS_AFTER (expected 0)"
echo "    titles appearing twice: $DOUBLED (expected 0)"

if [ "$FOLDERS_AFTER" = "$RESUME_COUNT" ] && [ "$INDEXED_AFTER" = "$RESUME_COUNT" ] \
    && [ "${ORPHANS_AFTER:-1}" = "0" ] && [ "$DOUBLED" = "0" ]; then
    echo "  one folder per book, nothing doubled, nothing orphaned ✓"
else
    echo "  THE RESUME LEFT DEBRIS BEHIND" >&2
    exit 1
fi

# ── 10. Every format, including the broken ones ──────────────────────────────
# Sprint 4's. A library holding EPUB, MOBI, AZW3, PDF and CBZ, with DRM-marked
# and deliberately damaged files mixed in, imported in one run — then the index
# thrown away and rebuilt, which is where the DRM badges were found to vanish.
#
# Not written and therefore not measured: CBR. A RAR is a proprietary
# compressed format and this Mac has no tool that can make one.
say "a library of every format Shelf reads, damaged files and all"
MIXED_SOURCE="$ROOT/mixed-source"
MIXED_LIBRARY="$ROOT/mixed-library"
MIXED_COUNT="${MIXED_COUNT:-500}"
rm -rf "$MIXED_SOURCE" "$MIXED_LIBRARY"
"$TOOL" synthesise-mixed "$MIXED_SOURCE" "$MIXED_COUNT" | tail -14

say "importing the mixed library"
/usr/bin/time -l "$TOOL" import "$MIXED_SOURCE" "$MIXED_LIBRARY" 2>&1 \
    | grep -Ev "^  *[0-9]+  " | grep -E "^plan:|^Verified|^  [A-Z]+: |new books|formats added|real|maximum resident"
echo "  library size: $(LC_ALL=C du -sh "$MIXED_LIBRARY" | awk '{print $1}')"

MIXED_DB="$MIXED_LIBRARY/.shelf/library.sqlite"
say "what the index holds"
sqlite3 "$MIXED_DB" "SELECT '  ' || format || ': ' || COUNT(*) FROM formats GROUP BY format ORDER BY format"
MIXED_BOOKS=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM books")
MIXED_FILES=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM formats")
MIXED_MULTI=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM (SELECT book_id FROM formats GROUP BY book_id HAVING COUNT(*) > 1)")
MIXED_DRM=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM formats WHERE drm IS NOT NULL")
ON_DISK=$(find "$MIXED_SOURCE" -type f | wc -l | tr -d ' ')
echo "  books: $MIXED_BOOKS · files: $MIXED_FILES of $ON_DISK on disk · books with several files: $MIXED_MULTI"
echo "  files carrying DRM: $MIXED_DRM"

if [ "$MIXED_FILES" = "$ON_DISK" ]; then
    echo "  every file in the source reached the index ✓"
else
    echo "  THE INDEX IS MISSING FILES" >&2
    exit 1
fi

say "is the mixed source untouched?"
NEWER=$(find "$MIXED_SOURCE" -newer "$MIXED_LIBRARY/.shelf/library.json" -type f | wc -l | tr -d ' ')
echo "  files in the source modified since the import began: $NEWER"
[ "$NEWER" = "0" ] || { echo "  THE SOURCE WAS TOUCHED" >&2; exit 1; }

say "one digest per format, against /usr/bin/shasum"
FAILED=0
for EXT in epub mobi azw3 pdf cbz; do
    FILE=$(find "$MIXED_SOURCE" -name "*.$EXT" | head -1)
    [ -n "$FILE" ] || continue
    OURS=$("$TOOL" digest "$FILE")
    THEIRS=$(shasum -a 256 "$FILE" | awk '{print $1}')
    IN_INDEX=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM formats WHERE sha256 = '$THEIRS'")
    if [ "$OURS" = "$THEIRS" ] && [ "${IN_INDEX:-0}" -gt 0 ]; then
        echo "  $EXT: shelf and shasum agree, and the index has it"
    else
        echo "  $EXT: MISMATCH ($OURS vs $THEIRS, in index: $IN_INDEX)"
        FAILED=1
    fi
done
[ "$FAILED" = "0" ] || { echo "digests disagree – stopping" >&2; exit 1; }

# The rebuild is where the DRM badges were found to disappear: the importer
# detected them and stored them, and a rebuild set every one back to nothing.
say "throwing the mixed index away and rebuilding it from the folders"
/usr/bin/time -l "$TOOL" rebuild "$MIXED_LIBRARY" 2>&1 | grep -Ev "^  *[0-9]+  " | tail -8
BOOKS_BACK=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM books")
FILES_BACK=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM formats")
DRM_BACK=$(sqlite3 "$MIXED_DB" "SELECT COUNT(*) FROM formats WHERE drm IS NOT NULL")
echo "  books back: $BOOKS_BACK of $MIXED_BOOKS"
echo "  files back: $FILES_BACK of $MIXED_FILES"
echo "  DRM badges back: $DRM_BACK of $MIXED_DRM"
if [ "$BOOKS_BACK" = "$MIXED_BOOKS" ] && [ "$FILES_BACK" = "$MIXED_FILES" ] \
    && [ "$DRM_BACK" = "$MIXED_DRM" ]; then
    echo "  the folders gave everything back, badges included ✓"
else
    echo "  THE REBUILD LOST SOMETHING" >&2
    exit 1
fi


# ── 11. Devices (Sprint 5) ────────────────────────────────────────────────────
#
# Four readers out of disk images. `Scripts/device-images.sh` makes them, and
# only ever detaches the four it made — a session never ends something it did
# not start (CLAUDE.md).
#
# `SKIP_DEVICES=1` leaves this out, for a run on a Mac where hdiutil is not
# available or where somebody is using the volume names.
if [ "${SKIP_DEVICES:-0}" = "1" ]; then
    say "devices: skipped (SKIP_DEVICES=1)"
else
DEVICE_ROOT="${DEVICE_ROOT:-$HOME/Library/Caches/Shelf/measure-library-5}"
DEVICE_SOURCE="$DEVICE_ROOT/device-source"
DEVICE_LIBRARY="$DEVICE_ROOT/device-library"
DEVICE_COUNT="${DEVICE_COUNT:-200}"
IMAGES="$HERE/device-images.sh"

device_fail() { echo "  $1" >&2; "$IMAGES" unmount >/dev/null 2>&1; exit 1; }

say "making four e-readers out of disk images"
"$IMAGES" unmount >/dev/null 2>&1
# Fresh cards every run, or the timings measure nothing: the second run over a
# Kobo that already holds the books correctly sends none of them, which is the
# *resume* being proved two steps further down and not a transfer. By name, and
# only the ones this script makes — a folder in the cache is not a folder to
# empty (CLAUDE.md).
for IMAGE in KOBOeReader Kindle tolino PocketBook KindleSmall; do
    rm -f "$DEVICE_ROOT/device-images/$IMAGE.dmg"
done
"$IMAGES" make "$DEVICE_ROOT/device-images" || device_fail "could not make the disk images"

say "which volumes are readers, and which are not"
"$TOOL" devices
# The Mac's own disk must not be one of them. It was, on the first run: APFS is
# case-insensitive, so `/System` and `/Applications` answered a PocketBook's
# markers. Checked here as well as in the unit test, because this is the shape
# of the mistake that only shows up against a real file system.
if "$TOOL" devices | grep -A2 "Macintosh HD" | grep -q "device: [A-Z]"; then
    device_fail "THE BOOT DISK WAS TAKEN FOR A READER"
fi
for NAME in KOBOEREADER KINDLE tolino POCKETBOOK; do
    "$TOOL" devices | grep -A2 "/Volumes/$NAME$" | grep -q "device: " \
        || device_fail "$NAME was not recognised"
done
echo "  all four recognised, and the boot disk is not one of them ✓"

say "a library of $DEVICE_COUNT books in every format, to send"
if [ ! -f "$DEVICE_LIBRARY/.shelf/library.json" ]; then
    rm -rf "$DEVICE_SOURCE" "$DEVICE_LIBRARY"
    "$TOOL" synthesise-mixed "$DEVICE_SOURCE" "$DEVICE_COUNT" | tail -3
    mkdir -p "$DEVICE_LIBRARY"
    "$TOOL" import "$DEVICE_SOURCE" "$DEVICE_LIBRARY" | tail -2
else
    echo "  $DEVICE_LIBRARY is already there – left alone"
fi
DEVICE_DB="$DEVICE_LIBRARY/.shelf/library.sqlite"
LIB_FILES_BEFORE=$(find "$DEVICE_LIBRARY" -type f | wc -l | tr -d ' ')
# A marker whose timestamp every later `find -newer` is measured against.
touch "$DEVICE_ROOT/.before-devices"
echo "  library: $LIB_FILES_BEFORE files"

say "sending 250 books to the Kobo, verified on the device"
/usr/bin/time -l "$TOOL" send "$DEVICE_LIBRARY" /Volumes/KOBOEREADER 250 2>&1 \
    | grep -Ev "^  *[0-9]+  |^  [0-9]+ / " | tail -12
"$TOOL" send "$DEVICE_LIBRARY" /Volumes/KOBOEREADER 250 2>&1 | tail -1 | grep -q "nothing to send" \
    || device_fail "THE SECOND RUN WANTED TO SEND SOMETHING AGAIN"
echo "  a second run sends nothing – the manifest on the card is the resume ✓"

say "the same books to a Kindle, which reads neither EPUB nor CBZ"
"$TOOL" send "$DEVICE_LIBRARY" /Volumes/KINDLE 250 2>&1 | grep -Ev "^  [0-9]+ / " | tail -16
ON_KINDLE=$(ls /Volumes/KINDLE/documents 2>/dev/null | wc -l | tr -d ' ')
ls /Volumes/KINDLE/documents 2>/dev/null | grep -q "\.epub$" \
    && device_fail "AN EPUB WAS WRITTEN TO A KINDLE"
echo "  $ON_KINDLE files on the Kindle, not one of them an EPUB ✓"

say "the names on a FAT32 card"
LONGEST=$(ls /Volumes/KINDLE/documents | awk '{ print length($0), $0 }' | sort -rn | head -1)
echo "  longest name: ${LONGEST%% *} characters"
BAD=$(ls /Volumes/KINDLE/documents | LC_ALL=C grep -c '[\\:*?"<>|]' || true)
echo "  names holding a character FAT refuses: $BAD"
[ "${BAD:-0}" = "0" ] || device_fail "A FORBIDDEN CHARACTER REACHED THE CARD"
OVERLONG=$(ls /Volumes/KINDLE/documents | while IFS= read -r n; do
    printf '%s' "$n" | wc -c
done | sort -rn | head -1)
echo "  longest name in bytes: $(echo "$OVERLONG" | tr -d ' ')"
[ "$(echo "$OVERLONG" | tr -d ' ')" -le 255 ] || device_fail "A NAME IS LONGER THAN 255 BYTES"
echo "  every name fits FAT's budget, and none carries a character it refuses ✓"

say "a transfer killed in the middle, and then resumed"
SHELF_EXIT_AFTER=40 "$TOOL" send "$DEVICE_LIBRARY" /Volumes/POCKETBOOK 120 2>&1 \
    | grep -Ev "^  [0-9]+ / |^    " | tail -3
AFTER_KILL=$(ls /Volumes/POCKETBOOK/Books 2>/dev/null | wc -l | tr -d ' ')
PARTS=$(find /Volumes/POCKETBOOK -name "*.part" | wc -l | tr -d ' ')
echo "  on the card after the kill: $AFTER_KILL books, $PARTS half-written files"
# A file left half-written by a kill *during* a copy, which the untidy exit
# above cannot produce on its own — it stops between files. Planted, so the
# next run's cleaning is measured rather than assumed.
head -c 4096 /Volumes/POCKETBOOK/Books/*.epub > "/Volumes/POCKETBOOK/Books/.shelf-send-deadbeef.part" 2>/dev/null
"$TOOL" send "$DEVICE_LIBRARY" /Volumes/POCKETBOOK 120 2>&1 | grep -Ev "^  [0-9]+ / |^    " | tail -4
RESUMED=$(ls /Volumes/POCKETBOOK/Books | wc -l | tr -d ' ')
PARTS_AFTER=$(find /Volumes/POCKETBOOK -name "*.part" | wc -l | tr -d ' ')
echo "  after the resume: $RESUMED books, $PARTS_AFTER half-written files"
[ "$RESUMED" = "120" ] || device_fail "THE RESUME DID NOT FINISH THE TRANSFER"
[ "$PARTS_AFTER" = "0" ] || device_fail "A HALF-WRITTEN FILE WAS LEFT ON THE DEVICE"
echo "  the resume copied only what was missing and swept up what a kill left ✓"

say "a card with no room left"
"$IMAGES" small "$DEVICE_ROOT/device-images" 3 | tail -2
SMALL=/Volumes/KINDLESMALL
"$TOOL" send "$DEVICE_LIBRARY" "$SMALL" 250 2>&1 | grep -Ev "^    |^  [0-9]+ / " | tail -4
WRITTEN=$(ls "$SMALL/documents" 2>/dev/null | wc -l | tr -d ' ')
echo "  files written: $WRITTEN"
[ "$WRITTEN" = "0" ] || device_fail "SOMETHING WAS COPIED ONTO A FULL CARD"
"$TOOL" send "$DEVICE_LIBRARY" "$SMALL" 20 2>&1 | grep -Ev "^    |^  [0-9]+ / " | tail -3
echo "  refused before the first byte, and a plan that fits still goes ✓"

say "reading a Kobo back – progress, shelves and read status"
"$TOOL" kobo-synthesise /Volumes/KOBOEREADER | tail -2
"$TOOL" kobo-read /Volumes/KOBOEREADER | tail -6
"$TOOL" kobo-read /Volumes/KOBOEREADER | grep -q "^UNCHANGED" \
    || device_fail "THE DEVICE'S DATABASE WAS WRITTEN TO"

say "what is on the device, matched to the library's books"
CONTENTS=$("$TOOL" device-contents /Volumes/KINDLE "$DEVICE_LIBRARY")
echo "$CONTENTS" | head -3
# Loudly, not vacuously: the first version counted a string in output that was
# not there because the command had failed with "no device profile matches",
# and a check that passes when its subject is missing is not a check.
echo "$CONTENTS" | grep -q "^files: " || device_fail "DEVICE-CONTENTS DID NOT LIST ANYTHING: $CONTENTS"
UNMATCHED=$(echo "$CONTENTS" | grep -c "not in the library" || true)
MATCHED=$(echo "$CONTENTS" | sed -n 's/.*matched to a book: \([0-9]*\).*/\1/p')
echo "  files Shelf could not place: $UNMATCHED"
[ "${MATCHED:-0}" -gt 0 ] || device_fail "NOT ONE FILE ON THE DEVICE WAS MATCHED TO A BOOK"

say "deleting on the device – the confirmation names every file"
DELETE_PATHS=()
while IFS= read -r NAME; do DELETE_PATHS+=("documents/$NAME"); done \
    < <(ls "$SMALL/documents" | head -3)
BEFORE_DELETE=$(ls "$SMALL/documents" | wc -l | tr -d ' ')
"$TOOL" device-delete "$SMALL" "${DELETE_PATHS[@]}"
STILL=$(ls "$SMALL/documents" | wc -l | tr -d ' ')
[ "$STILL" = "$BEFORE_DELETE" ] || device_fail "SOMETHING WAS DELETED WITHOUT A CONFIRMATION"
echo "  nothing went without the confirmation ✓"
SHELF_CONFIRM_DELETE=yes "$TOOL" device-delete "$SMALL" "${DELETE_PATHS[@]}" | tail -2
AFTER_DELETE=$(ls "$SMALL/documents" | wc -l | tr -d ' ')
echo "  on the card: $BEFORE_DELETE before, $AFTER_DELETE after"
[ "$AFTER_DELETE" = "$((BEFORE_DELETE - 3))" ] || device_fail "THE DELETION REMOVED THE WRONG NUMBER OF FILES"

# ── The claim the whole section exists to earn ────────────────────────────────
say "is the library untouched by all of that?"
LIB_FILES_AFTER=$(find "$DEVICE_LIBRARY" -type f | wc -l | tr -d ' ')
echo "  files in the library: $LIB_FILES_BEFORE before, $LIB_FILES_AFTER after"
[ "$LIB_FILES_BEFORE" = "$LIB_FILES_AFTER" ] || device_fail "THE LIBRARY GAINED OR LOST FILES"

# `.shelf/library.sqlite` and its WAL are **expected** to change: reading the
# library to work out a plan opens the index, and SQLite touches its own files
# when it does. The index is a cache of the folders (ADR 0001) and can be thrown
# away at any moment, so that is not what "untouched" means here.
#
# What it means is the part that cannot be rebuilt: the book files and the
# `metadata.opf` beside them. Those are listed separately, and one of them
# changing is what fails this run.
TOUCHED_ALL=$(find "$DEVICE_LIBRARY" -type f -newer "$DEVICE_ROOT/.before-devices" | wc -l | tr -d ' ')
TOUCHED_BOOKS=$(find "$DEVICE_LIBRARY" -type f -newer "$DEVICE_ROOT/.before-devices" \
    -not -path "*/.shelf/*" | wc -l | tr -d ' ')
echo "  files modified since the devices were plugged in: $TOUCHED_ALL"
echo "    of those, inside .shelf/ (the index, a cache): $((TOUCHED_ALL - TOUCHED_BOOKS))"
echo "    books and metadata.opf: $TOUCHED_BOOKS"
if [ "$TOUCHED_BOOKS" != "0" ]; then
    find "$DEVICE_LIBRARY" -type f -newer "$DEVICE_ROOT/.before-devices" -not -path "*/.shelf/*" | head -10
    device_fail "A BOOK OR ITS METADATA WAS WRITTEN TO"
fi

# Sample hashes as well as timestamps: a file rewritten with the same content
# and an old mtime would pass `find -newer` and is exactly what a careless
# "sync" would do.
say "sample hashes of the library's own books"
SAMPLE_BAD=0
while IFS= read -r FILE; do
    OURS=$("$TOOL" digest "$FILE")
    THEIRS=$(shasum -a 256 "$FILE" | awk '{print $1}')
    IN_INDEX=$(sqlite3 "$DEVICE_DB" "SELECT COUNT(*) FROM formats WHERE sha256 = '$THEIRS'")
    if [ "$OURS" = "$THEIRS" ] && [ "${IN_INDEX:-0}" -gt 0 ]; then
        echo "  ${FILE##*/}: unchanged, and the index still knows it"
    else
        echo "  ${FILE##*/}: CHANGED"
        SAMPLE_BAD=1
    fi
done < <(find "$DEVICE_LIBRARY" -type f \( -name "*.epub" -o -name "*.azw3" -o -name "*.pdf" \) | head -5)
[ "$SAMPLE_BAD" = "0" ] || device_fail "A BOOK IN THE LIBRARY CHANGED"
echo "  the library is byte for byte what it was ✓"

say "putting the disk images away"
"$IMAGES" unmount
fi

# ══ 12. Sprint 8 – ordering the library, and the way out of it ════════════════
#
# Three things this section has to earn, and each of them is a claim somebody
# would otherwise have to take on trust:
#
#   * a merge survives having the index thrown away — so it really went into
#     the OPFs and the index really is only a cache (ADR 0001);
#   * an organise can be killed with SIGKILL in the middle and resumed, and
#     afterwards every checksum is what it was, no folder is orphaned, and the
#     way back puts it all where it started;
#   * an archive export imported into an empty library gives back *the same
#     library* — which is the whole of "your library survives this app".
#
# It works on a copy of the main library, not on the library itself: the
# sections above have already measured that one, and an organise renames most
# of its folders.

say "Sprint 8: ordering the library"
S8="$ROOT/sprint8"
S8_LIB="$S8/library"
rm -rf "$S8"
mkdir -p "$S8"
cp -R "$LIBRARY" "$S8_LIB"
"$TOOL" rebuild "$S8_LIB" >/dev/null 2>&1

s8_fail() {
    echo ""
    echo "  ✗ $1" >&2
    exit 1
}

# Every EPUB's digest, as a set. The set is what has to survive all of this —
# not the paths, which are exactly what an organise is allowed to change.
digest_set() {
    find "$1" -name "*.epub" -print0 | sort -z | xargs -0 shasum -a 256 | awk '{print $1}' | sort
}
digest_set "$S8_LIB" >"$S8/digests-before.txt"
BOOKS_BEFORE=$(wc -l <"$S8/digests-before.txt" | tr -d ' ')
echo "  a copy of the library: $BOOKS_BEFORE EPUBs"

# ── 12a. Three spellings of one author, over 40 books ─────────────────────────
#
# The scenario Sprint 8 exists for. The synthetic library has no such author,
# so one is made: 40 books get their author set to one of three spellings of
# the same person, and then the three are folded into one.
say "one author under three spellings, over 40 books"
SPELLINGS=("Sebastian Fitzek" "Fitzek, Sebastian" "S. Fitzek")
N=0
while IFS= read -r TITLE; do
    "$TOOL" set-author "$S8_LIB" "$TITLE" "${SPELLINGS[$((N % 3))]}" >/dev/null 2>&1 \
        || s8_fail "could not set an author — is 'set-author' in shelf-tool?"
    N=$((N + 1))
done < <("$TOOL" first-titles "$S8_LIB" 40)
echo "  40 books given one of three spellings"

for SPELLING in "${SPELLINGS[@]}"; do
    COUNT_ONE=$("$TOOL" names "$S8_LIB" author | awk -F'\t' -v n="$SPELLING" '$2 == n {print $1}' | tr -d ' ')
    echo "    ${SPELLING}: ${COUNT_ONE:-0} books"
done

"$TOOL" merge "$S8_LIB" author "Sebastian Fitzek" "Fitzek, Sebastian" "S. Fitzek" | sed 's/^/  /'
MERGED=$("$TOOL" names "$S8_LIB" author | awk -F'\t' '$2 == "Sebastian Fitzek" {print $1}' | tr -d ' ')
echo "  after the merge: ${MERGED:-0} books under one spelling"
[ "${MERGED:-0}" = "40" ] || s8_fail "the merge did not gather all 40 books"

# The claim that matters: it went into the folders, not only into the index.
say "throwing the index away, and asking the folders who wrote those 40"
"$TOOL" rebuild "$S8_LIB" 2>&1 | tail -4 | sed 's/^/  /'
REBUILT=$("$TOOL" names "$S8_LIB" author | awk -F'\t' '$2 == "Sebastian Fitzek" {print $1}' | tr -d ' ')
STRAYS=$("$TOOL" names "$S8_LIB" author | grep -c "Fitzek" || true)
echo "  after the rebuild: ${REBUILT:-0} books under 'Sebastian Fitzek'"
echo "  spellings of Fitzek still in the library: $STRAYS"
[ "${REBUILT:-0}" = "40" ] || s8_fail "the merge did not survive the rebuild — it was only in the index"
[ "$STRAYS" = "1" ] || s8_fail "more than one spelling of Fitzek came back out of the folders"
echo "  one spelling, 40 books, nothing lost ✓"

# ── 12b. Two obstacles, built on purpose ──────────────────────────────────────
#
# Something already sitting where a book wants to go: once at the exact path,
# once at a path differing only in its capitals. The second is the Mac-only
# trap — on this disk that *is* the same folder, on a case-sensitive one it is
# not — and it is why `VolumeCase` measures the volume instead of assuming.
#
# Note what is **not** built here: two books wanting one folder. A target path
# ends in the library's own running number, and that number is UNIQUE in the
# index, so two indexed books cannot want the same path — the number is exactly
# what makes the name unique (ADR 0002). Those two guards in the planner are
# defensive and are covered by unit tests that hand it the state directly.
say "two obstacles in the way of the organise, built on purpose"
"$TOOL" make-collision "$S8_LIB" exact 2>&1 | sed 's/^/  /'
"$TOOL" make-collision "$S8_LIB" case 2>&1 | sed 's/^/  /'

say "the organise preview — nothing is moved by this"
"$TOOL" organize "$S8_LIB" >"$S8/preview.txt" 2>&1
sed 's/^/  /' "$S8/preview.txt" | head -24
FOLDS=$(grep -c "folds case: yes" "$S8/preview.txt" || true)
# The number the preview *states*, not the number of lines it states it on.
BLOCKED=$(sed -n 's/.*already there, and it is not empty: \([0-9]*\).*/\1/p' "$S8/preview.txt")
echo "  obstacles the preview named: ${BLOCKED:-0}"
[ "${BLOCKED:-0}" != "0" ] || s8_fail "the preview does not name the obstacle it was given"
if [ "$FOLDS" = "1" ]; then
    [ "${BLOCKED:-0}" -ge 2 ] \
        || s8_fail "this volume folds case, so the capitals obstacle should have counted too (got ${BLOCKED:-0})"
    echo "  this volume folds case, so both obstacles count ✓"
else
    echo "  this volume is case-sensitive, so only the exact obstacle counts ✓"
fi

# They were put there to be photographed and counted, not to be lived with.
# Both go now, so the organise below has a clean library to work on — and so
# that what is removed is exactly what this script made.
rm -rf "$S8_LIB/.shelf/library.sqlite" 2>/dev/null
while IFS= read -r LEFTOVER; do
    rm -f "$LEFTOVER"
    rmdir "$(dirname "$LEFTOVER")" 2>/dev/null || true
done < <(find "$S8_LIB" -name "not-a-book.txt")
"$TOOL" rebuild "$S8_LIB" >/dev/null 2>&1

# ── 12c. An organise killed in the middle, then resumed ───────────────────────
say "an organise killed in the middle, then resumed"
SHELF_EXIT_AFTER=25 "$TOOL" organize "$S8_LIB" --run >"$S8/killed.txt" 2>&1
grep -q "leaving the process now" "$S8/killed.txt" \
    || s8_fail "the run was meant to be killed mid-flight and was not"
KILLED_BOOKS=$(find "$S8_LIB" -name "*.epub" | wc -l | tr -d ' ')
KILLED_MANIFEST=$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['entries']))" \
    "$S8_LIB/.shelf/organize-manifest.json" 2>/dev/null || echo 0)
echo "  killed after 25 moves: $KILLED_BOOKS EPUBs on disk, $KILLED_MANIFEST in the manifest"
[ "$KILLED_BOOKS" = "$BOOKS_BEFORE" ] || s8_fail "BOOKS WENT MISSING WHEN THE RUN WAS KILLED"

"$TOOL" organize "$S8_LIB" --run 2>&1 | grep -vE "^  " | sed 's/^/  /'

say "after the organise: the same books, the same bytes, no orphan"
digest_set "$S8_LIB" >"$S8/digests-after.txt"
AFTER=$(wc -l <"$S8/digests-after.txt" | tr -d ' ')
echo "  EPUBs: $BOOKS_BEFORE before, $AFTER after"
[ "$AFTER" = "$BOOKS_BEFORE" ] || s8_fail "THE NUMBER OF BOOK FILES CHANGED"
if diff -q "$S8/digests-before.txt" "$S8/digests-after.txt" >/dev/null; then
    echo "  every checksum identical ✓"
else
    diff "$S8/digests-before.txt" "$S8/digests-after.txt" | head -5
    s8_fail "A BOOK'S CONTENTS CHANGED DURING THE ORGANISE"
fi
"$TOOL" orphans "$S8_LIB" 2>&1 | sed 's/^/  /'
ORPHANS=$("$TOOL" orphans "$S8_LIB" 2>&1 | awk -F': ' '/orphaned folders/ {print $2}' | tr -d ' ')
[ "${ORPHANS:-0}" = "0" ] || s8_fail "THE ORGANISE LEFT ORPHANED FOLDERS"
EMPTY_DIRS=$(find "$S8_LIB" -type d -empty -not -path "*/.shelf/*" | wc -l | tr -d ' ')
echo "  empty folders left behind: $EMPTY_DIRS"
"$TOOL" rebuild "$S8_LIB" 2>&1 | tail -3 | sed 's/^/  /'

# ── 12d. The way back ─────────────────────────────────────────────────────────
say "Undo Organize — every folder back where it came from"
"$TOOL" organize-undo "$S8_LIB" 2>&1 | sed 's/^/  /'
digest_set "$S8_LIB" >"$S8/digests-undone.txt"
if diff -q "$S8/digests-before.txt" "$S8/digests-undone.txt" >/dev/null; then
    echo "  every checksum still identical after the undo ✓"
else
    s8_fail "A BOOK'S CONTENTS CHANGED DURING THE UNDO"
fi
"$TOOL" rebuild "$S8_LIB" 2>&1 | tail -3 | sed 's/^/  /'

# Put it back the way it should be, for the export below.
"$TOOL" organize "$S8_LIB" --run >/dev/null 2>&1

# ── 12e. Export, in all three shapes ──────────────────────────────────────────
# Five books marked read, so the Calibre export has something to map. The
# shelves are already there: section 8 put a thousand books on twenty of them,
# and this section works on a copy of that library.
READ_SET=0
while IFS= read -r TITLE; do
    "$TOOL" edit "$S8_LIB" "$TITLE" 4 yes >/dev/null 2>&1 && READ_SET=$((READ_SET + 1))
done < <("$TOOL" first-titles "$S8_LIB" 5)
echo "  books marked read, to give the Calibre mapping something to map: $READ_SET"

# One at a time, and each of the two that are only being counted is taken away
# again before the next is written. Each is a full second copy of the library,
# and three of them alive at once is 4 GB that this run does not need to hold —
# it is measured on a machine with under 10 GB free.
say "export: Archive, Just the books, For Calibre"
"$TOOL" export "$S8_LIB" "$S8/export-archive" archive 2>&1 \
    | grep -E "preset:|plan:|Written" | sed "s/^/  [archive] /"
echo "  archive:  $(find "$S8/export-archive" -name '*.opf' | wc -l | tr -d ' ') OPFs, $(find "$S8/export-archive" -name '*.epub' | wc -l | tr -d ' ') EPUBs"

rm -rf "$S8/export-books"
"$TOOL" export "$S8_LIB" "$S8/export-books" books 2>&1 \
    | grep -E "preset:|plan:|Written" | sed "s/^/  [books] /"
BOOKS_OPFS=$(find "$S8/export-books" -name '*.opf' | wc -l | tr -d ' ')
echo "  books:    $BOOKS_OPFS OPFs, $(find "$S8/export-books" -name '*.epub' | wc -l | tr -d ' ') EPUBs"
grep -q "the rating, the read status, the tags and the shelves" \
    "$S8/export-books/Shelf-Export-Report.txt" \
    || s8_fail "the 'just the books' report does not say what it left behind"
echo "  and its report says, in as many words, what stayed behind ✓"
rm -rf "$S8/export-books"
[ "$BOOKS_OPFS" = "0" ] || s8_fail "'just the books' wrote OPFs"

rm -rf "$S8/export-calibre"
"$TOOL" export "$S8_LIB" "$S8/export-calibre" calibre 2>&1 \
    | grep -E "preset:|plan:|Written" | sed "s/^/  [calibre] /"
CAL_TAGS=$(grep -rl "dc:subject>Shelf/" "$S8/export-calibre" 2>/dev/null | wc -l | tr -d ' ')
CAL_READ=$(grep -rl "dc:subject>Read<" "$S8/export-calibre" 2>/dev/null | wc -l | tr -d ' ')
echo "  calibre:  $CAL_TAGS OPFs carry a shelf as a Calibre tag, $CAL_READ carry “Read”"
[ "$CAL_TAGS" != "0" ] || s8_fail "the Calibre export mapped no shelf to a tag"
rm -rf "$S8/export-calibre"

# ── 12f. The most important proof of the sprint ───────────────────────────────
#
# The archive, imported into a *new, empty* library, and the two compared book
# by book. If this passes, a library can leave Shelf and come back whole; if it
# does not, every other promise in this sprint is decoration.
say "the archive imported into an empty library, and the two compared"
rm -rf "$S8/reimported"
"$TOOL" import "$S8/export-archive" "$S8/reimported" 2>&1 \
    | grep -E "reading|shelves registered|plan:|index holds" | sed 's/^/  /'
"$TOOL" compare "$S8_LIB" "$S8/reimported" 2>&1 | sed 's/^/  /' \
    || s8_fail "THE RE-IMPORTED LIBRARY IS NOT THE SAME LIBRARY"
rm -rf "$S8/reimported"

# ── 12g. The second run, and the hard links ───────────────────────────────────
say "a second export into the same folder writes only the differences"
"$TOOL" export "$S8_LIB" "$S8/export-archive" archive 2>&1 | grep -E "plan:|Written" | sed 's/^/  /'
UNCHANGED=$("$TOOL" export "$S8_LIB" "$S8/export-archive" archive 2>&1 | grep -oE "[0-9]+ unchanged" | head -1)
echo "  and again: $UNCHANGED"

say "hard links: the same bytes, twice named, once stored"
rm -rf "$S8/export-linked"
"$TOOL" export "$S8_LIB" "$S8/export-linked" archive --links 2>&1 | grep -E "Written|hard links" | sed 's/^/  /'
LIB_EPUBS=$(find "$S8_LIB" -name '*.epub' | wc -l | tr -d ' ')
OUT_EPUBS=$(find "$S8/export-linked" -name '*.epub' | wc -l | tr -d ' ')
BOTH_INODES=$(find "$S8_LIB" "$S8/export-linked" -name '*.epub' -exec stat -f '%i' {} \; | sort -u | wc -l | tr -d ' ')
echo "  EPUBs in the library: $LIB_EPUBS · in the export: $OUT_EPUBS"
echo "  distinct inodes across both: $BOTH_INODES"
[ "$BOTH_INODES" = "$LIB_EPUBS" ] \
    || s8_fail "THE LINKED EXPORT MADE SECOND COPIES ($BOTH_INODES inodes for $LIB_EPUBS books)"
echo "  no second copy of a single book ✓"

# What is left of section 12 is the library copy and one archive. Both are
# named in the report, and `make synthetic-clean` takes the lot.
rm -rf "$S8/export-linked"

say "done"
echo "source:  $SOURCE"
echo "library: $LIBRARY"
echo ""
echo "To measure the window: make app, then open $LIBRARY in Shelf."
echo "To clean up: make synthetic-clean"
