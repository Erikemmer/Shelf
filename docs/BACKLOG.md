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

### 2a – one field all the way through · done

- [x] `MetadataChange` + `MetadataEditor` in the core: old book and new book in,
      an OPF delta and an index update out, with the file's own unknown metas,
      shelves and identifiers carried across
- [x] Undo/redo through the window's `UndoManager`, registered with the
      *previous value* before anything is written
- [x] Rating from the inspector and from 1–5 / 0; read status from the inspector
      and from R ([ADR 0006](adr/0006-editing-keys-are-not-menu-shortcuts.md))
- [x] `metadata.opf` written atomically on every change; the index follows; the
      book file is never opened for writing
- [x] "Unread" reacts to R at once
- [x] The proof in `Scripts/proof-run.sh`: ten changes, the EPUB's SHA-256
      unchanged, the OPF changed, the index erased and rebuilt finds the same
      rating and read status
- [x] Debouncing — done in 2b, and not as a timer: a field is written when it is
      *finished* (⏎ or focus lost). A timer would still write in the middle of a
      word and would have to be flushed before the window closed

### 2b – all the fields, tags, series, search · done

- [x] Every remaining field in the inspector: title, authors, series and its
      index, publisher, date, language, description, identifiers. The rules for
      each live in the core (`BookField`, `IdentifierEdit`, `TagEdit`, `ISBN`),
      not in a text field
- [x] Debouncing, in the form it turned out to need: **one write per finished
      field** (⏎ or focus lost), not a timer. Escape discards
- [x] Tags as chips with completion, T to focus the field, ⏎ adds, ⌫ removes
      the last, the chip's ✕ removes that one; the sidebar's counts move at once
- [x] Series: the sidebar filters, the grid is in series index order inside a
      series, the inspector says "Book 3 of 7"
- [x] Search over title, author, series, tags, description **and ISBN**
      (CONCEPT §4, Must) — migration 2, refilled from the tables it summarises
- [x] XML safety: the five entities, umlauts, emoji, tabs, Windows line breaks
      and a 20 KB description survive a round trip, the OPF stays well-formed,
      and a title that looks like markup lands as text
- [x] [ADR 0007](adr/0007-a-metadata-change-does-not-rename-the-folder.md) — a
      metadata change does not rename the book's folder
- [x] Proof run section 7: 200 books edited, timings, the book files unchanged,
      the new tag searched for across 5 000 books, the index thrown away and
      every change found again

### 2c – shelves, the table, and acting on many books · done

- [x] Shelves: create, rename in place, nest by dragging, drag books onto them,
      a context menu and an inspector row, removal behind a confirmation that
      names the shelf and the books. Membership in each book's OPF, the shape in
      `library.json`
      ([ADR 0008](adr/0008-shelves-membership-in-the-book-hierarchy-in-library-json.md))
- [x] The table view (⌘2): nine columns plus a hidden tenth, chosen and resized
      from the header's own menu, the layout kept in `library.json`
- [x] Multiple selection (⇧, ⌘, ⌘A) and editing across it as **one** undo step;
      the inspector shows shared values and `Mixed`
- [x] Sorting: six fields, both directions, the sort menu and the table header
      reading the same `BookOrder`, saved per library
- [x] **Duplicates** — the importer's own three rules asked of the whole
      library, with the rule that matched named in the inspector — and
      **Not on any Shelf**, answered from the book itself
- [x] Proof run section 8: twenty shelves in three levels, a thousand books
      distributed, the sidebar's arithmetic checked against SQL, fifty books
      tagged and undone with every file compared, the index thrown away and
      every shelving found again

### What 2c deliberately did not do

- [ ] **Editing publisher, language or date across a selection.** Only rating,
      read status, tags and shelves act on all the selected books; every text
      field is read-only while several are selected. Title, series and
      description should stay that way — a title typed once into twelve books is
      a mistake with twelve copies — but a publisher across a selection is a
      reasonable thing to want
- [ ] **Sorting by Tags, Format, Read or Size.** Those four columns have no
      arrow, because `BookSort` has no case for them and a column that sorted
      only the rows in memory would put the table in one order and leave the
      grid and the sort menu in another. Size needs a `SUM(byte_size)` join;
      the others are straightforward
- [ ] **Reordering shelves among their sisters.** `Shelf.position` exists and is
      honoured; nothing in the window sets it yet, so shelves sit in the order
      they were made
- [x] **Scrolling 5 000 table rows, measured.** Done in Sprint 3:
      `Scripts/table-scroll.sh`, 4 996 rows, no decode and no file I/O on the
      main thread, 282 MB peak. Keyboard-driven — the SwiftUI `Table` does not
      move for a posted scroll-wheel event at all

