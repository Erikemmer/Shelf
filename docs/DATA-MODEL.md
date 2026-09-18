# Data model

Three places hold data, and they are deliberately not equal: the **folders** are
the truth, the **OPF files** are the portable form of that truth, and the
**index** is a cache of both ([ADR 0001](adr/0001-folder-is-the-truth.md)).

## 1. The library folder

```
My Library/
  .shelf/
    library.sqlite          the index (deletable, rebuildable)
    library.sqlite-wal      SQLite's write-ahead log
    library.json            name, schema version, shelves, next book number
    covers/                 cover cache: <uuid>-<pixels>-<hash>.img
    Import-Report.txt       appended, one block per import
  Austen, Jane/                       ← AuthorSort.of(first author), sanitised
    Pride and Prejudice (17)/         ← title, sanitised, + the book number
      Pride and Prejudice - Jane Austen.epub
      Pride and Prejudice - Jane Austen.azw3
      cover.png                       ← named after what the bytes actually are
      metadata.opf
```

Calibre-compatible on purpose, so an import can take a tree over unchanged and a
return to Calibre stays possible.

### Names

`BookFolderName` owns every rule, and it is tested, because a wrong name is a
book that cannot be found again:

* **Forbidden characters** become one space: the union of three file systems'
  rules, because one name has to survive all of them — `/` and NUL (POSIX), `:`
  (HFS and the Finder), and `\ * ? " < > |` (FAT32/exFAT, which is what every
  e-reader is formatted with).
* **Trailing dots and spaces go.** FAT drops them silently, so "Vol. 2 ." and
  "Vol. 2" would be the same folder and one book would land on top of the other.
* **A leading dot goes**, so a book is not a hidden folder.
* **Names Windows reserves** (`CON`, `NUL`, `COM1`…) get an underscore.
* **255 *bytes* per component**, cut without splitting a character: the limit is
  bytes on ext4 and HFS+, and 255 emoji are 1 020 bytes.
* The **book number** (`(17)`) is what makes two books of one title distinct. It
  comes from `library.json`'s counter, never from the highest folder found.

## 2. `library.json`

```json
{
  "schemaVersion" : 1,
  "name" : "My Library",
  "createdAt" : "2026-09-16T20:56:30Z",
  "nextBookNumber" : 21,
  "shelves" : [
    { "id" : "…", "name" : "Fiction", "position" : 0 },
    { "id" : "…", "name" : "Science Fiction", "parentID" : "…", "position" : 0 }
  ],
  "customColumns" : [
    { "number" : 1, "label" : "read_date", "name" : "Date read",
      "kind" : "datetime", "isMultiple" : false, "isNormalized" : false }
  ],
  "view" : {
    "mode" : "table",
    "order" : { "field" : "author", "ascending" : false },
    "tableColumns" : "…"
  }
}
```

Pretty-printed, sorted keys, ISO-8601 dates — a file a person may well open in a
text editor, and one whose diffs should mean something. Written atomically.

`schemaVersion` is refused if it is higher than this Shelf understands: writing
such a library back could drop fields it does not know about.

### Shelves

This file holds the **shape**: what shelves exist, what is inside what, in what
order. *Which* shelves a book is on is in the book
([ADR 0008](adr/0008-shelves-membership-in-the-book-hierarchy-in-library-json.md)).

Hierarchical (CONCEPT §15, decision 3) through a `parentID`, so moving a shelf
is one field change and not a rewrite of its children. `ShelfTree.canMove`
refuses a move that would make a loop, and both tree walks carry a visited set
so a loop that already exists (from a corrupt file) cannot hang the app.

An **empty shelf lives only here**. No book can remember a shelf with nothing on
it, which is the clearest single reason the shape is kept in a file rather than
derived from what the books say.

`ShelfEdit` in the core owns the rules — what a name may be, what may go inside
what, and what happens to the books when a shelf is renamed, moved or removed.
The same rules run for a drag, a menu, a rebuild and somebody else's
`library.json`.

