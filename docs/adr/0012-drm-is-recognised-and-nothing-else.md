# ADR 0012 – DRM is recognised, said out loud, and otherwise untouched

*Status: accepted · 18 September 2026 · Sprint 4*

## The question

Part of any real library is protected: EPUBs with Adobe ADEPT, Kindle files with
Amazon's, the odd encrypted PDF. Shelf has to do *something* when it meets one,
because a protected file's metadata is thin and its cover often unreachable, and
a program that shows a book with no title and no explanation looks broken.

## What was decided

Shelf **detects** protection and **says so**. It never removes it, never works
around it, and nothing in this repository explains how to.

* **EPUB** — `META-INF/encryption.xml` is present.
* **MOBI and AZW3** — EXTH record 209, or a non-zero PalmDOC encryption byte.
* **PDF** — `PDFDocument.isEncrypted` at import; the tail of the file naming
  `/Encrypt` on a rebuild, where PDFKit may not exist.
* **CBZ, CBR, KFX** — no scheme Shelf recognises, so no claim is made.

What follows from detecting it is exactly three things: a badge in the grid and
on the file's row in the inspector; the metadata that is still in the clear is
read and kept; and a line in `Import-Report.txt` saying the file is protected
and was left alone.

## Why

CONCEPT §1 and §12 already say Shelf removes no DRM. This ADR is about the
weaker and more tempting thing: that *detecting* protection could be read as a
step towards handling it. It is not, and the code says so in the place it would
be tempting — `DRMProbe` answers one question and has no other entry point, and
`SyntheticEPUB.withAdobeDRM` and `SyntheticMobi(withKindleDRM:)` write files
that **announce** protection without being encrypted, because what Shelf claims
is that it reads the flag and stops. A fixture that were genuinely encrypted
would test nothing further and would be a thing this repository should not hold.

Detection earns its place by being the difference between "this book is broken"
and "this book is protected, which is why its author is missing". That is a
sentence the user can act on.

## Two decisions inside this one

**The badge is a fact about the bytes, not a note.** `DRMProbe` is asked again
on every rebuild rather than the answer being stored and trusted. That costs one
narrow read per file — an EPUB's central directory, a MOBI's record 0, a PDF's
last 8 KB — and it buys two things: a file whose protection is gone stops being
badged, and the index stays a cache that can be thrown away (ADR 0001).

This was not free knowledge. The first implementation stored the flag at import
and the rebuild dropped it: nine protected files in the measuring library, nine
badges, and after `Rebuild Index from Folders` zero, with nothing failing and
nothing logged. The proof run found it.

**A book whose files disagree is badged plainly "DRM".** A protected book bought
twice really is an EPUB with Adobe's scheme and an AZW3 with Amazon's. The grid
has room for one badge, and naming either would be wrong about the other file,
so `LibraryEntry.drm` answers the generic kind when the kinds differ. The
inspector lists every file with its own badge, which is where the whole truth
belongs.

## What it costs

* **The PDF probe on a rebuild is a heuristic**, and is named as one in the
  code: an encrypted PDF names `/Encrypt` in its trailer, and a cross-reference
  stream can hide that from a tail read. It errs towards "not protected", which
  is the smaller wrong — a missing badge beats a badge on a file that reads
  perfectly well.
* **No genuinely protected file has been read.** The fixtures announce
  protection; they are not encrypted. Whether a real ADEPT EPUB or a real Kindle
  purchase is detected has not been measured, and cannot be until Erik points at
  one.

## Related

* CONCEPT §1, §6, §12 · [ADR 0011](0011-mobi-with-an-own-parser-kfx-as-a-file-only.md)
* [ADR 0001](0001-folder-is-the-truth.md) — why the badge has to be re-derivable.
