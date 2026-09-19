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
- [x] **The inspector's `Mixed` values carry no visible label.** Fixed in
      Sprint 6: the title block is drawn only for one book, where the type size
      is the label. A selection of several shows Title, Authors and Series as
      named rows in *Details* instead
- [ ] **`Published` reads blank across a selection** where its neighbours read
      `Mixed`. Blank says neither "they differ" nor "none of them has one".
      Still open: `BookField.sharedText` returns the shared empty string, which
      is *correct* and unreadable. The row needs to tell "none of them has one"
      from "they differ", which is a change to the field rule and not to the view
- [ ] **`ZipWriter`, `MinimalPNG` and now `SyntheticCalibreLibrary` still live
      in `ShelfCore`.** The move to a `ShelfFixtures` target is **not** the
      drag-and-drop the entry below assumes: `OPFDocument.escaped` is internal
      and `SyntheticEPUB` uses it, so the move is an API decision about what
      `ShelfCore` publishes

## Sprint 4 – The other formats

- [x] The app icon: Erik's package in `docs/icon/`, its macOS variant the app's
      `AppIcon` asset, all ten sizes checked with `sips`, `iconutil` as the
      cross-check
- [x] A killed import no longer doubles its own books: the resume adopts the
      folders it left (`OrphanedFolders`), and what nothing can claim is
      reported — `Library ▸ Find Orphaned Folders…`, two steps, every file
      named, and the Trash rather than a delete
- [x] MOBI/AZW3: PalmDB + EXTH (100 author, 503 title, 104 ISBN, 106 date,
      201 cover offset) in `ShelfCore/Formats/Mobi`
      ([ADR 0011](adr/0011-mobi-with-an-own-parser-kfx-as-a-file-only.md))
- [x] PDF: PDFKit `documentAttributes`, page 1 rendered — app layer, PDFKit is
      not Linux-capable
- [x] CBZ: file name by regex, optional `ComicInfo.xml`, first image as cover
- [x] CBR: libarchive in the app layer, RAR5 checked at runtime, file-name
      fallback ([ADR 0003](adr/0003-zip-in-the-core.md)). **No genuine RAR has
      been read** — nothing on this Mac can write one
- [x] Kindle DRM detection (EXTH 209); Adobe ADEPT and encrypted PDFs too; KFX
      listed by name and size only
      ([ADR 0012](adr/0012-drm-is-recognised-and-nothing-else.md))
- [x] `BookFileFormat.hasReadableMetadata` becomes true for these — it is the
      one place that changes
- [x] Several files on one book: a row per file in the inspector with its size
      and Show in Finder, `Add Format…` through the same planner
- [x] Quick Look (␣): the file itself for a PDF, the extracted cover otherwise
- [ ] **Open, for Erik:** a real MOBI, a real AZW3, a real CBR and a genuinely
      DRM-protected file to try the readers against. Everything above is
      measured against synthetic material only

## Sprint 5 – Devices · done, against disk images

- [x] Detection through `NSWorkspace` volume notifications and marker paths;
      profiles as JSON data in `ShelfCore/Devices/Profiles/`
      ([ADR 0013](adr/0013-device-profiles-are-data-not-code.md))
- [x] Transfer with SHA-256 and read-back, format preference per device,
      "cannot be sent: no compatible format"
- [x] What is on the device, listed; Kobo reading progress and shelves read
      (read-only, through a copy of `KoboReader.sqlite`)
- [x] Deleting on the device only behind a confirmation that **names every file**
      ([ADR 0014](adr/0014-deleting-on-a-device-needs-a-named-confirmation.md))
- [x] Eject, only when no transfer is running
- [x] Proof run — `Scripts/proof-run.sh` section 11, against four disk images
      made by `Scripts/device-images.sh`
- [ ] Proof run with every device Erik owns → see below

### To check on real hardware

**Nothing in Sprint 5 was measured against a real e-reader.** The four devices
are `hdiutil` disk images, which is enough for every *rule* — markers, format
choice, file names, verification, resume, the 4 GB limit, the Kobo reader — and
is not enough for the list below. Each line says what would be learned and what
is currently assumed.

- [ ] **A real device, plugged in, detected by its marker alone.** This is the
      first one because the sandbox makes it genuinely uncertain.
      `com.apple.security.files.removable-volumes.read-write` is in the
      entitlements, and with it the app could read a mounted disk image's *name
      and free space* and could **not** list its directory — a card holding five
      books showed "0 books". Real removable media is exactly what that
      entitlement is for, so it is expected to work; it is not proven, and if it
      does not, auto-detection is decorative and every device has to be chosen
      through `Device ▸ Treat Volume as Device…`. **Check first, with a Kobo or
      a Kindle on a cable.**