### `view`: how the library was last looked at

Grid or table, the sort field and its direction, and the table's column layout.
**Per library, not per app**: it describes this collection, so a library of
comics can want different columns from a library of novels, and it travels with
the folder the way the shelves do.

`tableColumns` is SwiftUI's own `TableColumnCustomization`, carried as an opaque
string. Deliberately not interpreted here — it is the framework's structure, and
a second reading of it would be a second thing to keep in step with something
that owns it. A value that cannot be decoded gives the default layout rather
than an error.

The whole `view` block may be **missing**: every `library.json` written before
Sprint 2c lacks it. The descriptor is decoded by hand so that absent means "the
default", because a new field that makes existing libraries unopenable would be
a migration, and this is not worth one.

## 3. `metadata.opf`

The Calibre OPF schema: Dublin Core plus `calibre:` metas, plus Shelf's own
fields as `shelf:` metas, which Calibre ignores silently.

```xml
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>The Dispossessed</dc:title>
    <dc:creator opf:role="aut" opf:file-as="Guin, Ursula K. Le">Ursula K. Le Guin</dc:creator>
    <dc:language>en</dc:language>
    <dc:publisher>Gollancz</dc:publisher>
    <dc:date>2001-09-09T00:00:00+00:00</dc:date>
    <dc:description>Two worlds, one wall.</dc:description>
    <dc:identifier id="uuid_id" opf:scheme="uuid">E5C7B22F-…</dc:identifier>
    <dc:identifier opf:scheme="ISBN">9780061054884</dc:identifier>
    <dc:subject>science fiction</dc:subject>
    <meta name="calibre:title_sort" content="Dispossessed, The"/>
    <meta name="calibre:series" content="Hainish Cycle"/>
    <meta name="calibre:series_index" content="6"/>
    <meta name="calibre:rating" content="5"/>
    <meta name="calibre:timestamp" content="2026-09-16T20:56:31+00:00"/>
    <meta name="shelf:read" content="true"/>
    <meta name="shelf:shelves" content="[&quot;Fiction/Science Fiction&quot;,&quot;To Read&quot;]"/>
  </metadata>
  <guide/>
</package>
```

### Which field goes where

Every editable field and the element it becomes. `BookField` in the core owns
the reading and writing of each one, so this table and the code are the same
list ([`Sources/ShelfCore/Library/BookFieldEdit.swift`](../Sources/ShelfCore/Library/BookFieldEdit.swift)).

| field in the inspector | in `metadata.opf` | notes |
|---|---|---|
| Title | `<dc:title>` | may not be empty: it names the folder |
| — (derived) | `<meta name="calibre:title_sort">` | follows the title, unless somebody set it by hand |
| Authors | one `<dc:creator opf:role="aut">` each | separated by ` & ` in the field, order kept |
| — (derived) | `opf:file-as` on each `dc:creator` | `AuthorSort.of(name)`, follows the author |
| Series | `<meta name="calibre:series">` | empty removes the series *and* its index |
| Series index | `<meta name="calibre:series_index">` | a decimal; `2,5` and `2.5` both mean 2.5 |
| Publisher | `<dc:publisher>` | |
| Published | `<dc:date>` | typed as a year, a month or a day |
| Language | `<dc:language>` | not validated: "eng" is what the file said |
| Description | `<dc:description>` | several lines; ⏎ is a line break, not a commit |
| Tags | one `<dc:subject>` each, sorted | a case-insensitive set |
| Identifiers | `<dc:identifier opf:scheme="ISBN">` … | an ISBN is checked against its check digit |
| Shelves | `<meta name="shelf:shelves">` | a JSON array of stored paths, sorted |
| Rating | `<meta name="calibre:rating">` | Calibre's 0…10, five stars × 2 |
| Read | `<meta name="shelf:read">` | Shelf's own |
| Calibre's own columns | `<meta name="shelf:custom">` | a JSON object, label → text; read-only (ADR 0010) |

