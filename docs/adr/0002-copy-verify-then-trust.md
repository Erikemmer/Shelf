# ADR 0002 – Import: copy, verify, then trust

Date: 2026-09-16 · Status: accepted

## Context

Adding books to a library is where data can be lost. A copy that silently
truncated, a name collision that overwrote a book already there, an import
interrupted halfway and resumed into a folder with half a file in it – none of
these announce themselves. And unlike photographs off a card, an eBook usually
*is* the only copy: it came from a shop that no longer sells it, or from a
Calibre library the user is about to stop maintaining.

Selector solved the same problem for photographs in its ADR 0004, and the
solution was proved against 253 files and 7.4 GB before it had a window. Shelf
inherits the shape of it rather than reinventing it.

## Decision

1. **The source is only ever read.** Not moved, not renamed, not touched. The
   report ends with "Nothing at the source was changed, moved or deleted",
   which is checked in a test rather than merely printed.
2. **Copy, verify with SHA-256, then count it.** The source is hashed *while*
   it is read for the copy – one read, not two – the destination is read back
   and hashed, and only if the two digests match is the file renamed into place.
   "Verified" means a digest was compared, not that a copy call returned success.
3. **A file is written under a short random `.part` name.** Short and random,
   not the destination's name with a prefix: a book file may already use all 255
   bytes a path component is allowed, and prefixing it pushed the temporary file
   over the limit. That failed the copy for the longest titles *only*, which is
   the kind of bug that reaches a user rather than a test – it was found by the
   synthetic library's deliberately absurd every-hundredth title, and there is
   now a test for it.
4. **Nothing is ever overwritten.** The planner makes every folder and file name
   unique before the run starts; a file already sitting at the destination is an
   error, not something to write over.
5. **Free space is checked before the first byte.** Source × 1.05. Running out
   of space halfway is the one failure that leaves a library half-imported.
6. **The counting protocol is the plan.** What the sheet shows the user – n new
   books, n new formats, n skipped and why, n bytes, room needed – is the exact
   `ImportPlan` value the runner is then handed. There is no second computation
   that could differ from the one the user agreed to.
7. **Duplicates are decided by three tests, in this order** (CONCEPT §2.4):
   the file's SHA-256, then the normalised ISBN, then folded title + first
   author. ISBN before title because an ISBN names an *edition* and a title does
   not – "Dune" by Frank Herbert is one title and a dozen editions.
8. **The same book in a new format joins the book it belongs to**, in the folder
   it already has. That is what makes dragging a second file and a future
   "Add Format…" the same operation.
9. **An ambiguous match becomes a new book.** Two library books with the same
   title and author and no ISBN are a mess Shelf must not make worse by picking
   one of them. The new file becomes its own book and the "Duplicates"
   collection is where it gets resolved by hand.
10. **The preferred format defines the book.** When one drop holds a book's EPUB
    and its AZW3, the EPUB becomes the new book and its metadata and cover are
    kept. EPUB is the only format Sprint 1 can read metadata out of, so letting
    the AZW3 win would name a book after its file for no reason.
11. **Per-file problems never fail the import.** A file that cannot be read, a
    missing cover, an OPF that will not parse: the book is imported as far as it
    can be, and the report names every one. Only a problem that makes the whole
    run pointless – no space, an uncreatable folder – is thrown.
12. **Planner, plan and report are pure types in `ShelfCore`** and unit-tested
    without touching a file. Only copying, hashing and the window are in the app.

## Proven before the user interface

`shelf-tool import` runs the same plan and the same runner from the command
line, with the core's own SHA-256, and `Scripts/proof-run.sh` then checks the
digests against `/usr/bin/shasum` – a tool that knows nothing about this code.
The measured numbers are in `CHANGELOG.md`.

Two defects came out of doing this rather than assuming it:

1. **The `.part` name blew the 255-byte path limit** for the longest titles
   (decision 3 above). One file in twenty failed, and only the long ones.
2. **The in-memory test index was writing real files.** `DatabasePool` has no
   in-memory mode, and a pool asked for `":memory:something"` quietly creates a
   *file* of that name in the working directory. Sixty stray databases appeared
   in the repository and the tests shared rows between runs, which showed up as
   a unique-constraint failure that looked like a bug in the schema. The
   in-memory index is a `DatabaseQueue` now, which is the API that actually has
   one.

## Consequences

* + The expensive, irreversible step has the strongest guarantees: nothing is
  deleted, nothing is overwritten, and a verified file has had its hash compared.
* + The import is idempotent: running it again over the same folder skips
  everything by content hash and reports what it skipped.
* − Verifying costs a second full read of the destination. On a 20 GB Calibre
  library that is real time, and it is the point of the exercise.
* − The digest of every source file is computed before the plan can be made, so
  the counting protocol is not instant for a large drop. The sheet says what it
  is doing while it works.
* − Shelf cannot promise the source is safe to delete: it can only say which
  files it verified. The report is what the user reads before deleting anything,
  and deleting is never Shelf's doing.
