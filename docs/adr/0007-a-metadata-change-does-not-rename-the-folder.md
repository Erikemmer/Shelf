# ADR 0007 – A metadata change does not rename the book's folder

Date: 2026-09-17 · Status: accepted

## Context

Sprint 2b makes the title and the authors editable. Both of them are in the
book's path: the library is laid out as `AuthorSort/Title (number)/`, Calibre's
own shape, and the importer builds that path from the book's metadata
(`docs/DATA-MODEL.md` §1). So the first question an editable title asks is:
when somebody corrects "Ancilary" to "Ancillary", does the folder follow?

Calibre renames. It has an index that is the authority and a `path` column it
updates in the same transaction, so the folder is a consequence of the metadata
and keeping the two in step is bookkeeping.

Shelf's arrangement is the other way round. **The folder is the truth and the
index is a cache** (ADR 0001): the index can be deleted at any moment and
rebuilt by walking the folders. That inverts what a rename costs.

## Decision

**A metadata change never renames a folder.** Editing the title, the authors or
anything else writes `metadata.opf` and the index, and leaves the path exactly
as it is. A folder named after an old title is not a defect; it is a name.

Renaming becomes a separate, deliberate command — **"Reorganize Library…"**,
with a preview of every move and a report afterwards, listed in
`docs/BACKLOG.md` for a later sprint.

## Why

1. **The identity is the UUID, not the path.** `dc:identifier opf:scheme="uuid"`
   in each OPF is what makes a rebuild *reconstruct* a library rather than
   reinvent it — shelves, reading status and covers still point at the same
   books afterwards (CONCEPT §5.3). The path carries no identity, so nothing
   breaks when it goes stale. If the path *were* the identity, it would have to
   be kept correct, and this ADR would have to say the opposite.

2. **A rename is the one file operation that can lose a book.** Everything else
   Shelf does to a library is "write one small file next to the book". A rename
   moves the book itself: it can half-fail across a volume, it can collide with
   an existing folder, it can hit a name the file system refuses after
   sanitising, and on a case-insensitive file system "the same name in different
   case" is a special case of its own. The rule that a book file is never
   written, deleted or overwritten in v1.0 (CONCEPT §4) is worth very little if
   the *folder around it* moves on every typo fix.

3. **It would happen at the worst moment.** A title is finished by ⏎ or by the
   field losing focus, which is the moment a person moves the pointer away. A
   rename there means a Finder window jumping, an open file handle pointing at
   the old path, and a Time Machine backup copying the book again — for a
   correction to one character.

4. **Batches make it worse, not better.** Sprint 2c brings multiple selection
   and editing a field across a selection. Renaming 200 folders as a side effect
   of one edit is not something to do without a preview and a way back, and once
   there is a preview and a way back it is a command, which is what
   "Reorganize Library…" is.

5. **Nothing goes stale that cannot be seen.** The inspector's *Show in Finder*
   reveals the folder, so where a book lives is never a mystery; and because the
   folder is the truth, a stale name costs nothing but tidiness.

## Consequences

* A library that has been edited for a while has folder names that are
  historical. That is the cost, and it is the one being chosen.
* The importer still builds a *new* book's folder from its metadata, because
  that is the moment the metadata is all there is.
* `BookFolderName` keeps every rule it has; "Reorganize Library…" will use it
  unchanged when it arrives.
* The proof run checks the consequence that matters: after 200 books have had
  their titles, tags and descriptions changed, every EPUB is byte for byte what
  it was, and a rebuilt-from-scratch index finds all 200 changes — through the
  folders, under their old names.