Rules that come with the table:

* **An empty field removes the element** rather than writing an empty one. A
  book with no publisher has no `<dc:publisher>`, not an empty one.
* **`shelf:shelves` is one meta holding a JSON array**, not one meta per shelf:
  `<meta name>` is looked up by name, and repeated names would collapse into
  one. JSON because a shelf name may contain a comma or a pipe, and because the
  obvious ASCII separators (the unit separator) are *not legal in XML 1.0* — a
  parser refuses the whole file. Slashes are **not** escaped (`Fiction/Sci-Fi`,
  not `Fiction\/Sci-Fi`): the argument for JSON here was that it is lossless
  *and readable*, and a decoder accepts either spelling.
* **`calibre:title_sort` follows the title, but only when nobody had set it.**
  "Nobody set it" is recognisable: the stored value is exactly what
  `TitleSort.of` produces for the old title. A hand-written "Dispossessed, The"
  survives the next typo fix, because overwriting it would be the app changing
  data nobody asked it to change.
* **The author sort form is never stored**, only derived — which is why it
  follows a changed author into `opf:file-as` and into the index's `name_sort`
  without anybody maintaining it.
* **Authors are separated by `&`, never by a comma.** `AuthorSort` reads a comma
  as "this name is already in sort form", so "Austen, Jane" is *one* author;
  splitting on commas would make it two.
* **Tags are sorted and case-folded.** The OPF writes them sorted, the index
  reads them back `ORDER BY name`, and `Book` sorts them on construction — three
  places, one order, so the same book read from its folder and read from the
  index cannot differ in a field nobody touched. Adding a tag that differs only
  in case keeps the spelling the library already uses, so a sidebar never lists
  "Science Fiction" and "science fiction" as two keywords.
* **A metadata change never renames the book's folder**
  ([ADR 0007](adr/0007-a-metadata-change-does-not-rename-the-folder.md)). The
  UUID holds the identity; a folder named after an old title is a name, not a
  defect. "Reorganize Library…" is a separate command with a preview.

Rules worth knowing:

* **Written atomically**, through a `metadata.opf.part` that is renamed into
  place. A crash leaves either the old file or the new one, never half of either.
* **The UUID is the book's identity.** It is taken from Calibre on import and
  minted otherwise, and it is what makes a rebuild *reconstruct* a library
  rather than reinvent it: shelves and reading status still point at the same
  books afterwards.
* **Shelves are a JSON array**, not a joined string. An ASCII separator such as
  the unit separator is *not legal in XML 1.0* — the parser refuses the whole
  file — and a shelf name may contain a comma, a slash or a pipe. (The first
  version of this used `U+001F` and a test caught it.)
* **Rendering is stable**: the same book gives byte-identical output, so a diff
  in a library folder means a real change.
* **Text between tags and text inside an attribute are escaped differently.**
  Both get the five XML entities. An attribute also gets `&#9;`, `&#10;` and
  `&#13;` for tab, newline and carriage return, because XML *attribute-value
  normalisation* turns those into a space before the parser ever reports them —
  a sort title with a line break came back changed, and `calibre:title_sort`,
  `calibre:series`, `opf:file-as` and Calibre's custom columns are all
  attributes. Element text escapes the carriage return for the same kind of
  reason (*line-ending normalisation* turns a literal CR into LF) and leaves
  newlines and tabs as themselves, so a long description is still readable by
  eye in the file.
* **A value that looks like XML arrives as text.** A book titled
  `<meta name="calibre:rating" content="10"/>` keeps that title and keeps its
  rating of 0; it cannot set its own fields by being called the right thing.
* **A value is trimmed at both ends.** The XML reader trims an element's text,
  so a value stored with a leading space would not come back with one. The
  editor trims what is typed, which makes "what was stored" and "what comes
  back" the same string.

