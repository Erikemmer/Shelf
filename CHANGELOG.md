# Changelog

Newest first. Measured numbers belong here, with the machine they were measured
on and what was *not* measured.

## Sprint 2a – Editing, one field all the way through · 17 September 2026

Undo first, then one field through every layer: the rating, and with it the read
status. `metadata.opf` is written on every change and the index follows; no book
file is opened for writing anywhere in the chain.

### Added

- **`MetadataChange` and `MetadataEditor` in `ShelfCore`.** A change is the pair
  it really is — the book before and the book after — because undo needs the
  *previous value* and the file cannot be asked for it once it has been written.
  `fields` is what actually differs, which is both the guard against writing a
  file for nothing and the name in the Edit menu ("Undo Rating").
  `MetadataEditor` lays the delta over **what the file already says**, not over
  what the index believes, and writes the OPF atomically before touching the
  index: the folder is the truth, the index is the cache (ADR 0001).
- **The rating is editable** from the inspector's stars and from 1–5, with 0 and
  a second click on the current rating to clear it. **The read status** from a
  checkbox and from R. Both with ⌘Z / ⇧⌘Z through the window's `UndoManager`.
  "Unread" in the sidebar reacts the moment R is pressed.
- **`Book.stars`**, the one place Shelf's five stars and Calibre's ten meet.
  `calibre:rating` keeps the ten-point value so a library that goes back to
  Calibre does not lose half stars somebody set there.
- **`shelf-tool edit` and `shelf-tool show`**: the same core from the command
  line, which is what lets `Scripts/proof-run.sh` prove the edit without a
  window.
- **[ADR 0006](docs/adr/0006-editing-keys-are-not-menu-shortcuts.md)** – editing
  keys are handled in the grid, not by the menu bar, with the measurement that
  decided it.

### Fixed

1. **`dcterms:modified` was read and never written.** Since the first version.
   Every rebuild therefore dated every book to the moment of the rebuild. The
   round-trip test now walks every field of `MetadataChange.Field` rather than
   the four somebody thought of, and it fails without the fix.
2. **The index never read identifiers back.** `LibraryEntry.book.identifiers`
   was always empty, which cost twice: the inspector has a row per identifier
   and never drew one, and re-saving an entry that came from the index deletes
   the identifier rows and would have written none back — taking the ISBN off
   every edited book and the duplicate check with it. Proved by a test that
   fails without the fix (`bookIDs(isbn:)` returns nothing after a re-save).
3. **The inspector handed `rating` to a five-star control unconverted**, so
   anything Calibre rated 5 or more drew five full stars.
4. **The status bar and the sidebar wrote the same number two ways** — "4996
   books" under "4.996". Found by reading the accessibility tree, which is the
   only way anybody was going to notice two formats a few pixels apart.
5. **`make proof` and `make synthetic-clean` could not run at all.** Neither
   script had its executable bit, and both targets call the script directly.
   `make proof` has been broken since Sprint 1; it went unnoticed because the
   script was always run as `bash Scripts/proof-run.sh` while it was written.

### Measured

MacBook Pro, Apple silicon, macOS 26.6.2, Release build, five-book synthetic
library, `SHELF_TIMING=1`.

| | |
|---|---|
| key press → written `metadata.opf`, rating | **8 ms** |
| key press → written `metadata.opf`, read status | **5 ms** |
| target in the sprint brief | 50 ms |

The evidence is in `docs/screenshots/sprint-2a/`:

- `opf-diff.txt` — `git diff --no-index` of one book's `metadata.opf` before and
  after pressing 4 and R. **Three lines change**: `calibre:rating` 8 arrives,
  `shelf:read` flips, `dcterms:modified` follows. The title, the author, the
  identifier, the subjects and the timestamp are byte-for-byte what they were.
  The EPUB's SHA-256 is identical before and after.
  ⌘Z twice put the file back **byte-identical**, modification date included.
- `ax-tree.txt` — the star control publishes `valueDescription="3 of 5"` while
  the OPF says `calibre:rating` 6, and the read status is now an `AXCheckBox`
  where Sprint 1 had a static "Read: No".

`Scripts/proof-run.sh` gained the Sprint 2 form of "the folder is the truth",
run against a 20-book library:

```
══ ten metadata changes, and what they did and did not touch
  epub before: 3768cd9a3df77b0d6fa714110611f371e11d74b99d42250bf5c961aa447e103c
  epub after:  3768cd9a3df77b0d6fa714110611f371e11d74b99d42250bf5c961aa447e103c
  the book file is untouched after ten metadata changes ✓
  metadata.opf changed, as it must ✓
══ throwing the index away and asking the folders again
  the rebuilt index found the same rating and read status ✓
```

**264 core tests**, 14 of them new. Two of the new ones were checked by removing
the fix and watching them fail.

