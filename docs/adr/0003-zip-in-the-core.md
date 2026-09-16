# ADR 0003 – An own ZIP reader in the core; libarchive only for CBR

Date: 2026-09-16 · Status: accepted

This is decision 2 of CONCEPT §15, taken as proposed there.

## Context

An EPUB is a ZIP, and so is a CBZ. Reading one is therefore the gate every
format in Sprint 1 and most of Sprint 4 goes through. There were two ways:

* **libarchive**, which ships with macOS, reads ZIP *and* RAR, and is a mature C
  library nobody has to maintain.
* **A minimal ZIP reader in `ShelfCore`**, which would have to include a DEFLATE
  decoder, because ZIP entries are deflated.

"Standard vor Eigenbau" (Leitlinie, principle 2) points at libarchive.

## Decision

**A minimal read-only ZIP reader in `ShelfCore`, with a plain-Swift DEFLATE
decoder. libarchive only for CBR, in the app layer, in Sprint 4.**

The reason is one the Leitlinie also states, and which outranks the first here:
`ShelfCore` builds and tests on Linux, and that is the guard rail that keeps
AppKit, ImageIO and PDFKit out of it. If reading an EPUB needed libarchive, then
the EPUB reader, the metadata mapping, the cover extraction and the duplicate
logic would all sit behind a system dependency and could not be tested in CI –
and those are precisely the parts where a bug loses a book's metadata quietly.

So the line is drawn by *what has to be testable*:

1. **ZIP and DEFLATE decompression live in the core** (`ZipReader`, `Inflate`).
   Reading only: Shelf never writes a book file.
2. **RAR does not.** CBR needs libarchive, which is a system library and Apple
   only, so it goes in the app layer in Sprint 4 with a file-name fallback when
   the installed libarchive cannot read RAR5 (CONCEPT §13).
3. **The decoder is checked against zlib, not against itself.** Every DEFLATE
   test vector in `InflateTests` was produced by `python3 -c "import zlib; …"`
   with `wbits = -15`, and the compressed bytes are in the test verbatim. A
   decoder tested only against data this project compressed would agree with its
   own mistakes. The vectors cover all three block types, an overlapping
   back-reference at distance one, and all 256 byte values.
4. **The central directory is what is read**, not a walk of local headers from
   the front: it is the archive's own index, it is what every other tool trusts,
   and it means one entry can be pulled out of a 300 MB comic without reading
   the 299 MB in front of it.
5. **ZIP64 is named, not guessed at.** An archive whose sizes or offsets are
   `0xFFFFFFFF` keeps its real numbers in a record this reader does not read, so
   it reports `zip64NotSupported` rather than reading the wrong offsets. No EPUB
   is ever that large; a comic could be, and Sprint 4 will decide whether to
   add it or to hand those to libarchive.
6. **The decoder follows zlib's reference decoder `puff.c` in structure** – a
   bit reader, canonical Huffman tables as counts-plus-symbols, a symbol loop.
   That decoder exists to be read and checked against the standard, which is
   worth more here than the last few percent of speed.

## What it costs

* − About 250 lines of format code this project now maintains, in the one place
  where a bug is a corrupted book rather than a wrong pixel. Mitigated by the
  zlib vectors and by the fact that it only ever *reads*.
* − Plain-Swift DEFLATE is slower than zlib's. It does not matter for an OPF (a
  few kilobytes) and it is measured for covers in `CHANGELOG.md`. If a
  measurement ever demands it, a `Compression`-framework fast path can be added
  in the app layer *behind the same interface*, with the core's implementation
  kept as the tested reference – which is the shape the code is already in.
* − A ZIP writer exists in the core too (`ZipWriter`), which looks like scope
  creep for an app that never writes a book. It is there because the tests need
  EPUBs and this project will never have borrowed ones: the fixtures and the
  5 000-book synthetic library are built with it. Its doc comment says so, and
  no library code path calls it.

## What it buys

* The EPUB reader, the OPF mapping, cover extraction, duplicate detection and
  folder naming are all verified on Linux in CI, on every push.
* A synthetic EPUB can be built inside a test, which is why there are 250-odd
  core tests and no test data in the repository.
* `shelf-tool` runs the whole import on the command line with no Apple
  framework, which is how the numbers in `CHANGELOG.md` were measured.