* **Unknown metas are kept**, not dropped. Calibre's `user_metadata:*` custom
  columns land in `unmappedMetas` and are written back, so Sprint 3 is a feature
  and not a migration.
* **`dc:date` is read loosely and written one way**: "2019", "2019-04",
  "2019-04-01" and full ISO-8601 stamps all turn up, and Calibre's
  `0101-01-01T00:00:00+00:00` placeholder is read as *no date* rather than as
  the year 101.
* **`opf:role` other than `aut` is not an author.** A translator is filed
  separately, as Calibre does.
* **`calibre:rating` is Calibre's ten-point scale**, not Shelf's five stars.
  `Book.rating` holds 0…10 and `Book.stars` is the conversion: stars × 2 on the
  way in, `(rating + 1) / 2` on the way out, so a book Calibre rated 7 shows
  four stars rather than three and a half, and four stars are written back as 8.
  The finer value is kept because a library that goes back to Calibre must not
  lose half stars somebody set there. The conversion lives in one place, on
  `Book`, so no view can invent a third answer.
* **`shelf:` metas are Shelf's own**, and Calibre ignores metas it does not
  know. Two so far: `shelf:read` (`true` / `false`) and `shelf:shelves` (the
  JSON array above).
* **`dcterms:modified` is written as well as read** since Sprint 2a. It was read
  from the first version and never written, so a rebuilt index dated every book
  to the moment of the rebuild. It is an EPUB 3 `<meta property=…>` rather than a
  `calibre:` meta, because that is where the reader already looked for it.
* **The modification date is stamped to whole seconds**, which is the precision
  the file has. A `Date` with a fractional part would come back from the file
  slightly different, and "undo restores exactly the previous state" would be
  false by a few microseconds — true enough to pass a careless test and false
  enough to make the folder and the index disagree.
* **An edit is a delta, laid over the file.** `MetadataEditor` reads the OPF
  that is there and copies across only the fields that actually changed, so
  Calibre's custom columns, the shelves and the identifiers survive an edit made
  from a window that never loaded them.

### Calibre's custom columns

`<meta name="shelf:custom" content="{&quot;pages&quot;:&quot;341&quot;}"/>` — one
meta holding a JSON object, keys sorted, for the two reasons `shelf:shelves` is
one meta holding an array: `<meta name=…>` is looked up by name, so a column
called `read` would collide with Shelf's own field, and a label is free-form
text a joined string cannot carry back.

*Which* columns a library has — their names and their kinds — is in
`library.json`, not here; a book carries only its values
([ADR 0010](adr/0010-calibre-custom-columns-are-read-only.md)).

**Calibre's own `calibre:user_metadata:#…` metas are untouched.** They carry
Calibre's JSON definition of the column, not a value, and Shelf writes its own
meta rather than pretending to speak that dialect. They survive an edit like
every meta Shelf does not model — which they had *not* until Sprint 3, because
the reader treated the whole `calibre:` prefix as understood and dropped them.
The metas Shelf models are named one by one now:

    calibre:title_sort · calibre:series · calibre:series_index
    calibre:rating · calibre:timestamp
    shelf:read · shelf:shelves · shelf:custom

## 4. The index (`.shelf/library.sqlite`)

GRDB.swift over SQLite, WAL mode, foreign keys on, schema through versioned
migrations (`IndexSchema`). Tables as CONCEPT §5.2 names them:

| table | holds | rebuildable from |
|---|---|---|
| `books` | id (UUID as text), number, folder, title, title_sort, series_id, series_index, rating, is_read, publisher, published, language, description, added_at, modified_at, last_seen_at | the OPFs |
| `authors`, `book_authors` | one row per name; `position` keeps the printed order | the OPFs |
| `series` | one row per name | the OPFs |
| `tags`, `book_tags` | one row per keyword | the OPFs |
| `shelves`, `book_shelves` | the hierarchy and its contents | `library.json` (shape) + `shelf:shelves` (membership) |
| `formats` | one row per file: format, file_name, byte_size, **sha256**, modified_at, drm | the files |
| `identifiers` | scheme → value, plus a normalised `isbn_normalised` row | the OPFs |
| `custom_columns`, `custom_values` | Calibre's custom columns (Sprint 3, read-only) | the OPFs' unknown metas |
| `devices`, `device_books` | what is on which reader (Sprint 5) | the devices |
| `search` | FTS5 over title, authors, series, tags, description, **ISBN** | everything above |

Notes:

* **The UUID is stored as text**, not as a blob, so the file can be read with any
  SQLite tool. A library nobody but Shelf can open would be the lock-in the
  Leitlinie forbids.
* **`formats.sha256` is indexed**, because it is how a duplicate is found and how
  a book already on a device will be recognised.
* **`identifiers` carries a second, normalised ISBN row** (`isbn_normalised`):
  the importer compares those, so `0-306-40615-x` and `030640615X` are one book.
* **`search` is a plain FTS5 table**, not one with external content: the text
  searched spans six tables, so there is no single row to point at. Migration 2
  added the `isbn` column — FTS5 has no `ALTER TABLE … ADD COLUMN`, so the table
  is dropped, built again and *refilled* from the tables it summarises. The
  refill is not optional: without it an existing library loses its whole search
  index, not merely the ISBN, because nothing rewrites a book's row until
  somebody edits that book. Both spellings of an ISBN are indexed, hyphens and
  no hyphens, because neither prefix-matches the other.
  `LibraryIndex` writes that row whenever it writes a book — one place, rather
  than five triggers that have to stay in step. A book's search row is deleted
  and reinserted on every save, because FTS5 has no useful `UPDATE` and a stale
  search row shows up as "I renamed it and search still finds the old name".
* **The device tables exist from migration 1** although Sprint 5 fills them, so
  a library already in use does not need migrating then.
* **`last_seen_at`** records when the folder was last found as expected. A
  mismatch between index and disk is shown, never resolved silently
  (CONCEPT §5.2).
* **`book_shelves` is written from the book, and invents nothing.** Saving a
  book resolves each of its stored paths against the `shelves` table — one level
  at a time, case-insensitively — and *skips* a path with no shelf behind it.
  A shelf conjured up in the cache would be one `library.json` never hears
  about. It follows that a rebuild must save the tree **before** the books, or
  every membership is silently dropped.
* **Reading them back is one recursive CTE**, walking each shelf to the root and
  joining the names, so 5 000 books on 20 shelves cost one statement rather than
  one per level. It has to work: `Book.shelves` is what the grid filters on and
  what *Not on any Shelf* is answered from.
* **Duplicates are three queries, not a column.** Same bytes (`GROUP BY sha256`),
  same ISBN (`GROUP BY value` over `isbn_normalised`), and same title-and-author
  — the last folded in Swift, because the folding drops accents, punctuation and
  runs of space and `DuplicateKey` is where that rule lives. Which rule matched
  is kept, because identical bytes is a fact and identical title-and-author is a
  guess that fits two editions and a translation.

### Sort orders

`BookSort` owns the SQL, so the sort menu, the table header and a stored
preference cannot disagree about what "by author" means. Six fields — title,
author, series, rating, date added, last changed — and the direction is a
separate thing (`BookOrder`), so every one of them works both ways round.

Rules that are easy to get wrong and are therefore written down:

* `COLLATE NOCASE` wherever a person's eye reads the column — a library that
  puts "Zola" before "adams" is unscannable.
* By series, books *without* one sort last **in both directions**: a `NULL`
  sorts before everything in SQLite, so a plain `DESC` would move them to the
  front.
* **Every order ends in the title**, so two books that tie keep a fixed order
  instead of reshuffling on every reload.
