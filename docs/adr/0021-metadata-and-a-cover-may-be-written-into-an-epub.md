# ADR 0021 – Metadata and a cover may be written into an EPUB, on request

Date: 2026-09-21 · Status: accepted and implemented — metadata in the
window since Sprint 10, Schritt E2 (21 September 2026), the cover since
Sprint 11, Schritt 3 (22 September 2026): both now live behind one command,
"Write into the Book File", one confirmation, one plan

## Context

Shelf's most visible promise, since Sprint 1, is CONCEPT §4 under "Won't":
**a book file is never written, deleted or overwritten.** Metadata goes into
`metadata.opf` beside the book and into the index — never into the book. It
is repeated in `CLAUDE.md` as one of "the rules that are not negotiable", and
it is why every path in `docs/RUNBOOK.md` is a copy, a read, or a write to an
OPF: "if a path ever seems to need a book file changed, it is the wrong
path."

The reason the rule existed is still true and this ADR does not touch it: a
book file is often something a person cannot get back — bought once, from a
shop that may not sell it again, or the one surviving copy of something
scanned by hand. Writing into it is the one mistake in this program that
cannot be undone by rebuilding an index or emptying a Trash a different way.

The reason to reverse it anyway is what the folder-is-the-truth model itself
keeps surfacing: `metadata.opf` is Shelf's record, and Calibre's, but it is
not the book's own. Open the EPUB anywhere else — another reader, another
Mac, a phone with no Shelf on it — and the title, the author and the cover
are whatever the file *itself* says, which for an import that took its
metadata from a folder name is nothing worth reading. Two sprints of
metadata editing widen that gap every time somebody corrects a title and
does not know the file they can hand to a Kindle still carries the old one.

## Decision

**A book's own metadata and cover may be written into its EPUB file,
on an explicit command, with `metadata.opf` as the source of truth.**

What the command does, once it exists (not part of this ADR's own writer —
see below):

1. **Nothing happens automatically.** No field edit, no cover replacement,
   no import writes an EPUB. This is a separate, named command a person asks
   for, book by book or for a selection — never a side effect of anything
   else Shelf already does.
2. **A confirmation names every file** it is about to touch, the same shape
   as ADR 0014's device-deletion confirmation and CLAUDE.md's own rule for
   it. Nothing runs unconfirmed.
3. **A new file is written beside the original**, never in place. The
   original is not touched until the new file exists, is verified, and the
   person has agreed to the swap.
4. **The person reviews before the swap.** What changed is shown — old
   metadata beside new, the same shape Sprint 6's online-metadata dialogue
   already uses — before anything is exchanged for anything.
5. **The original goes to the Trash**, through the same `FolderDisposal` seam
   a replaced cover and an emptied author folder already go through (ADR
   0020, ADR 0018). Never `removeItem`. A disposal that cannot take it means
   the swap does not happen and nothing is lost.
6. **DRM is refused**, not attempted and not worked around. A file
   `DRMProbe` marks as protected does not reach the writer at all — CONCEPT
   §12 is not negotiable and this ADR does not ask it to be.
7. **EPUB only.** MOBI, AZW3, PDF, CBZ and CBR are not in scope, now or
   implicitly later. Each of those formats has its own container quirks, its
   own risk of corruption, and its own ADR to earn if it is ever proposed —
   this decision is not a precedent for them.

**What this ADR itself builds is smaller than the command above: the
zip-level writer the command will eventually stand on**, proven against
archives this project generates itself, never against a book in a library.
No command exists yet. No confirmation, no swap, no Trash disposal of a real
book file happens until a later sprint builds the window part and Erik has
seen the bytes it produces.

**That command exists now.** "Write into the Book File" shipped for
metadata in Sprint 10, Schritt E2, and for the cover in Sprint 11, Schritt
3 — the confirmation naming every file and every field old → new, the new
file written and read back before anything is displaced, the original to
the Trash, no ⌘Z. Everything this paragraph describes as not yet built has
been built, against real EPUBs (`Scripts/real-epub-proof.sh`) as well as
synthetic ones.

## What is explicitly not decided here

- **`CLAUDE.md` and `docs/CONCEPT.md` §4 are not changed by this ADR.** The
  "never written" rule stays written down as it is until the command that
  replaces it actually exists to be pointed at. This document is the record
  that the change is planned and why; the rule itself falls when the window
  part ships, not before.
