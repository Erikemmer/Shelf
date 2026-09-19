# Shelf

An eBook manager for the Mac that looks like [Selector](https://github.com/Erikemmer/Selector)
and behaves like a library: covers, metadata, shelves, a Calibre import, and
your readers. **English and German.** macOS 14 or later, Apple silicon or
Intel; Swift 6.

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
* **Your library can leave.** `File ▸ Export Library…` writes it out as an
  ordinary folder of files — with the covers and a `metadata.opf` each, so it
  can be imported back into Shelf, or into Calibre, with nothing lost. A second
  run into the same folder writes only what has changed.

  **The honest sentence about the way back to Calibre:** Shelf writes Calibre's
  own schema, so the title, the authors, the publisher, the date, the language,
  the description, the tags, the identifiers, the series and its index, the
  rating, the sort title and the cover all come across. Two things do **not**:
  the **read status** and the **shelves**. Shelf stores those as
  `<meta name="shelf:read">` and `<meta name="shelf:shelves">`, and Calibre
  ignores a meta it does not know — which is what makes them safe to write
  into a library Calibre also reads, and why they stay behind. Nothing is lost:
  they are there in plain text for anything that cares to look. Use the
  **"For Calibre"** export if you want them to arrive: it writes the same files
  and additionally maps each shelf to a tag (`Shelf/Fiction/Sci-Fi`) and a read
  book to the tag `Read`. That is a mapping, not the real fields, and the
  dialogue says so.
* **DRM is detected and then left alone.** Never removed, never worked around.
* **Nothing from the net is taken over without being ticked.** ⌘E asks Open
  Library and Google Books, shows every field old beside new **with the service
  that said it on each line**, and ticks only what fills a gap. Where the two
  disagree there are two lines and a box each, and neither is ticked. A service
  that does not answer is one line in the status bar, never a dialogue.
* **Only what leaves this Mac is the ISBN or the title being looked up.** No
  identifier of you, your library or your machine; no telemetry; and the only
  network access in the whole build is that one explicit ⌘E.

## Getting it running

Nothing here needs a login. Shelf and its one shared package,
[SlateKit](https://github.com/Erikemmer/SlateKit), are both public, so a clone
and `make bootstrap` is the whole of it.

```bash
make bootstrap     # first time on a Mac: checks Xcode, installs XcodeGen,
                   # runs the tests, generates and builds the project
```

Then press ⌘R in Xcode, or:

```bash
make app           # build the app, Release
make smoke         # start it and check it shows a window and settles
```

Every push runs three jobs — the core's tests on Linux, the core's tests on
macOS, and the app build — and `main` is green on all three.

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
make german-shots  # photograph the window in German (on the command line,
                   # never the Mac's language)
make contrast      # every colour Shelf decides, against WCAG AA
make accessibility # dump the accessibility tree of every view and judge it
make runbook       # run every path in docs/RUNBOOK.md and print what it did
make release-dry   # archive, sign ad hoc, verify, zip — the release path as
                   # far as the step that needs Apple
make release       # the real one: Developer ID, notarytool, stapler, spctl
```

`make help` lists them all. Before every commit: **`make test && make app &&
make lint && make smoke`**, all four green.

## Where things are

| | |
|---|---|
| `Sources/ShelfCore/` | everything that can be decided without a window. Builds and tests on Linux, which is what keeps AppKit out of it. |
| `App/Shelf/` | the window: SwiftUI + AppKit, the cover pipeline, ImageIO. |
| `Sources/ShelfFixtures/` | the test material — `ZipWriter`, `MinimalPNG`, the five `Synthetic…` builders. The tests and `shelf-tool` depend on it; the app does not, so none of it ships. |
| `Sources/shelf-tool/` | the same import and rebuild on the command line, for proof runs. |
| `docs/CONCEPT.md` | what Shelf is, in full. |
| `docs/ARCHITECTURE.md` | the building blocks and the data flows. |
| `docs/DATA-MODEL.md` | the folder layout, the OPF, the index schema. |
| `docs/adr/` | the decisions, and what they cost. |
| `docs/BACKLOG.md` | the sprints, and what is done. |
| `docs/RELEASE.md` | how a build here becomes a file somebody else can open. |
| `docs/RUNBOOK.md` | backup, restore, rebuild, move, the way back to Calibre, and what to do after a crash. Every path run once, with its output quoted. |
| `docs/accessibility/` | the accessibility tree of every view, as `make accessibility` last wrote it. |
| `CHANGELOG.md` | what changed, with the measured numbers. |

## Languages

English and German. Every word the window draws goes through one door and lives
in `App/Shelf/Resources/Localizable.xcstrings` — 441 entries, both languages,
with real plural forms rather than a trailing "s". Numbers, dates and file sizes
are the reader's: *18.09.2026* and *134,5 kB* on a German Mac.

Five tests keep it honest, because none of the three ways of losing a
translation is visible by looking at the app: a missing entry, a missing German
and a sentence that never reached the catalogue all draw perfectly good English
([ADR 0016](docs/adr/0016-the-core-answers-in-english-the-window-translates.md)).

A library's own words are never translated. Your tags, authors, series and
shelves are yours.

The look lives in [SlateKit](https://github.com/Erikemmer/SlateKit), a package
shared with Selector and used through a tag — see
[ADR 0004](docs/adr/0004-slatekit-shared-with-selector.md).

## Without a mouse, and without perfect eyes

Every row of the sidebar is a button a keyboard can reach and activate, every
control has a name, and every hand-drawn control draws a focus ring. The grid's
cells say the whole book in one sentence — title, author, series, formats,
rating, read, DRM, on the device — rather than arriving as four unrelated stops
with a symbol's name among them. The arrow keys are answered by the window
rather than by the menu bar, so holding one costs the move and nothing else
([ADR 0017](docs/adr/0017-the-arrow-keys-leave-the-menu-bar.md)).

None of that is a claim: `make accessibility` drives the app through ten views,
writes each accessibility tree into `docs/accessibility/`, and fails on a
control with no name, on a name that is an SF Symbol's identifier, or on a view
that has stopped holding a button. `make contrast` checks every colour Shelf
decides against WCAG AA.

What a script cannot answer is on the run's own report: whether the order things
are read in makes sense needs an ear.

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
