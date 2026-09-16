# Changelog

Newest first. Measured numbers belong here, with the machine they were measured
on and what was *not* measured.

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
  opened is the covers appearing in its cache.
