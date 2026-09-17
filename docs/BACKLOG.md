# Backlog

The sprints from CONCEPT §11, with what is actually done marked. A sprint is
done when its features work, its tests are green, its numbers are in
`CHANGELOG.md`, and the four checks pass.

## Sprint 0 – SlateKit · done (in Selector)

Selector's look moved into its own package, `~/Documents/SlateKit`, tagged
`0.1.0`. Proved by photographing six screens before and after: zero differing
pixels. See SlateKit's README and [ADR 0004](adr/0004-slatekit-shared-with-selector.md).

## Sprint 1 – Scaffolding and EPUB · done

- [x] Repo, `Package.swift`, `project.yml`, `Makefile`, `.swift-format`,
      `.gitignore`, CI (core on Linux **and** core + app on macOS)
- [x] `Scripts/`: `smoke.sh`, `window-count.swift`, `proof-run.sh`,
      `synthetic-clean.sh`
- [x] `Library` + `LibraryDescriptor`: create, open, refuse a newer schema, warn
      about a synced folder
- [x] Model: `Book`, `SeriesRef`, `BookFormat`, `BookFileFormat`, `Shelf` /
      `ShelfTree`, `SmartCollection` / `LibraryFilter`, `BookFolderName`,
      `TitleSort` / `AuthorSort`, `ShortcutReference`
- [x] `LibraryIndex` with GRDB: the schema from CONCEPT §5.2, FTS5, facets,
      totals, duplicate lookups, versioned migrations