### Still open, carried from 2b

- [ ] Combining filters with ⌘-click, as Selector's sidebar does
- [ ] Series view proper: missing volumes visible, not only the ones present
- [ ] **"Reorganize Library…"** — the command that *does* rename folders to match
      the metadata, with a preview of every move and a report afterwards
      ([ADR 0007](adr/0007-a-metadata-change-does-not-rename-the-folder.md)).
      Until it exists, a library that has been edited for a while has folder
      names that are historical, which costs nothing but tidiness
- [ ] **Clicking a cover does not take the keyboard back from the search field.**
      Carried, but narrower than it was. Sprint 2c replaced the two competing
      `@FocusState` bindings with one window-wide value, and
      `Scripts/keyboard-proof.sh` now drives the real window: search, click a
      cover, press R, and read the book's status back out of the index. It reads
      **5 of 5** — and **5 of 5 against the build from before the change too**,
      so the symptom Sprint 2b reported could not be reproduced and the change
      cannot be credited with fixing it. What the change did fix, measured 0 of 5
      before and 5 of 5 after, is Escape in the search field: it now empties the
      field as well as handing the keyboard on. There is a script to point at
      this now, which is the real progress
- [ ] **Debouncing the search field**, if it turns out to be wanted. It already
      waits 120 ms after the last keystroke before asking FTS5, and a search
      over 5 000 books measured 0.6 ms, so there is nothing to fix yet — written
      down so the question is not asked twice

### Not a Shelf defect, but it wastes a sprint's evidence

- [ ] **The Mac's screen lock silently breaks every window-driven script.**
      Confirmed with `ioreg` (`CGSSessionScreenIsLocked = Yes`) in the middle of
      the Sprint 2c screenshot run. While the screen is locked:
      `screencapture -l <window id>` keeps working and returns the window's
      *last drawn frame*, so shot after shot is byte-identical; System Events
      reports no windows; and the accessibility tree degenerates to an
      application element containing only itself, so every lookup answers
      "nothing" rather than failing. `Scripts/window-count.swift` reads `5 0 0`.

      This is almost certainly what Sprint 2b recorded as "one launch produced
      an app with no window, not reproducible, no crash report", and what
      happened twice more during 2c. The app is fine: it still creates and shows
      its window, and `make smoke` passes while locked.

      All four scripts have the guard now, and it asks *again* whenever one of
      them is about to blame the app — the version that only asked at the start
      let a run pass the guard and then lose the screen underneath it.
      `caffeinate -di` was not enough on this Mac either; it is `-dimsu`, since
      `-u` is what the screen saver watches

## Sprint 3 – Calibre import · done, except against a real library

- [x] `CalibreReader`: `metadata.db` read **through a copy**, and its
      write-ahead log with it, schema version checked, unknown version a warning
      rather than an abort
      ([ADR 0009](adr/0009-calibre-is-read-through-a-copy-of-metadata-db.md))
- [x] Counting protocol before, in the sheet and as `shelf-tool calibre-dry`:
      books, formats per type, tags, series, authors, custom columns with their
      kinds, files in the DB missing on disk, files on disk missing from the DB,
      total size, free space × 1.05
- [x] Import through the importer that was already there, with resume over
      UUID + hash; `Import-Report.txt`
- [x] Custom columns read-only: values in the book's OPF, definitions in
      `library.json`, both cached in the index, shown in the inspector
      ([ADR 0010](adr/0010-calibre-custom-columns-are-read-only.md))
- [x] `shelf-tool calibre-synthesise`, so the fixtures and the proof run are
      built rather than borrowed
- [x] **Proof run against a synthetic Calibre library of 2 000 books**: counts
      before and after, resume after an abort, 6 001 source files byte for byte
      identical, ten sample digests against `shasum`. Numbers in `CHANGELOG.md`
- [ ] **Proof run against Erik's real Calibre library.** Not done, and not
      because it was forgotten: nothing above has met a library Calibre actually
      wrote. `~/Downloads/Calibre Library Erik` holds a `metadata.db` with no
      book folders, which exercises the schema and not the import. **Erik has to
      name the path.**

### What Sprint 3 found and did not finish

- [ ] **An interrupted import copies up to 200 books twice.** The batch in
      flight when the process is killed was never indexed, so the resumed run
      copies those again — 23 of them in the measured run — and their files sit
      in folders no book points at. Nothing is lost and a rebuild no longer
      trips over them. The batch size is the whole of the window; a smaller one
      narrows it, and flushing on `SIGTERM` would close it
