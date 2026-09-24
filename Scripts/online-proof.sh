#!/bin/bash
# Sprint 6's real run: ten ISBNs asked of both services, with the manners the
# app uses — Shelf's own User-Agent, at most one request per second per service,
# a time limit, and no retry for anything but a 5xx.
#
# It does two jobs at once, and that is deliberate:
#
#   1. it *measures* — time per request, how many of the ten each service knows,
#      and where the two disagree;
#   2. it *writes the fixtures the tests run against*, trimmed of the fields
#      Shelf never reads, so the unit tests are checked against real answers and
#      never touch the network (CONCEPT §14, "no network in CI").
#
# Nothing else in the build talks to the network. `make test` reads the files
# this leaves behind.
#
# Usage: Scripts/online-proof.sh [output folder for fixtures]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${1:-$ROOT/Tests/ShelfCoreTests/Fixtures/online}"
UA="Shelf/0.1.0 (eBook manager; +https://github.com/Erikemmer/Shelf)"
TIMEOUT=15
# Exactly the fields ShelfCore's reader reads (`MetadataEndpoint`).
FIELDS="key,title,subtitle,author_name,first_publish_year,publisher,language,isbn,cover_i,subject,number_of_pages_median"

# Ten real ISBN-13s, check digits verified, chosen to be a library rather than a
# shelf: children's, fantasy, science fiction, a classic, non-fiction, two
# German titles and two technical books. What they have in common is that they
# exist; what matters is where the two services differ about them.
ISBNS=(
    9780140328721  # Fantastic Mr Fox — Roald Dahl
    9780261103573  # The Fellowship of the Ring — Tolkien
    9780441013593  # Dune — Frank Herbert
    9780747532699  # Harry Potter and the Philosopher's Stone
    9780451524935  # Nineteen Eighty-Four — Orwell
    9780062316097  # Sapiens — Harari
    9783453319950  # a German Heyne paperback
    9783442267743  # a German Goldmann paperback
    9781449355739  # Learning Python — O'Reilly
    9780132350884  # Clean Code — Robert C. Martin
)
# Literal, ten ISBNs, never computed or filtered – "${ISBNS[@]}" below is
# never empty under set -u (Sprint 16, Teil F).

say() { echo "online-proof: $1"; }
mkdir -p "$OUT"

# `jq` trims the answers to what Shelf reads. Without it the fixtures are the
# raw answers, which is still honest — just larger — so its absence is a note
# and not a failure.
if command -v jq >/dev/null 2>&1; then TRIM=1; else TRIM=0; say "jq not found – fixtures are stored untrimmed"; fi

# One request, with the app's own retry rule: a 5xx or a request that never got
# an answer at all is tried again, at most three attempts, waiting 1 s then 2 s
# (`NetworkPolicy`). A 404 and a 429 are answers and are not repeated.
#
# The first run of this script had no retry and reported three of the ten as
# timeouts — all three answered in under three seconds when asked again. A
# measurement that does not behave like the app measures something the app does
# not do.
fetch() { # url outfile  → prints "status time bytes attempts"
    local attempt=1 total=0 status time bytes
    while :; do
        read -r status time bytes <<<"$(curl -s -A "$UA" --max-time "$TIMEOUT" -o "$2" \
            -w "%{http_code} %{time_total} %{size_download}" "$1")"
        total=$(echo "$total + $time" | bc)
        case "$status" in
            5??|000) ;;
            *) break ;;
        esac
        [ "$attempt" -ge 3 ] && break
        sleep $((1 << (attempt - 1)))
        attempt=$((attempt + 1))
    done
    echo "$status $total $bytes $attempt"
}

declare -a ROWS=()
OL_HITS=0; GB_HITS=0; OL_TIME=0; GB_TIME=0; OL_FAIL=""; GB_FAIL=""