### Not verified

- **Nobody has still seen the window.** `screencapture` needs Screen Recording
  permission for the terminal that runs it and this terminal has none, so the
  four screenshots and the pixel-for-pixel comparison with Selector could not be
  taken. `Scripts/screenshots.sh` does the whole job the moment the permission
  exists; `docs/BACKLOG.md` says which settings pane grants it. What could be
  read instead is the accessibility tree, and it found two of the four defects
  above.
- **Debouncing is not implemented.** At 5–8 ms a write it earns nothing for a
  rating; it becomes necessary in 2b, where a text field would otherwise write a
  file per keystroke. Written down rather than quietly skipped.
- The edit path was exercised by hand against libraries of five and twenty
  books, and by tests. It has **not** been exercised against the 5 000-book
  library, so nothing is known about what an edit costs when the grid is full.

## Sprint 1 follow-up – the measurements that needed a window · 17 September 2026

Everything `docs/BACKLOG.md` listed under "Measurements still to take by hand",
except the screenshots.

### The window question, settled

`Scripts/window-count.swift` reported **six** layer-0 windows in Sprint 1 and
nobody knew whether that was a SwiftUI artefact or a real extra window. It is
neither, quite:

| | layer-0 windows | windows the accessibility API reports |
|---|---|---|
| Shelf, library open | 5 (one on screen) | **1** |
| Selector, running, read and not touched | 5 (none on screen) | 0 — it had none open |

Four of those five are **1512 × 33 at (0, 0)** and never on screen, and Selector
reports exactly the same four: they are the system's menu bar, not the app's.
Three quit-and-relaunch rounds and three kill-and-relaunch rounds stayed at one
window; the "six, growing by one per launch" was restored window state from a
saved-state folder that no longer exists and did not come back. The script and
the smoke test say so now, so the next reader does not have to find it again.

### The numbers, with the window in the foreground

5 000 synthetic books, 4 996 in the index, Release build, `SHELF_TIMING=1`.
The Sprint 1 figures were taken with the window **occluded** by another app and
are kept below for comparison.

| | this run (foreground) | Sprint 1 (occluded) |
|---|---|---|
| index read, 4 996 books | 488 ms cold · 353 ms warm | not measured |
| **every visible cover on screen** (12 cells) | **852 ms cold · 768 ms warm** | not measured — "the process settles", 3–6 s |
| against CONCEPT §11's target | 2 s, warm | — |
| peak memory, cold open | **301 MB** | 312 MB |
| peak memory, warm open | **206 MB** | — |
| peak memory, arrow key held | **218 MB** | — |
| against CONCEPT §11's limit | 1.5 GB | 1.5 GB |
| cover cache | 4 901 covers, 96 MB | 4 901 covers, 96 MB |

"Every visible cover on screen" is what `TimingLog` measures and what nothing
before it could: it counts the cells the grid has actually laid out and stops
when the last of them has its cover, 250 ms after the pending set empties so
that a grid which lays out over several frames is not reported one row early.
It is silent unless `SHELF_TIMING=1` is set.

### A held arrow key for ten seconds

`sample` over 626 right-arrow presses. The main thread was busy 89 % of the
time, and almost none of it was Shelf's:

| where the main thread was | share of the run |
|---|---|
| `-[NSMenu performKeyEquivalent:]`, all of it | 83 % |
| of which `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` → `usleep` | **31 %** |
| of which `_NSHighlightMenu` → unhighlight → CA commit → window layout | **27 %** |
| `LibraryModel.move(by:)`, the actual work | 0.3 % |

**No image decoding and no file I/O on the main thread**, which is what the
sample was taken to check. What it found instead is that AppKit throttles a
repeated menu-item invocation by sleeping on the main thread and flashes the
menu title on every one. That decided where Sprint 2a's editing keys go
(ADR 0006) and put the arrow keys in the backlog.

macOS's own `key down` produces no auto-repeat — the first attempt measured a
perfectly idle app for ten seconds — so the repeat had to be generated as 626
separate presses.

### Also

- `grep -ri lithothek` is empty. CONCEPT's appendix A is gone: it listed
  Selector's occurrences and belongs in Selector, where it is done.
- CONCEPT catches up with two accepted deviations: the cover cache writes JPEG
  (§13) and warming does not pause for trackpad scrolling until the deployment
  target reaches macOS 15 (§10). §15's first open point is decided.
- **CI: nothing to do.** `gh secret list -R Erikemmer/Shelf` is empty and
  `Erikemmer/SlateKit` is still `PRIVATE`, so neither route to building the app
  in CI is open and nothing was changed. The choice is still Erik's and
  `docs/HANDOFF.md` sets out both.

## Sprint 1 – Scaffolding and EPUB · 17 September 2026

