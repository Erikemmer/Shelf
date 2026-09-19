# ADR 0019 – The OPF decides whether an export is an archive or a pile of files; hard links only on one volume

Date: 2026-09-19 · Status: accepted

## Context

CONCEPT §4 had "export a selection as a folder (a copy) with the name pattern
`{author} - {title}`" under *Should*, and read as a convenience: a way to get
some books onto a stick. Sprint 8 moved it to *Must*, and once it is a Must it
has to answer a harder question than "which files go where".

The *Leitlinie*'s third principle is no lock-in: **every database fully
exportable**. For Shelf that has a sharp edge. The book files are not the
library. What somebody spends years building is the *metadata* — the ratings,
what has been read, the tags, the shelves — and none of it is inside a book
file, because a book file is never written (CONCEPT §4). All of it is in
`metadata.opf`.

So an export that writes only book files is not a lesser export. It is a
different kind of thing, and somebody who chooses it because it sounds tidier
has silently thrown away the part that was theirs.

There is a second question underneath, which is the one that decides whether
this feature is used at all. An archive of a 20 GB library costs 20 GB and
twenty minutes. Nobody runs that weekly, which means nobody has a current
archive, which means the feature exists and does not work.

## Decision

**1. The `metadata.opf` is what makes an export an archive.** With it, the
folder is a library: it can be imported back into Shelf with nothing lost, and
Calibre's own "add books from directories" reads it too. Without it, the folder
is a pile of book files. The presets are named for that difference and not for
their settings — *Archive*, *Just the books*, *For Calibre* — and the one that
leaves the OPF out **says what it costs, in the dialogue, before anything is
pressed**, and again in the report written into the folder:

> The rating, the read status, the tags and the shelves will not go with them —
> they live in the metadata.opf, and that is not written.

**2. An import believes a `metadata.opf` beside a book, outright.** This is the
other half of the same decision and without it the first half is a lie: writing
the OPF is useless if reading it back is not implemented. `SidecarMetadata`
takes the OPF's answer for every field, including the fields it leaves empty.
An empty field in a record is a statement, not a silence — see *What this cost
to learn*.

**3. For Calibre, the shelves and the read status are also written as tags.**
`Shelf/Fiction/Sci-Fi` and `Read`. Calibre ignores a `<meta>` it does not know,
which is exactly what makes it safe to write Shelf's own fields into a library
Calibre also reads — and exactly why they do not survive the way back
(`docs/RUNBOOK.md` §6). A Calibre *custom column* would have been the faithful
mapping and is not available: a custom column has to be declared in Calibre's
`metadata.db` before a value in an OPF means anything, and Shelf never writes
to `metadata.db` (ADR 0009). A tag needs no declaration.

It is a **mapping and it says so**: the prefix is visible, the dialogue
explains it in one sentence, and Shelf's own metas are written beside the tags
rather than instead of them — so the same folder still re-imports into Shelf
without loss.

**4. A second export writes only the differences, and never reads back.** A
manifest at the destination records what Shelf wrote and with which options. A
second run compares the *library* against that record. It does not consult the
exported files to find out what a book is: somebody who edits an exported OPF
has edited a copy, and the next export overwrites it without ceremony. That is
the difference between an export and a sync, and Shelf is not offering a sync —
two authorities that can disagree is the failure this whole program is arranged
to prevent.

(This is not in tension with copy-verify-then-trust. The runner does read back
the file it has just written, to hash it; that is what "verified" means, here
as everywhere. What it never does is take *metadata* from the destination into
the library.)

**5. An export tidies its own previous output, and nothing else.** A book whose
title has changed has a new file name; the old file is removed. Only paths the
previous manifest names, and only while the file is still the size that
manifest recorded — anything a person has changed is left alone and named in
the report instead.

**6. Hard links on the same volume; a copy across volumes, without asking.** A
link costs a directory entry and no bytes, which is what makes an archive of a
large library something somebody will actually run. It is safe **here and
nowhere else** for one reason: a book file is never written, so the two names
cannot come to differ. Across a volume boundary a link is impossible, and
stopping to say so would be stopping to say that physics is physics.

## What this cost to learn

Both of these were found by the proof run — by exporting a library, importing
it into an empty one, and comparing the two book by book. Neither would have
been found by a test of the export alone, because each half was behaving
reasonably.

1. **Filling the OPF's gaps from the book file was wrong.** The first version
   of `SidecarMetadata.merged` used the OPF where it had something and the
   file where it did not. A book with **no author** has an OPF that says so by
   saying nothing — so the file's own guess got through, and the file's guess
   came from its *name*, which the export had just written from the very
   metadata being reconstructed. One book came back with its title as its
   author.

2. **An export that does not tidy up corrupts the next import.** With the old
   file left beside the new one, the destination held the book twice — once
   under its old name with its old OPF. Importing such a folder, the older copy
   sorts first, is read first, and wins. A round trip came back with titles the
   library had corrected weeks earlier.

## Consequences

* + A library can leave Shelf at any moment and come back whole. That is
  checked rather than claimed: `Scripts/proof-run.sh` exports an archive,
  imports it into an empty library and compares titles, authors, ratings, read
  status, series, shelves and tags.
* + The way back to Calibre stops losing the shelves and the read status, which
  `docs/RUNBOOK.md` §6 had to admit in Sprint 7.
* − The sidecar rule costs something in one case: a hand-written, sparse OPF
  beside a richly tagged EPUB loses the EPUB's extras. That is the right way
  round. A `metadata.opf` is a deliberate record — Shelf writes one, Calibre
  writes one — and both write it complete.
* − An export destination is a place Shelf removes files from. Its own files,
  at paths its own manifest names, at the size it wrote them; nothing else in
  that folder is ever a candidate.
* − A hard-linked export is not a backup. It is one copy of the bytes with two
  names, so a disk failure takes both. The report says how many links it made,
  so the difference is visible rather than assumed.
