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
  ]
}
```

Pretty-printed, sorted keys, ISO-8601 dates — a file a person may well open in a
text editor, and one whose diffs should mean something. Written atomically.

`schemaVersion` is refused if it is higher than this Shelf understands: writing
such a library back could drop fields it does not know about.

Shelves are hierarchical (CONCEPT §15, decision 3) through a `parentID`, so
moving a shelf is one field change and not a rewrite of its children.
`ShelfTree.canMove` refuses a move that would make a loop, and both tree walks
carry a visited set so a loop that already exists (from a corrupt file) cannot
hang the app.

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
    <meta name="shelf:shelves" content="[&quot;Fiction ▸ Science Fiction&quot;]"/>
  </metadata>
  <guide/>
</package>
```

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

## 4. The index (`.shelf/library.sqlite`)

GRDB.swift over SQLite, WAL mode, foreign keys on, schema through versioned
migrations (`IndexSchema`). Tables as CONCEPT §5.2 names them:

| table | holds | rebuildable from |
|---|---|---|
| `books` | id (UUID as text), number, folder, title, title_sort, series_id, series_index, rating, is_read, publisher, published, language, description, added_at, modified_at, last_seen_at | the OPFs |
| `authors`, `book_authors` | one row per name; `position` keeps the printed order | the OPFs |
| `series` | one row per name | the OPFs |
| `tags`, `book_tags` | one row per keyword | the OPFs |
| `shelves`, `book_shelves` | the hierarchy and its contents | `library.json` + `shelf:shelves` |
| `formats` | one row per file: format, file_name, byte_size, **sha256**, modified_at, drm | the files |
| `identifiers` | scheme → value, plus a normalised `isbn_normalised` row | the OPFs |
| `custom_columns`, `custom_values` | Calibre's custom columns (Sprint 3, read-only) | the OPFs' unknown metas |
| `devices`, `device_books` | what is on which reader (Sprint 5) | the devices |
| `search` | FTS5 over title, authors, series, tags, description | everything above |

Notes:

* **The UUID is stored as text**, not as a blob, so the file can be read with any
  SQLite tool. A library nobody but Shelf can open would be the lock-in the
  Leitlinie forbids.
* **`formats.sha256` is indexed**, because it is how a duplicate is found and how
  a book already on a device will be recognised.
* **`identifiers` carries a second, normalised ISBN row** (`isbn_normalised`):
  the importer compares those, so `0-306-40615-x` and `030640615X` are one book.
* **`search` is a plain FTS5 table**, not one with external content: the text
  searched spans five tables, so there is no single row to point at.
  `LibraryIndex` writes that row whenever it writes a book — one place, rather
  than five triggers that have to stay in step. A book's search row is deleted
  and reinserted on every save, because FTS5 has no useful `UPDATE` and a stale
  search row shows up as "I renamed it and search still finds the old name".
* **The device tables exist from migration 1** although Sprint 5 fills them, so
  a library already in use does not need migrating then.
* **`last_seen_at`** records when the folder was last found as expected. A
  mismatch between index and disk is shown, never resolved silently
  (CONCEPT §5.2).

### Sort orders

`BookSort` owns the SQL, so the sidebar, the table header and a stored
preference cannot disagree about what "by author" means. Two rules are easy to
get wrong and are therefore written down:

* `COLLATE NOCASE` wherever a person's eye reads the column — a library that
  puts "Zola" before "adams" is unscannable.
* By series, books *without* one sort last: a `NULL` sorts before everything in
  SQLite, which would bury every series behind them.

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

## 6. `Import-Report.txt`

Plain text, appended to, one block per import, because the history of what came
into a library and what was skipped is worth more than the last run alone. It
leads with what was verified, names every skipped file and why, names every
failure, and ends with "Nothing at the source was changed, moved or deleted."
Dates and durations are formatted with a fixed locale: a record that reads
differently on another Mac is a worse record.