* A field decides which way round *one* click gives (`prefersDescending`): names
  A–Z, dates and ratings newest and best first. Both are always offered.
* The table's header sorts **through the model**, which re-queries. Four columns
  — Tags, Format, Read, Size — have no `BookSort` and therefore no arrow: a
  column that sorted only the rows in memory would put the table in one order
  and leave the grid and the menu in another.

## 5. The cover cache

`.shelf/covers/<uuid>-<pixels>-<8 hex>.img`

* The key is the **book's UUID, the pixel size asked for, and a generation
  number** (`CoverCacheKey`). Unlike Selector, which keys on a file's path, size
  and date, a cover belongs to the book and outlives any one of its files; the
  generation is what replaces size-and-date, so a replaced cover misses instead
  of matching something stale.
* The fingerprint is **spelled out**, not derived from Swift's `hashValue`: both
  are free to change between releases, and a changed fingerprint means every
  cached cover on every machine misses at once.
* The UUID is in the file name **in plain sight**, not only inside the digest:
  when one book's cover goes wrong, finding its file in the Finder is worth more
  than four saved characters. It is also how `cachedBookIDs()` answers "Missing
  Cover" with one directory read.
* `.img` whatever the format inside (HEIC where the system can write it, JPEG
  otherwise): ImageIO reads both from the content, and one extension keeps a
  file written by an older machine findable after an upgrade.
* Held under 1 GB by `CoverCachePolicy`, oldest first, down to the limit and no
  further — a cache that trims itself to half spends the next session rebuilding
  what it threw away.

## 6. Coming from Calibre

What `CalibreReader` reads out of `metadata.db`, and what it becomes. The
database is read **through a copy**, never in place
([ADR 0009](adr/0009-calibre-is-read-through-a-copy-of-metadata-db.md)).

| in `metadata.db` | in Shelf | in `metadata.opf` |
|---|---|---|
| `books.uuid` | `Book.id` — the identity (CONCEPT §5.3) | `dc:identifier opf:scheme="uuid"` |
| `books.title` | `Book.title` | `dc:title` |
| `books.sort` | `Book.titleSort` | `calibre:title_sort` |
| `books.timestamp` | `Book.addedAt` | `calibre:timestamp` |
| `books.last_modified` | `Book.modifiedAt` | `dcterms:modified` |
| `books.pubdate` | `Book.published` | `dc:date` |
| `authors` + `books_authors_link` | `Book.authors`, in link order | one `dc:creator` each |
| `series` + `books_series_link`, `books.series_index` | `Book.series` | `calibre:series`, `calibre:series_index` |
| `tags` + `books_tags_link` | `Book.tags`, sorted | one `dc:subject` each |
| `ratings` + `books_ratings_link` | `Book.rating`, Calibre's 0…10 kept whole | `calibre:rating` |
| `comments.text` | `Book.description` | `dc:description` |
| `identifiers` | `Book.identifiers`, scheme lower-cased | `dc:identifier opf:scheme=…` |
| `publishers` + link | `Book.publisher` | `dc:publisher` |
| `languages` + link, first by `item_order` | `Book.language` | `dc:language` |
| `data` | one `BookFormat` per file | — (the files themselves) |
| `custom_columns` | `LibraryDescriptor.customColumns` | — (`library.json`) |
| `custom_column_<n>` / `books_custom_column_<n>_link` | `Book.customValues` | `shelf:custom` |
| `books_plugin_data` | **ignored** (CONCEPT §7) | — |

Rules worth knowing:

* **Publishers and languages are read although CONCEPT §7 does not list them.**
  `Book` models both and every OPF gets a `dc:publisher` and a `dc:language`;
  an import that dropped a field the model has would not be the lossless one
  CONCEPT §2 promises.
* **Calibre writes a real comma in a name as a `|`.** `Le Guin|Ursula` is one
  name with a comma in it. Undone on the way in, before it can reach a folder
  name.