- [x] `IndexRebuilder`: folders → index, with digest reuse
- [x] `ZipReader` + `Inflate` (plain Swift, checked against zlib's own output)
- [x] `XMLTree`, `OPFDocument` (read **and** write, atomic through `.part`),
      `EPUBMetadata`, `FileNameMetadata`, `CoverFile`
- [x] `ImportPlanner` (three duplicate tests) → `ImportRunner` (copy, verify,
      then trust) → `ImportReport`
- [x] App: welcome screen, three columns, sidebar with all sections visible,
      cover grid, read-only inspector, import sheet with the counting protocol
- [x] Cover pipeline with the disk cache **from the start**: `CoverLoader`,
      `CoverDiskCache` in `.shelf/covers/`, `CoverWarmer` in rings,
      `DecodeGate`, `InteractionWindow`
- [x] Docs: ARCHITECTURE, DATA-MODEL, this file, HANDOFF, CHANGELOG, ADRs 1–4
- [x] Proof run against 5 000 synthetic books; numbers in `CHANGELOG.md`

## Sprint 2 – Metadata editing

The inspector becomes editable. Everything is laid out for it already; this is a
change of controls, not of layout.

- [ ] Editable fields in the inspector with **undo/redo** through the window's
      `UndoManager`, as Selector does for reviews
- [ ] Rating (1–5, 0), read/unread (R), tags (T) from the keyboard
- [ ] Writing `metadata.opf` on every change, debounced, atomic; the index
      follows
- [ ] Shelves: create, rename, drag books onto them, hierarchy in the sidebar,
      mirrored into the OPFs and `library.json`
- [ ] Series view: the books of a series in index order, missing volumes visible
- [ ] The table view (⌘2): sortable, choosable columns
- [ ] The two smart collections Sprint 1 left disabled: **Duplicates** (needs a
      query over `isbn_normalised` and the folded title key) and **Not on any
      Shelf**
- [ ] Combining filters with ⌘-click, as Selector's sidebar does
- [ ] Multiple selection in the grid, and acting on it

## Sprint 3 – Calibre import

- [ ] `CalibreReader`: `metadata.db` read-only **through a copy** in
      `~/Library/Caches/Shelf/`, schema version checked, unknown version a
      warning rather than an abort
- [ ] Counting protocol before: books, formats per type, tags, series, authors,
      custom columns with their types, files in the DB missing on disk, files on
      disk missing from the DB, total size, free space × 1.05
- [ ] Import runner with resume over UUID + hash; `Import-Report.txt`
- [ ] Custom columns read-only: `custom_columns` / `custom_values` are already
      in the schema
- [ ] **Proof run against Erik's real Calibre library**: counts before/after,
      sample hashes, and `find -newer` showing the Calibre folder untouched

## Sprint 4 – The other formats

- [ ] MOBI/AZW3: PalmDB + EXTH (100 author, 503 title, 104 ISBN, 106 date,
      201 cover offset) in `ShelfCore/Formats/Mobi`
- [ ] PDF: PDFKit `documentAttributes`, page 1 rendered — app layer, PDFKit is
      not Linux-capable
- [ ] CBZ: file name by regex, optional `ComicInfo.xml`, first image as cover
- [ ] CBR: libarchive in the app layer, RAR5 checked at runtime, file-name
      fallback ([ADR 0003](adr/0003-zip-in-the-core.md))
- [ ] Kindle DRM detection (EXTH 209); KFX listed by name and size only
- [ ] `BookFileFormat.hasReadableMetadata` becomes true for these — it is the
      one place that changes
- [ ] Quick Look (␣)

## Sprint 5 – Devices

- [ ] Detection through `NSWorkspace` volume notifications and marker paths;
      profiles as JSON data in `ShelfCore/Devices/Profiles/`
- [ ] Transfer with SHA-256 and read-back, format preference per device,
      "cannot be sent: no compatible format"
- [ ] What is on the device, listed; Kobo reading progress and shelves read
      (read-only, through a copy of `KoboReader.sqlite`)
- [ ] Deleting on the device only behind a confirmation that **names every file**
- [ ] Eject, only when no transfer is running
- [ ] Proof run with every device Erik owns

## Sprint 6 – Online metadata

- [ ] Open Library and Google Books, no API key, by ISBN then title + author
- [ ] Candidate list, then field-by-field old/new with a checkbox each
- [ ] Cover fetched from the net when the file has none
- [ ] Network errors are quiet: a line in the status bar, never modal

## Sprint 7 – Polish and release

- [ ] German localisation
- [ ] Accessibility: keyboard, contrast, labels
- [ ] Signing, notarisation, direct download, runbook → **v1.0**

## Housekeeping, when it is next convenient

- [ ] **`ZipWriter` and `MinimalPNG` belong in their own target, `ShelfFixtures`.**
      They exist so the tests and `shelf-tool synthesise` can *build* test
      material; nothing the app does needs to write a ZIP or encode a PNG. In
      `ShelfCore` they are 385 lines of production surface that production never
      calls, and every one of them is code the Linux CI job has to keep
      compiling. A separate target that the tests and `shelf-tool` depend on –
      and the app does not – says what they are for. It is a move, not a
      rewrite: no caller outside the tests and the tool changes.

## Wishes, after v1.0

Conversion through an installed Calibre's `ebook-convert`; an integrated reader;
Send-to-Kindle by e-mail; writing reading progress to a device; rule-based
shelves; iPad.

## Measurements still to take by hand

These need the window open and a person watching, so they are listed here rather
than claimed:

- [ ] **Does the window look right?** Nobody has seen it. The grid, the sidebar
      sections, the inspector and the import sheet were written against
      SlateKit's components and they compile and run, but every judgement about
      spacing, wrapping and whether it actually resembles Selector needs eyes.
- [x] **Is there more than one window?** Settled: **no.** Shelf reports
      `5 1` – five layer-0 windows, one of them on screen – and the
      accessibility API, which counts real windows, reports **one**. Selector,
      read while it was running and never touched, reports **five** layer-0
      windows too: four of them are 1512 × 33 at (0, 0), exactly the four Shelf
      also has, and they belong to the system's menu bar rather than to either
      app. Three quit-and-relaunch rounds and three kill-and-relaunch rounds
      stayed at one window; the "six, growing by one per launch" of Sprint 1 was
      restored window state from a saved-state folder that no longer exists and
      did not come back. `window-count.swift` and `smoke.sh` say so now.
- [ ] Time from opening a 5 000-book library until every *visible* cover is on
      screen, cold and warm (CONCEPT §11 target: warm cache under 2 s). What was
      measured instead is when the process settles (≈3–6 s cold, CPU at 0 % from
      6 s warm) and how fast the cache fills — not the same thing as "the covers
      I can see are there".
- [ ] A held arrow key for 10 s with `sample` running, looking for stalls.
- [ ] Peak memory with the window in the foreground. The measured 312 MB peak
      was taken with the window **occluded** by another app's window, which
      means macOS was throttling the process; the real figure may be higher,
      though it has a long way to go to reach 1.5 GB.
- [ ] Whether trackpad scrolling stays smooth while the cover cache is filling.
      Warming no longer pauses for scrolling (ADR 0005, decision 6), which is
      the one deliberate regression against Selector's behaviour.

`Scripts/proof-run.sh` measures everything that does *not* need the window.