- [ ] **The `NSWorkspace` mount notification.** The proof run lists `/Volumes`;
      the app subscribes to `didMount`/`didUnmount`. Those are different code
      paths and only the first is measured. A reader plugged in while the window
      is open should appear in the sidebar within a second.
- [ ] **A cable pulled out mid-transfer.** The nearest measured thing is a
      process killed mid-run, which stops *between* files. A cable pulled during
      a write is a partial file plus a volume that has gone: `copyAndVerify`
      should fail its digest check, the `.part` should be swept up — and the
      sweep itself runs on a volume that is no longer there, which is the part
      no test has exercised.
- [ ] **A resumed transfer reports as failures the files it wrote itself.**
      Measured on 19 September 2026 by `Scripts/runbook-proof.sh`, which is
      where the numbers in [docs/RUNBOOK.md](RUNBOOK.md) §9 come from: a
      transfer of 20 books killed after one second left **9 files on the card
      and 0 of them in the manifest**, and the same transfer run again reported
      `Verified · 11 books · Skipped: 0 · Failed: 9`, one line each saying "a
      file of that name is already on the device".

      Nothing is lost — all 20 are on the card afterwards, the `.part` was swept
      up, and `Device ▸ Show What Is on the Device…` finds the nine by name. But
      "Failed: 9" is the wrong word for "I had already done that", and the
      manifest stays behind by nine for the life of the card. The planner skips
      a book whose digest is in the manifest; it should also recognise a file it
      would have written, by name **and** digest, and skip it as
      `alreadyOnDevice` rather than letting the copy fail on
      `destinationExists`. That is a change to `TransferPlanner`, not to the
      runner, and it wants a test that kills a transfer and resumes it.
- [ ] **A real `KoboReader.sqlite`.** `SyntheticKoboDatabase` writes the tables
      and columns Shelf reads; a real one has about a hundred more columns, a
      real WAL, and firmware differences in `___PercentRead` and `ReadStatus`.
      Wanted: that the reading positions come back, that the shelves come back,
      and that the file's digest is unchanged afterwards — the last one being
      the claim that matters.
- [ ] **A Kobo's `.kobo/` folder at full size.** It holds tens of thousands of
      files. The listing skips hidden folders, so it should cost nothing;
      measured only against a folder with one file in it.
- [ ] **A device that is nearly full, for real.** Measured with ballast on a
      40 MB image, because `hdiutil` refuses to make a FAT32 volume smaller than
      about 40 MB on this Mac.
- [ ] **A KEPUB on a Kobo.** The profile prefers KEPUB over EPUB and nothing has
      ever produced one: no fixture writes a `.kepub.epub`, so the preference is
      tested and the *file* is not.
- [ ] **exFAT.** Three images are FAT32 and one is HFS+. Newer readers are
      exFAT, which has no 4 GB limit — so a book over 4 GB should be refused on
      one and sent on the other, and only the refusal has been seen.
- [ ] **A book over 4 GB.** The limit is checked against a fabricated byte size.
      No file that big exists in any fixture here, and making one would put 4 GB
      of zeroes in the cache folder.

## Sprint 6 – Online metadata

- [x] **Duplicates split into what is certain and what is only likely.** Two
      collections, two counts, disjoint; `shelf-tool duplicates` prints both.
      Measured: 413 books, 0 certain, 396 suspicions
- [x] **The inspector names what is `Mixed`** across a selection, and `Added`
      and `Size` stop reporting the anchor book's values as the selection's
- [x] Open Library and Google Books, no API key, by ISBN then title + author.
      Open Library through `/search.json` for both questions: `/api/books`
      answered 404 to every ISBN tried ([ADR 0015](adr/0015-online-metadata-two-sources-field-by-field.md))
- [x] Candidate list with a match score, then field-by-field old/new with a
      checkbox each. Ticked only where it fills a gap — and not even then from a
      work-level record
- [x] Cover fetched from the net when the file has none, on its own button
- [x] Network errors are quiet: one line in the sidebar's footer, never modal.
      Photographed against a host that cannot resolve
- [x] Proof run against both services with ten ISBNs; its answers are the test
      fixtures. Numbers in `CHANGELOG.md`
- [x] Screenshots in `docs/screenshots/sprint-6/`, each looked at and judged
- [x] `Scripts/online-apply-proof.sh`: the real window, a real lookup, a box
      ticked, Apply pressed — then the EPUB's digest, the OPF's `<dc:date>` and
      ⌘Z read off the disk. It found that a sheet has no undo manager

### What Sprint 6 found and did not finish

