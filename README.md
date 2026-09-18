# Shelf

An eBook manager for the Mac that looks like [Selector](https://github.com/Erikemmer/Selector)
and behaves like a library: covers, metadata, shelves, a Calibre import, and
your readers. macOS 14+, Swift 6.

**What it is not**, on purpose: not a reader, not a converter, not a content
server, and it does not touch DRM in any way. In v1.0 it does less than Calibre
and does it with the quiet and the speed Selector has for photographs.

## The promises

* **A book file is never written, deleted or overwritten.** Metadata goes next
  to the book, in `metadata.opf`, and into an index — never into the book.
* **The folder is the truth.** The database is a cache that can be deleted and
  rebuilt from the folders at any time. Your library survives this app.
* **Copy, verify, then trust.** Every file copied in is hashed on both sides
  before it counts as taken over.
* **A Calibre library is only ever read**, byte for byte unchanged.
* **DRM is detected and then left alone.** Never removed, never worked around.
* **Nothing from the net is taken over without being ticked.** ⌘E asks Open
  Library and Google Books, shows every field old beside new, and ticks only
  what fills a gap. A service that does not answer is one line in the status
  bar, never a dialogue.

## Getting it running

```bash
make bootstrap     # first time on a Mac: checks Xcode, installs XcodeGen,
                   # runs the tests, generates and builds the project
```

Then press ⌘R in Xcode, or:

```bash
make app           # build the app, Release
make smoke         # start it and check it shows a window and settles
```

## Everyday commands

```bash
make test          # ShelfCore's tests — these run on Linux too
make lint          # swift-format, strict
make format        # reformat in place
make project       # regenerate Shelf.xcodeproj from project.yml
make synthetic     # generate 5 000 synthetic EPUBs to measure against
make proof         # import them, verify the digests, rebuild the index
make synthetic-clean   # delete the test material, and say how much came back
make online-proof  # ask both metadata services about ten ISBNs and refresh the
                   # test fixtures. The only thing in the build that uses the
                   # network — no test and no CI job does
```

`make help` lists them all. Before every commit: **`make test && make app &&
make lint && make smoke`**, all four green.

## Where things are

| | |
|---|---|
| `Sources/ShelfCore/` | everything that can be decided without a window. Builds and tests on Linux, which is what keeps AppKit out of it. |
| `App/Shelf/` | the window: SwiftUI + AppKit, the cover pipeline, ImageIO. |
| `Sources/shelf-tool/` | the same import and rebuild on the command line, for proof runs. |
| `docs/CONCEPT.md` | what Shelf is, in full. |
| `docs/ARCHITECTURE.md` | the building blocks and the data flows. |
| `docs/DATA-MODEL.md` | the folder layout, the OPF, the index schema. |
| `docs/adr/` | the decisions, and what they cost. |
| `docs/BACKLOG.md` | the sprints, and what is done. |
| `CHANGELOG.md` | what changed, with the measured numbers. |

The look lives in [SlateKit](https://github.com/Erikemmer/SlateKit), a package
shared with Selector and used through a tag — see
[ADR 0004](docs/adr/0004-slatekit-shared-with-selector.md).

## Test data

Synthetic and generated. No borrowed book is in this repository, and none needs
to be: the tests build their own EPUBs, and `make synthetic` writes a library of
5 000 of them under `~/Library/Caches/Shelf/` — never under `~/Documents`, which
is synced.

The one exception is `Tests/ShelfCoreTests/Fixtures/online/`: answers Open
Library and Google Books really gave, fetched once by `make online-proof` and
trimmed by it, so the readers are checked against reality and the tests still
never open a socket. Their provenance — including the one file that is *not* a
live answer, and why — is in that folder's own `README.md`.