- **No automatic write-along.** A field changed in the inspector still only
  reaches `metadata.opf` and the index, exactly as today. Keeping the EPUB
  in step with every edit was considered and rejected: it would turn a
  reversible, cheap OPF write into an irreversible, expensive one on every
  keystroke's worth of change, for a promise ("the file matches what Shelf
  shows") that a deliberate, occasional command can keep just as well
  without that cost.
- **No format beyond EPUB.** See point 7 above.

## What this buys

- The most common reason to want this — "give me back a file I can hand to
  a device or a person, with the metadata I actually have" — is answered
  without asking Shelf to become a converter or a DRM-removal tool, neither
  of which this project has ever wanted to be (CONCEPT §12, "Won't").
- The book-file rule stays the strongest guarantee in the program for
  MOBI, AZW3, PDF, CBZ, CBR and every DRM-protected file, which is most of
  what a real library holds. It is narrowed for one format, on request, with
  a Trash under it — not dropped.

## What it costs

- − A rule that was previously absolute ("never" in every document that
  states it) becomes conditional ("never, unless asked, and only for an
  EPUB, and never on DRM"). Every place that rule is written has to be read
  again once the command ships, to say the new shape correctly rather than
  overstate or understate it.
- − A zip writer is new, real complexity in `ShelfCore` — offsets, headers, a
  format with rules a subtly wrong writer can violate while still producing
  a file most readers tolerate. That risk is exactly why this ADR splits the
  writer from the command: the writer is built and proven first, against
  synthetic archives, before anything is asked to trust it with a book.

## Addendum – 25 September 2026, Sprint 23, Teil B

**A whole selection, not only one book, could already be handed to "Write
into the Book File…"** — `EPUBWrite.plan(for:library:)` and `.run` took
`[LibraryEntry]`/`[BookPlan]` since Sprint 10, Schritt E2, and the sidebar's
own multi-selection context menu already called `beginEPUBWrite(for: books)`
for exactly this. What this addendum adds is not multi-selection itself, but
three things a run against hundreds of books, rather than a handful, turns
out to need:

1. **The first failure halts the run.** Before this, a refused or failed
   book was recorded and `run` pressed on through the rest of the selection.
   Now it stops there — every plan after it comes back `.notAttempted`,
   named rather than silently missing, and its file is exactly as it was,
   because `EPUBFileReplacement.replace` was never asked to touch it. A
   failure among 366 books is worth a person's own look before the other
   365 are written past it; nothing here changes what a *success* does.
2. **"Stop After This Book"**, during a run — the same shape as a first
   failure: the book already in flight (atomic, never interrupted
   mid-write) finishes, and everything after it is `.notAttempted`.
   `EPUBWrite.run` takes an injectable `isCancelled` closure, defaulting to
   `Task.isCancelled` — the same cooperative-cancellation idiom
   `OrganizeRunner` already checks, wired here for the first time to an
   actual button (`LibraryModel.stopEPUBWrite()` cancels the detached task
   `run` executes inside).
3. **`EPUBWriteManifest`** (`.shelf/epub-write-report.txt`, appended to,
   never overwritten — the same shape `Import-Report.txt` already uses):
   one line per book actually written, naming the hash it had, the hash it
   has now, and where the original went. **Never read back by `run`
   itself** — resuming an interrupted run needs no manifest at all, because
   a fresh plan already shows an already-written book as having no change
   left to make (`BookPlan.hasChange`), the same way `Organize`'s own
   folder-state repair works from the folders rather than from its
   manifest. This one is a record for a person, not a second source of
   truth, which is also why losing it is tolerated rather than thrown —
   the book it describes is already correct by the time a line would be
   written for it.

The confirmation sheet gained the numbers this addendum's own task asked
for — to write / already the same / cannot be written, each read back from
the same plan the list below shows — and the finished summary now names how
many succeeded, were already the same, failed, or were never attempted,
plus where the manifest lives. Every rule ADR 0021 itself states — EPUB
only, DRM refused, the confirmation naming every field, no ⌘Z, the original
to the Trash — is unchanged; this addendum is about what happens *around*
one book's own write when there are many of them, not about the write
itself. 4 new core tests (`EPUBWriteTests.swift`), `CHANGELOG.md` has the
numbers.