- [ ] **`Missing Cover` counts every book in a freshly imported library**, until
      the cover cache has been warmed: the collection is answered from the cache
      (one directory read, which is what makes it cheap) and a cache nobody has
      filled is empty. It corrects itself as covers are drawn, which is worse
      than being wrong — it is wrong and then quietly right
- [ ] **The inspector's `Mixed` values carry no visible label.** On one book
      those positions are the title, the series and the description; three bare
      `Mixed` in three sizes is not obvious. The accessibility tree *does* name
      them, so this is a visual gap, not an accessibility one
- [ ] **`Published` reads blank across a selection** where its neighbours read
      `Mixed`. Blank says neither "they differ" nor "none of them has one"
- [ ] **`ZipWriter`, `MinimalPNG` and now `SyntheticCalibreLibrary` still live
      in `ShelfCore`.** The move to a `ShelfFixtures` target is **not** the
      drag-and-drop the entry below assumes: `OPFDocument.escaped` is internal
      and `SyntheticEPUB` uses it, so the move is an API decision about what
      `ShelfCore` publishes

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

- [ ] **Move the arrow keys off the menu bar.** Holding → spends 31 % of the
      time in `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` calling
      `usleep` on the main thread and another 27 % highlighting and
      unhighlighting the menu bar, which drags a full window layout behind it.
      Shelf's own work in that sample is 0.3 %. The editing keys already avoid
      it ([ADR 0006](adr/0006-editing-keys-are-not-menu-shortcuts.md)); the
      arrows were left alone because moving them is a separate risk to keyboard
      navigation and wanted its own step.
- [ ] **Sidebar rows have no role a keyboard user can activate.** The
      accessibility tree shows an `AXImage` and two `AXStaticText` per row, no
      `AXButton`, no action. Sprint 7 owns accessibility, but this is the one
      that makes the sidebar unusable rather than merely awkward.

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

- [x] **Does the window look right?** Answered in Sprint 2b, once the Screen
      Recording permission existed. Five shots in `docs/screenshots/sprint-1/`,
      Shelf and Selector at 1440 × 877: the sidebar background, the inspector
      background and the selected sidebar row are identical to the byte
      (`#2B2B2B`, `#2B2B2B`, `#52472F`). The fourth probe point compares nothing
      — it sits in the content area, where Selector has a photograph and Shelf
      has the ground behind a cover grid — and is named as such rather than
      moved somewhere that would agree. Looking at the shots found five defects
      that no test could have; all five are fixed.
- [x] **Is there more than one window?** Settled: **no.** Shelf reports `5 1` –
      five layer-0 windows, one of them on screen – and the accessibility API,
      which counts real windows, reports **one**. Four of the five are
      1512 × 33 at (0, 0), never on screen, and belong to the system's menu bar:
      every app has them. Selector, read while it was running and never touched,
      reports the same four – and with a document window open it reports
      **six**, which is exactly the number Shelf was suspected for. Shelf has one
      fewer than a shipping app that works. Three quit-and-relaunch rounds and
      three kill-and-relaunch rounds stayed at one window; the "six, growing by
      one per launch" of Sprint 1 was restored window state from a saved-state
      folder that no longer exists and did not come back. `window-count.swift`
      and `smoke.sh` say so now.
- [x] Time from opening a 5 000-book library until every *visible* cover is on
      screen, cold and warm (CONCEPT §11 target: warm cache under 2 s).
      Measured with `SHELF_TIMING=1`: **852 ms cold, 768 ms warm**, twelve
      cells, window in the foreground.
- [x] A held arrow key for 10 s with `sample` running. No stall in Shelf's own
      code — and 58 % of the run inside AppKit's menu key-equivalent machinery
      ([ADR 0006](adr/0006-editing-keys-are-not-menu-shortcuts.md)).
- [x] Peak memory with the window in the foreground: **301 MB cold, 206 MB
      warm, 218 MB while the arrow key was held**, against the 1.5 GB the
      concept allows. The Sprint 1 figure of 312 MB was taken with the window
      occluded; it turns out to have been about right.
- [ ] Whether trackpad scrolling stays smooth while the cover cache is filling.
      Still open, and now known to need a hand: a posted scroll-wheel event does
      not reach the table at all, so no script can answer it.
      Warming no longer pauses for scrolling (ADR 0005, decision 6), which is
      the one deliberate regression against Selector's behaviour.

`Scripts/proof-run.sh` measures everything that does *not* need the window.