for ISBN in "${ISBNS[@]}"; do
    # ── Open Library ──────────────────────────────────────────────────────────
    RAW="$OUT/.raw.json"
    URL="https://openlibrary.org/search.json?q=isbn:$ISBN&limit=1&fields=$FIELDS"
    read -r STATUS TIME BYTES TRIES <<<"$(fetch "$URL" "$RAW")"
    OL_TIME=$(echo "$OL_TIME + $TIME" | bc)
    OL_TITLE="—"; OL_AUTHOR="—"; OL_SUBJECTS=0
    if [ "$STATUS" = "200" ]; then
        FOUND=$(jq -r '.docs | length' "$RAW" 2>/dev/null || echo 0)
        if [ "${FOUND:-0}" -gt 0 ]; then
            OL_HITS=$((OL_HITS + 1))
            OL_TITLE=$(jq -r '.docs[0].title // "—"' "$RAW")
            OL_AUTHOR=$(jq -r '.docs[0].author_name[0] // "—"' "$RAW")
            OL_SUBJECTS=$(jq -r '(.docs[0].subject // []) | length' "$RAW")
        fi
        if [ "$TRIM" = "1" ]; then
            # Only the first doc; only the twelve subjects the reader keeps;
            # and only the ISBN that was asked for plus five others. A work on
            # Open Library carries every edition's ISBN — Dune has about two
            # hundred — which is 90 % of the answer's bytes and proves nothing
            # the sixth one does not.
            jq --arg want "$ISBN" '{docs: [ .docs[0] | select(. != null)
                    | .subject = ((.subject // [])[0:12])
                    | .isbn = ( ((.isbn // []) | map(select(. == $want)))
                                + ((.isbn // []) | map(select(. != $want)) | .[0:5]) ) ]}' \
                "$RAW" > "$OUT/openlibrary-isbn-$ISBN.json" 2>/dev/null || cp "$RAW" "$OUT/openlibrary-isbn-$ISBN.json"
        else
            cp "$RAW" "$OUT/openlibrary-isbn-$ISBN.json"
        fi
    else
        OL_FAIL="$OL_FAIL $ISBN:$STATUS"
        cp "$RAW" "$OUT/openlibrary-isbn-$ISBN.json" 2>/dev/null
    fi
    printf "  open library  %s  %ss  %sB  %s try  %s\n" "$STATUS" "$TIME" "$BYTES" "$TRIES" "$OL_TITLE"
    sleep 1

    # ── Google Books ──────────────────────────────────────────────────────────
    URL="https://www.googleapis.com/books/v1/volumes?q=isbn:$ISBN"
    read -r STATUS TIME BYTES TRIES <<<"$(fetch "$URL" "$RAW")"
    GB_TIME=$(echo "$GB_TIME + $TIME" | bc)
    GB_TITLE="—"; GB_DESC=0
    if [ "$STATUS" = "200" ]; then
        FOUND=$(jq -r '.totalItems // 0' "$RAW" 2>/dev/null || echo 0)
        if [ "${FOUND:-0}" -gt 0 ]; then
            GB_HITS=$((GB_HITS + 1))
            GB_TITLE=$(jq -r '.items[0].volumeInfo.title // "—"' "$RAW")
            GB_DESC=$(jq -r '(.items[0].volumeInfo.description // "") | length' "$RAW")
        fi
        if [ "$TRIM" = "1" ]; then
            # `saleInfo`, `accessInfo`, `searchInfo`, `readingModes` and the
            # panelization summary are never read by anything in Shelf.
            jq '{totalItems, items: [ .items[0] | select(. != null) | {id, volumeInfo: (.volumeInfo | {title, subtitle, authors, publisher, publishedDate, description, industryIdentifiers, pageCount, categories, language, imageLinks, seriesInfo})} ]}' \
                "$RAW" > "$OUT/googlebooks-isbn-$ISBN.json" 2>/dev/null || cp "$RAW" "$OUT/googlebooks-isbn-$ISBN.json"
        else
            cp "$RAW" "$OUT/googlebooks-isbn-$ISBN.json"
        fi
    else
        GB_FAIL="$GB_FAIL $ISBN:$STATUS"
        cp "$RAW" "$OUT/googlebooks-isbn-$ISBN.json" 2>/dev/null
    fi
    printf "  google books  %s  %ss  %sB  %s try  %s\n" "$STATUS" "$TIME" "$BYTES" "$TRIES" "$GB_TITLE"
    ROWS+=("$ISBN|$OL_TITLE|$OL_AUTHOR|$OL_SUBJECTS|$GB_TITLE|$GB_DESC")
    sleep 1
done
rm -f "$OUT/.raw.json"

echo
say "what each service knows of the ten"
printf "  Open Library: %s of 10 · %ss in total\n" "$OL_HITS" "$OL_TIME"
printf "  Google Books: %s of 10 · %ss in total\n" "$GB_HITS" "$GB_TIME"
[ -n "$OL_FAIL" ] && printf "  Open Library did not answer 200 for:%s\n" "$OL_FAIL"
[ -n "$GB_FAIL" ] && printf "  Google Books did not answer 200 for:%s\n" "$GB_FAIL"

echo
say "where the two disagree"
printf "  %-14s %-34s %-4s %-34s %s\n" ISBN "OPEN LIBRARY" "SUBJ" "GOOGLE BOOKS" "DESC"
# ROWS is built above by one unconditional "ROWS+=(...)" per loop iteration,
# and that loop runs exactly ${#ISBNS[@]} times (ISBNS is literal) with no
# "continue" in its body. "${ROWS[@]}" below is never empty under set -u
# (Sprint 16, Teil F).
for ROW in "${ROWS[@]}"; do
    IFS='|' read -r I OT OA OS GT GD <<<"$ROW"
    printf "  %-14s %-34.34s %-4s %-34.34s %s\n" "$I" "$OT" "$OS" "$GT" "$GD"
done

echo
say "fixtures in $OUT"
ls -1 "$OUT" | wc -l | xargs printf "  %s files\n"
du -sh "$OUT" | awk '{print "  " $1}'