The first working Shelf: it creates and opens a library, reads EPUBs, imports
them with verified copies into `Author/Title (n)/`, indexes them in SQLite with
full-text search, and shows them in a three-column window with a disk-backed
cover pipeline. Read-only inspector; editing is Sprint 2.

### Added

- **Repo and build**: `Package.swift` (ShelfCore + `shelf-tool` + tests, GRDB
  7.11.1), `project.yml` (XcodeGen, `de.erikemmer.shelf`, SlateKit pinned to
  `0.1.0`), `Makefile` with `test` / `app` / `lint` / `smoke` and
  `SCRATCH = ~/Library/Caches/Shelf/build`, CI for the core on Linux *and* core
  plus app on macOS.
- **`ShelfCore`**, UI-free and Linux-buildable: the model (`Book`, `SeriesRef`,
  `BookFormat`, `Shelf`/`ShelfTree`, `SmartCollection`/`LibraryFilter`,
  `BookFolderName`, `TitleSort`/`AuthorSort`, `ShortcutReference`); `Library` +
  `LibraryDescriptor`; `LibraryIndex` over GRDB with the schema from CONCEPT
  §5.2, FTS5, facets and duplicate lookups; `IndexRebuilder`; `ZipReader` and a
  plain-Swift `Inflate`; `XMLTree`, `OPFDocument` (read and write, atomic),
  `EPUBMetadata`, `FileNameMetadata`, `CoverFile`; `ImportPlanner` →
  `ImportRunner` → `ImportReport`; the loading rules copied from Selector
  (`LoadPriority`, `DecodeGate`, `WarmOrder`, `InteractionWindow`,
  `CoverCacheKey`/`Policy`); `PortableSHA256Hasher`.
- **The window**: welcome screen, three columns, sidebar with every section
  visible (empty ones say why), cover grid with a size slider and search,
  read-only inspector, import sheet with the counting protocol before anything
  is copied, and `Library ▸ Rebuild Index from Folders`.
- **The cover pipeline with its disk cache from the start** (not retrofitted, as
  Selector had to): `CoverLoader`, `CoverDiskCache` in `.shelf/covers/`,
  `CoverWarmer` in rings around the selection.
- **`shelf-tool`**: `synthesise`, `import`, `rebuild`, `digest` – the same core
  from the command line, so the numbers below were measured without a window.
- **Docs**: `docs/ARCHITECTURE.md`, `docs/DATA-MODEL.md`, `docs/BACKLOG.md`,
  `docs/HANDOFF.md`, `README.md`, and ADRs 0001–0005.
- **245 core tests**, all of them on synthetic fixtures the tests build
  themselves. No borrowed book is in this repository.

### Measured

MacBook Pro, Apple silicon, macOS 26.0, Swift 6.4, Release builds.
`make synthetic` writes 5 000 EPUBs with real PNG covers; `make proof` does the
rest. Source and library live under `~/Library/Caches/Shelf/`.

| | |
|---|---|
| synthetic library | 5 000 EPUBs, 643.6 MB, written in **20 s** |
| files on disk | 4 999 (two long titles truncate to the same name, see below) |
| import: read, plan, copy, verify, index | **28.1 s** for 4 999 files |
| of which | metadata + cover + SHA-256 of every file, then a verified copy and a read-back hash of each |
| books in the index afterwards | **4 996** — 3 skipped as duplicates by ISBN, which is exactly the number the generator plants |
| library on disk | 1.3 GB (the cover is kept both inside the copied EPUB and extracted beside it) |
| digests vs `/usr/bin/shasum` | 3 of 3 match, on the copies |
| source folder afterwards | **0 files modified**, 4 999 files still there |
| erase the index and rebuild from the folders | **12 s**, 4 996 books before and after, 0 unreadable folders, 0 books without an OPF |
| cover cache, cold | **4 901 covers in under 10 s** (~500/s), CPU peaking at 168 % across cores |
| cover cache on disk | **96 MB** for 4 901 covers at 400 px |
| warm open of the same library | CPU at 0 % from **6 s**, no new cover written |
| memory | 76–312 MB throughout, against the 1.5 GB the concept allows |

The 4 901 covers are all there are: the generator leaves every fiftieth book
without one, which is what the "Missing Cover" collection is for.

### Three defects the measurements found

Each of these was a real bug, none would have been found by a unit test, and
each is now either tested or written down.

1. **The `.part` name blew the 255-byte path limit.** The temporary file was the
   destination's name with `.shelf-import-` in front, and a book file may
   already use all 255 bytes a path component is allowed. One import in twenty
   failed — the long titles only. Found by the synthetic library's deliberately
   absurd every-hundredth title. The temporary name is short and random now, and
   there is a test for it. (ADR 0002)
