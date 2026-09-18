#!/bin/bash
# Builds the twelve-book library the Sprint 6 screenshots are taken against.
#
# The books are generated EPUBs — `shelf-tool synthesise`, the same fixtures
# every other proof run uses. What this adds is **real bibliographic details**:
# each book's `metadata.opf` gets the title, author and ISBN of a real book, so
# that ⌘E has something Open Library and Google Books have actually heard of.
# No borrowed book file is in this repository or in the cache (CLAUDE.md); what
# is borrowed is a title and a number off a spine.
#
# Three of them lose their cover file, because "fetch a cover when the file has
# none" cannot be photographed on a book that has one.
#
# It writes only into its own folder under ~/Library/Caches/Shelf and removes
# only what it made there.
#
# Usage: Scripts/online-library.sh [folder]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CACHE="${1:-$HOME/Library/Caches/Shelf/measure-library-6}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/debug/shelf-tool"

[ -x "$TOOL" ] || swift build --package-path "$ROOT" --scratch-path "$SCRATCH"

SOURCE="$CACHE/online-source"
LIBRARY="$CACHE/online-library"
# Only these two, by name, and only because this script made them.
rm -rf "$SOURCE" "$LIBRARY"
mkdir -p "$LIBRARY"

"$TOOL" synthesise "$SOURCE" 12 | tail -2
"$TOOL" import "$SOURCE" "$LIBRARY" | tail -2

python3 - "$LIBRARY" <<'PY'
import glob, os, re, sys

root = sys.argv[1]

# Ten of the proof run's own ISBNs plus two books with none at all, so both
# questions — by ISBN, and by title and author — are in the picture.
books = [
    ("Fantastic Mr Fox",                          "Roald Dahl",          "9780140328721"),
    ("The Fellowship of the Ring",                "J. R. R. Tolkien",    "9780261103573"),
    ("Dune",                                      "Frank Herbert",       "9780441013593"),
    ("Sapiens",                                   "Yuval Noah Harari",   "9780062316097"),
    ("Learning Python",                           "Mark Lutz",           "9781449355739"),
    ("Clean Code",                                "Robert C. Martin",    "9780132350884"),
    ("The Left Hand of Darkness",                 "Ursula K. Le Guin",   None),
    ("The Dispossessed",                          "Ursula K. Le Guin",   None),
    ("Ein deutscher Heyne-Titel",                 "Unbekannt",           "9783453319950"),
    ("Nineteen Eighty-Four",                      "George Orwell",       "9780451524935"),
    ("Die Herren von Winterfell",                 "George R. R. Martin", "9783442267743"),
    ("Harry Potter and the Philosopher's Stone",  "J. K. Rowling",       "9780747532699"),
]

opfs = sorted(glob.glob(os.path.join(root, "*", "*", "metadata.opf")))
assert len(opfs) >= len(books), f"only {len(opfs)} books were imported"

for opf, (title, author, isbn) in zip(opfs, books):
    text = open(opf, encoding="utf-8").read()
    text = re.sub(r"<dc:title>[^<]*</dc:title>", f"<dc:title>{title}</dc:title>", text)
    text = re.sub(
        r"<dc:creator [^>]*>[^<]*</dc:creator>",
        f'<dc:creator opf:role="aut" opf:file-as="{author}">{author}</dc:creator>',
        text)
    text = re.sub(
        r'<meta name="calibre:title_sort" content="[^"]*"/>',
        f'<meta name="calibre:title_sort" content="{title}"/>', text)
    element = f'<dc:identifier opf:scheme="ISBN">{isbn}</dc:identifier>'
    has_isbn = '<dc:identifier opf:scheme="ISBN">' in text
    if isbn and has_isbn:
        text = re.sub(r'<dc:identifier opf:scheme="ISBN">[^<]*</dc:identifier>', element, text)
    elif isbn:
        # `shelf-tool synthesise` writes an ISBN for only some of its books, so
        # the element usually has to be added rather than replaced. After the
        # uuid, which is where an OPF Calibre wrote would have it.
        text = re.sub(
            r'(<dc:identifier id="uuid_id"[^>]*>[^<]*</dc:identifier>)',
            r"\1\n    " + element, text)
    elif has_isbn:
        text = re.sub(r'\s*<dc:identifier opf:scheme="ISBN">[^<]*</dc:identifier>', "", text)
    open(opf, "w", encoding="utf-8").write(text)
    print(f"  {title} — {author} — {isbn or 'no ISBN'}")

for opf in opfs[:3]:
    folder = os.path.dirname(opf)
    for name in os.listdir(folder):
        if name.startswith("cover."):
            os.remove(os.path.join(folder, name))
            print(f"  no cover: {os.path.basename(folder)}")
PY

# The folder is the truth; the index follows it (ADR 0001).
"$TOOL" rebuild "$LIBRARY" | tail -3
echo "online-library: $LIBRARY"
