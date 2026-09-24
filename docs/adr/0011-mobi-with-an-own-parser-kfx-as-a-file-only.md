# ADR 0011 – MOBI and AZW3 get their own parser; KFX is carried, not read

*Status: accepted · 18 September 2026 · Sprint 4*

## The question

Shelf has to read MOBI and AZW3 to be a Calibre replacement: a library grown
over years has thousands of them. Three ways were open — call out to a program
that already reads them, take a library in, or write the parser.

And a fourth format is in the same family and is a different question: Amazon's
KFX, which every recent Kindle purchase is.

## What was decided

**MOBI and AZW3 are read by a parser in `ShelfCore/Formats/Mobi`**, written from
the public format descriptions: the PalmDB container, record 0's PalmDOC and
MOBI headers, and the EXTH records.

**KFX is listed and never opened.** A `.kfx` is carried as a file with a name, a
size and a digest; `BookFileFormat.hasReadableMetadata` is false for it and the
inspector says why in one sentence.

## Why

**Not calling out to a program.** Calibre's `ebook-meta` reads these formats
well. But Shelf would then be a program that does not work until another program
is installed, for a job it does at import time on every file — and CONCEPT §4
puts calling Calibre in "Won't (v1.0)" for conversion precisely because a
dependency on a second application is a thing to take on deliberately, once, and
not by the back door.

**Not a library either.** There is no maintained Swift package for MOBI, and the
C ones would have to be vendored and kept. The Leitlinie says *Standard vor
Eigenbau*, and this is the case where the standard costs more than the thing it
saves: the part of the format Shelf needs is a header and a list of key/value
records, and it is about three hundred lines.

**The format is small where Shelf touches it.** Shelf reads metadata and a
cover. It does not decompress the text, so PalmDOC compression, HUFF/CDIC and
the whole KF8 rendering path are not its business. The risk CONCEPT §13 names —
"many variants" — is a risk about *text*; the header and EXTH have been stable
for fifteen years.

**KFX is a different answer because the question is different.** Its container
is undocumented. A parser written against guesses would produce plausible wrong
answers — a title from the wrong offset is still a title — and nobody looking at
the library would know. Carrying the file by name and size is less, and it is
true. The alternative that was rejected was leaving `.kfx` out of the importable
list altogether: a file the user can see in the Finder and cannot find in Shelf
is worse than one Shelf admits it cannot open.

## What it costs

* **The fixtures are ours too.** `SyntheticMobi` writes the files the tests read,
  from the same description the parser was written from — so a fixture can agree
  with the parser and with nothing else. Two things are done about that: the
  fixture's byte offsets are written out longhand rather than borrowed from
  `MobiHeader`'s constants, so a typo in one does not cancel a typo in the
  other; and several tests assert against fixed byte positions and hand-written
  bytes instead of against whatever the writer produced.
* **It has read no MOBI bought from Amazon.** No borrowed book is in this
  repository (CLAUDE.md) and none has been tried by hand. That is the honest
  limit of what these tests prove, and it is the first thing to do with a real
  library when there is one.
* **Windows-1252 had to be written out as a table.** `String.Encoding` does not
  carry the single-byte code pages in swift-corelibs-foundation, and the core
  builds on Linux. Thirty-two characters, in `MobiHeader`.

## The two things most likely to be got wrong later

* **The container is big-endian.** The ZIP reader in the next folder is
  little-endian. `PalmDatabase.uint16`/`uint32` are the only places that matters
  and they are tested against bytes written by hand.
* **A comma is not an author separator.** MOBI files overwhelmingly write
  authors surname-first — `Le Guin, Ursula K.` — so splitting on commas turns
  one author into two half-people. `AuthorField` splits on `&` and `;` only, and
  is shared with the PDF reader and the comic reader for exactly this reason.

## Related

* [ADR 0003](0003-zip-in-the-core.md) — the same shape of decision for ZIP.
* [ADR 0012](0012-drm-is-recognised-and-nothing-else.md) — what happens when one
  of these files is protected.
* CONCEPT §6, §13.

## Addendum – 24 September 2026, Sprint 18, Teil B4

**KFX's own container marker may now be read for DRM, on Erik's explicit
instruction, while the rest of this ADR stands unchanged: KFX content is still
never decoded.** `DRMProbe` reads only the first bytes of the file, or (for a
KFX-ZIP) the archive's own entry list — never the KFX payload itself:

* the bytes start with `DRMION` → protected (Kindle DRM)
* the file is a KFX-ZIP holding an entry named `*.voucher` → protected
* the bytes start with `CONT`, KFX's plain non-ZIP container → clean, and
  confidently so — a raw container has no ZIP entries to hold a voucher in
* anything else — unrecognised bytes, a KFX-ZIP with no voucher, a file that
  cannot be opened — stays **"not checked"**, never guessed at and never
  removed. A KFX-ZIP without a voucher is not treated as proof of "clean":
  only the `CONT` case is a positive, structural absence of anywhere a voucher
  could be; the ZIP case is just the one signal this project knows how to read
  being missing, which is a weaker claim.

Nothing decrypts, nothing is worked around, and every other line of this ADR —
KFX still has no metadata, no cover, no text — is unchanged.

`BookFileFormat.drmIsExaminable` stays a format-level constant, false for KFX
always, because *metadata* reading did not change. What changed is file-level:
`BookFormat.drmExamined` (new column `formats.drm_examined`, migration
`v4-drm-examined`) says whether **this** file's container was actually
classified, which for KFX now depends on its bytes rather than being a
constant of the format. `DRMKind.kfx` is a distinct case from `.kindle` on
purpose — the signal is a container marker on an undocumented format, not
MOBI/AZW3's own documented EXTH record, and the two are worth keeping
distinguishable in a test or a report even though both name the same
account-tied scheme to a person.

Existing KFX rows, indexed before this addendum, are migrated to
`drm_examined = false` — honestly "not yet asked" until a re-import or
`Rebuild Index from Folders` re-derives the real, per-file answer, which is
the same path the original DRM-survives-a-rebuild fix already relies on
(`Tests/ShelfCoreTests/DRMProbeTests.swift`).

See `docs/BACKLOG.md`'s "Not building a KFX parser or a KFX DRM probe here,
per instruction" — that instruction is superseded by this addendum, narrowly,
for DRM detection only.