- [ ] **Google Books has never answered.** Its shared anonymous quota was
      exhausted all day: HTTP 429 to all ten ISBNs, from both hostnames and with
      either `country` parameter. The reader is therefore tested against **one
      hand-written fixture** built from Google's documented shape, named as such
      in `Tests/ShelfCoreTests/Fixtures/online/README.md`. Re-run
      `Scripts/online-proof.sh` when the quota allows; it overwrites the
      fixtures with live answers. Until then, everything this repository knows
      about Google Books' JSON is read off a manual
- [ ] **The score is lenient with omnibuses.** "Earthsea & The Left Hand of
      Darkness" scores 94 against "The Left Hand of Darkness" — high enough to
      be clicked without thinking. A collection is recognisable (several titles
      joined by `&` or `/`), and recognising it is a rule worth its own test
      rather than a tweak to the weights
- [ ] **Open Library's speed varies by an order of magnitude**: 1.9 s to 24 s
      for the same kind of question, and three of ten proof-run requests timed
      out at 15 s before the retry was added. A 15-second limit and three
      attempts means a lookup can take 45 s with only a "Asking Open Library and
      Google Books" to look at. A first answer shown as soon as *either* service
      replies would fix it
- [ ] **Nothing has been measured about the response cache in use.** It is
      tested, and no run has yet asked the same book twice through the window to
      see the second lookup come back instantly
- [ ] **A real disagreement between the two services has never been seen**, so
      the proof run's "where the two disagree" table is one column of dashes.
      That is the same 429
- [ ] **The Edit menu reads a bare "Undo" after a fetch**, not "Undo Published".
      The undo itself works — `Scripts/online-apply-proof.sh` writes the field,
      presses ⌘Z and reads it gone off the disk — and `setActionName` is called
      on the same `UndoManager` that `registerUndo` was called on, which is the
      manager ⌘Z reaches. So the name is set and the menu shows the generic
      title anyway. Unexplained, cosmetic, and written down rather than guessed
      at. An edit made in the inspector still names itself

## Sprint 7 – Polish and release

- [x] **German localisation.** 429 catalogue entries, English and German, eight
      with plural variations; every drawn word through `Loc`; `FormatStyle` for
      numbers, dates and sizes; five tests, one of which refuses a sentence
      drawn without the catalogue at all
      ([ADR 0016](adr/0016-the-core-answers-in-english-the-window-translates.md)).
      Photographed in German: `docs/screenshots/sprint-7/`
- [x] **Accessibility: keyboard, contrast, labels.** Ten accessibility trees in
      `docs/accessibility/`, judged by `Scripts/ax-judge.py` and green; 21
      findings in the library window before, none after. Every sidebar row is a
      button a keyboard can activate (SlateKit 0.4.0), every hand-drawn control
      draws a focus ring, the arrows are off the menu bar
      ([ADR 0017](adr/0017-the-arrow-keys-leave-the-menu-bar.md)), and
      `make contrast` checks every colour Shelf decides against WCAG AA — two
      failed and are fixed
- [x] **The shortcut table feeds the menu bar.** ⌥⌘I had been declared twice and
      ⌘A and ⇧⌘W were written down nowhere; a menu item reads its words and its
      key out of `ShortcutReference` now, with a test that refuses a key
      equivalent written by hand anywhere else
- [x] **`docs/RUNBOOK.md`**, twelve paths, every one of them run once by
      `make runbook` with its output quoted rather than described
- [ ] Signing, notarisation, direct download → **v1.0**

### What the localisation did not cover

- [ ] **The device profiles' `note`** (`ShelfCore/Devices/Profiles/*.json`) is
      data, and still English. Translating a data file is a different decision
      from translating a program, and it wants its own line rather than a
      sentence smuggled into this one
- [ ] **Five sheets have never been photographed in German**: Send to Device,
      Delete from Device, the Calibre import protocol, Fetch Metadata and the
      orphaned-folders sheet. Their strings are in the catalogue and covered by
      the tests; nothing has looked at their *layout* in German, which is the
      only thing a picture can answer. `Scripts/online-shot.sh` and
      `Scripts/device-shot.sh` would take them with the same defaults-domain
      trick `german-shots.sh` uses

## Housekeeping, when it is next convenient

- [x] **Move the arrow keys off the menu bar.** Done in Sprint 7,
      [ADR 0017](adr/0017-the-arrow-keys-leave-the-menu-bar.md). Measured again
      by `Scripts/arrow-key-proof.sh`: 0.0 % of the main thread inside the menu
      machinery, against ADR 0006's 83 %.
- [x] **Sidebar rows have no role a keyboard user can activate.** Done in
      SlateKit 0.4.0: the combined element carries `.isButton` and a default
      action, and the accessibility tree in `docs/accessibility/grid.txt` shows
      33 `AXButton` rows where it showed none.

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