2. **The cover cache wrote HEIC.** Copied from Selector, where it is right.
   Measured here: **38.4 ms** to encode a 400 px cover as HEIC against
   **1.05 ms** as JPEG, for 8.2 KB against 19.9 KB — HEIC goes through the
   hardware video encoder and sets up an HEVC session per image. Over 5 000
   books that is 58 MB of disk against three minutes of encoding. Shelf writes
   JPEG. (ADR 0005)
3. **Warming starved itself twice over.** The cache-write task ran at
   `.background` QoS, which the system throttles hard, while holding one of the
   decode gate's two background slots — the exact mistake `LoadPriority`'s own
   comment warns about, made one line away from the warning. And cell appearance
   was used as the "user is scrolling" signal, which closed a loop through the
   progress display: warm → progress → view invalidated → cell appears →
   "interaction" → warming pauses. Together: 3.5 covers per second instead of
   500. (ADR 0005)

Two smaller ones came out of writing the tests: `XMLTree.descendants` returned
elements in reverse document order, which would have scrambled author order and
therefore the folder a book lives in; and the shelf list was joined with
`U+001F`, which is **not legal in XML 1.0** and made the parser refuse the whole
OPF. Both are tested now.

### Three more, from real books and from CI

Seventeen real EPUBs were copied out of `~/Downloads` into a throw-away library
(the originals only read, the copies deleted afterwards). Sixteen read
correctly — titles, authors, subtitles and covers. The three findings:

4. **An author name that already had a comma was sorted again.** Shop EPUBs
   write `dc:creator` both ways, and `AuthorSort.of("McFadden, Freida")` gave
   `"Freida, McFadden,"` — a second author folder for the same person, in a
   library where thirteen of seventeen books were hers. A name with a comma is
   already in sort form and is now left alone, with a test.
5. **Symlinked books imported with the wrong size.**
   `FileManager.attributesOfItem(atPath:)` does *not* follow a symlink while
   `FileHandle` does, so a linked book arrived with the right content and a size
   of about eighty bytes. `FileFacts` now resolves the link first, in one place
   the importer and the command-line tool share.
6. **CI caught three portability faults on its first two runs**, which is
   exactly what it is for. `autoreleasepool` does not exist in
   swift-corelibs-foundation (there is a `withAutoreleasePool` shim now). One
   expression in `MinimalPNG` exceeded the type checker's budget on **Swift
   6.1** — which CI uses on both Linux *and* macOS — while the 6.4 toolchain on
   this Mac compiled it happily. And `FileManager.replaceItemAt` is not
   implemented on Linux either, so every *second* write of a `metadata.opf`
   failed there: the first write took the `moveItem` path and worked, which is
   why only two tests noticed. `Data.write(options: .atomic)` is the
   write-to-temp-and-`rename(2)` that CONCEPT §5.1 asks for, does it portably,
   and is less code than doing it by hand. **A local green build is not a green
   build.**

The seventeenth real book, *Greenlights*, has no readable metadata: the file is
not a valid ZIP at all, and `unzip` refuses it too. Shelf imported it anyway,
named from its file, and said so in the report — which is what the fallback
chain is designed to do, working on a real broken file rather than a contrived one.

### Not verified

Everything that needs somebody looking at the screen. In full in
`docs/BACKLOG.md` under "Measurements still to take by hand"; the short list:

- **Nobody has seen the window.** It builds, runs, opens a 5 000-book library
  and fills its cover cache, but every judgement about how it *looks* is open.
- **`Scripts/window-count.swift` reports six layer-0 windows** for one process
  with, as far as can be told, one visible window. The count is *stable* at six
  across launches — it appeared to grow by one per launch, but that only
  happened while the app was being rebuilt between launches, and from a clean
  container it is six every time. Six backing windows for one SwiftUI
  `WindowGroup` scene is plausible on this macOS, but it has not been
  established: the comparison against Selector that would settle it in a minute
  was not run, because Selector was already running and this session does not
  end processes it did not start. The smoke test asserts only "at least one".
- The memory and timing figures were taken with the window **occluded** by
  another app, so macOS was throttling the process. They are therefore
  pessimistic for throughput and possibly optimistic for memory.
- "Time until every visible cover is on screen" was **not** measured; what was
  measured is when the process settles and how fast the cache fills.
- `make smoke` no longer needs permission to automate System Events, because a
  library can be handed to the app on the command line — but that also means the
  front window's *title* cannot be read, so the evidence that a library really
  opened is its appearance in the app's recent list and the covers in its cache.
- **CI does not build the app.** SlateKit is a private repository and GitHub
  Actions has no credentials for it, so that job skips with a warning; the core
  is verified on Linux and macOS and gates every push. Either add a
  `SLATEKIT_TOKEN` secret or make SlateKit public — the choice is Erik's, and
  `docs/HANDOFF.md` sets out both. Until then the app is built by `make app`
  here, not by CI.
