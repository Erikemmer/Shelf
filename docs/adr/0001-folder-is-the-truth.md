# ADR 0001 – The folder is the truth, the index is rebuildable

Date: 2026-09-16 · Status: accepted

## Context

A library of 8 000 books needs an index. "All science fiction, unread, ordered
by series" cannot be answered by reading 8 000 files, and full-text search
cannot be done at all without one. So there will be a SQLite database.

The question is what that database *is*. Calibre's `metadata.db` is the
authority: the folders hold the files, the database holds the meaning, and if
the database is lost or corrupted the library is damaged in a way no amount of
looking at the folders repairs. That is why a Calibre user who has been through
it once keeps backups of one file.

Shelf has the same problem and a different answer available, because it starts
from Selector's rule about originals: the files on disk are the truth and the
app's own state is derived.

## Decision

1. **Everything about a book lives next to the book.** Its folder holds the book
   files, `cover.<ext>`, and `metadata.opf` in the Calibre OPF schema – Dublin
   Core plus `calibre:` metas, plus Shelf's own fields as `shelf:` metas, which
   Calibre ignores. A book's UUID is in that OPF as
   `dc:identifier opf:scheme="uuid"`, so the folder alone identifies it.
2. **The index (`.shelf/library.sqlite`) is a cache.** It may be deleted,
   vacuumed, replaced by a newer schema, or thrown away after a crash.
   `IndexRebuilder` walks `Author/Title (n)/` and reconstructs it, and
   `Library ▸ Rebuild Index from Folders` offers exactly that to the user.
3. **What the folders cannot hold is mirrored into them.** Shelves are the only
   thing the index knows that a book file does not: they are written into every
   book's OPF as `shelf:shelves` *and* into `.shelf/library.json`. Two copies of
   a small amount of data, so that no single loss costs the user an evening's
   arranging.
4. **The index never silently disagrees with the disk.** A rebuild reports
   folders that hold no readable book and books whose OPF could not be read; it
   never deletes or tidies anything (CONCEPT §5.2: "Abweichungen werden
   angezeigt, nie still verworfen").
5. **A folder number, not a UUID, is in the path.** `Pride and Prejudice (17)`
   is what makes two books of one title distinct, exactly as in Calibre, so an
   import can take a tree over unchanged. A 36-character UUID in every folder
   name would make the paths unreadable and push against the 255-byte limit.
6. **The counter is stored, not derived.** `library.json` holds
   `nextBookNumber`. Deriving it from the highest existing folder would let a
   book deleted in the Finder hand its number to the next import, which would
   then aim at a folder that may still have files in it.

## What this buys

* The index can be opened in WAL mode and treated casually, because nothing in
  it is irreplaceable.
* A library can be copied with the Finder, backed up with Time Machine, or
  handed to Calibre, and nothing is lost in the process.
* `make test` can erase and rebuild an index inside a test, which is how the
  claim is checked rather than asserted (`IndexRebuilderTests`).
* iCloud Drive can be *warned about* rather than refused: SQLite in a synced
  folder can be corrupted, and here that costs a rebuild rather than a library.

## What it costs

* − Writing a book's metadata means writing two things: the OPF and the index.
  They can disagree if a write fails halfway, which is why the OPF is written
  atomically through a `.part` file and why the index is the one that can be
  rebuilt from the other and not the reverse.
* − A rebuild reads every `metadata.opf`. Measured on 5 000 synthetic books, see
  `CHANGELOG.md`; digests are reused when a file's size and modification date
  are unchanged, so the expensive part is not repeated.
* − Shelf's own fields sit in a foreign schema's extension mechanism. Calibre
  ignores unknown metas today; if it ever stopped, a Shelf library would still
  be readable but a round trip through Calibre could drop the read status.
  Accepted: the alternative is a schema only Shelf can read, which is the
  lock-in the Leitlinie forbids.
* − Two books really can share a title, an author and have no ISBN. The folder
  number keeps them apart on disk, and the "Duplicates" collection is where that
  gets sorted out by hand. The importer refuses to guess between them.