* **`books.isbn` is Calibre's legacy column** and the `identifiers` table wins
  where both have something.
* **A custom column has two shapes** and which one is Calibre's decision, not
  the datatype's: *normalized* keeps its values in their own table with a link
  table beside it (that is how one value is shared by many books), and a plain
  one keeps the value in the row. Both are read.
* **A `composite` column has no stored value** — Calibre computes it from a
  template — so there is nothing to import. A datatype this Shelf has never
  heard of is a line in the report and the other columns come in around it.
* **The cover comes from Calibre's `cover.jpg`**, not out of the book file:
  somebody who replaced a bad cover did it there. `CoverFile.name(for:)` then
  names the file after what the bytes actually are, so a PNG that Calibre calls
  `cover.jpg` arrives as `cover.png`.
* **The counting protocol counts the database *and* the disk**, because they
  disagree: `data` is what the library believes and the folder is what it has.
  A count from one of them alone is the one that makes an import look fine and
  then fail halfway.

## 6a. Where a book's metadata comes from, per format

One row per format: what is read out of the file, where the cover comes from,
which half of the program reads it, and what reaches `metadata.opf`.

The last column is the important one and it is the same for every row: **the OPF
gets the same fields whatever the file was**. That is what makes the folder the
truth (ADR 0001) — a rebuild reads the OPF and does not care that the book
arrived as an AZW3.

| Format | Metadata from | Cover from | Read by | Into `metadata.opf` |
|---|---|---|---|---|
| EPUB, KEPUB | `META-INF/container.xml` → OPF → Dublin Core, `calibre:series` | manifest's `cover-image`, else first image | core | every field |
| MOBI, AZW3 | PalmDB → record 0 → EXTH: 100 author, 101 publisher, 103 description, 104 ISBN, 105 subject, 106 date, 113 ASIN, 503 title, 524 language | EXTH 201 (an image record), else 202, else the first record that begins like an image | core | every field |
| PDF | `documentAttributes`: Title, Author, Subject, Keywords, CreationDate | page 1 rendered to PNG at 1 000 px | **app** (PDFKit) | every field |
| CBZ | `ComicInfo.xml` if present, else the file name (`ComicFileName`) | first page in natural order | core | every field |
| CBR | the same, through libarchive | the same | **app** (libarchive) | every field |
| KFX | nothing — the container is undocumented (ADR 0011) | nothing | nobody | title and author from the file name |

Two rules the table does not show:

* **A file that will not parse is still a book.** Every reader falls back to the
  file name and puts what went wrong in the import report. Nothing is refused
  for having odd metadata.
* **`fromTheFile` says which happened.** "The file says the title is X" and
  "Shelf guessed X from the name" are different claims, and the report makes the
  difference visible.

### Protection

`formats.drm` holds what protects *that file*, not that book — a book can be an
EPUB with Adobe's scheme and an AZW3 with Amazon's.

| Format | Recognised by |
|---|---|
| EPUB, KEPUB | `META-INF/encryption.xml` exists → `adobeADEPT` |
| MOBI, AZW3 | EXTH 209, or a non-zero PalmDOC encryption byte → `kindle` |
| PDF | `PDFDocument.isEncrypted` at import, `/Encrypt` in the trailer on a rebuild → `unknown` |
| CBZ, CBR, KFX | nothing is claimed |

It is **not stored in the OPF** and is deliberately not: it is re-derived from
the file on every rebuild (`DRMProbe`), so a file whose protection is gone stops
being badged. See [ADR 0012](adr/0012-drm-is-recognised-and-nothing-else.md).

## 7. `Import-Report.txt`

Plain text, appended to, one block per import, because the history of what came
into a library and what was skipped is worth more than the last run alone. It
leads with what was verified, names every skipped file and why, names every
failure, and ends with "Nothing at the source was changed, moved or deleted."
Dates and durations are formatted with a fixed locale: a record that reads
differently on another Mac is a worse record.
