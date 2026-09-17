# Architecture

## Building blocks

```
┌───────────────────────────────────────────────────────────────┐
│  SlateKit (Swift package, separate repo, pinned to a tag)     │
│  The look, shared with Selector: palette · sidebar rows ·     │
│  inspector blocks · grid cell · status bar · banner ·         │
│  shortcut sheet · welcome scaffold. Knows nothing of books.   │
├───────────────────────────────────────────────────────────────┤
│  App/Shelf (macOS, SwiftUI + AppKit)                          │
│  Views:    ContentView (owns the window's one focus value) ·  │
│            WelcomeView · SidebarView + ShelvesSection ·       │
│            LibraryBar (mode · sort · size · search) ·         │
│            CoverGridView (grid + cell) · BookTableView ·      │
│            InspectorView · ImportSheet · Theme                │
│  Services: LibraryModel (@MainActor @Observable: what the     │
│              window is looking at, and every action)          │
│            ImportModel (@MainActor: the sheet's own state)    │
│            CoverLoader (actor: cache + dedupe only)           │
│            CoverDecoder (ImageIO, pure, runs detached)        │
│            CoverDiskCache (actor, inside the library)         │
│            CoverWarmer (rings around the selection)           │
│            RecentLibrariesStore (security-scoped bookmarks)   │
│            SHA256Hasher (CryptoKit, the fast path)            │
│            TimingLog (SHELF_TIMING=1; silent otherwise)       │
│            EditingKeyMonitor (1–5, 0, R, T at the window)     │
├───────────────────────────────────────────────────────────────┤
│  ShelfCore (Swift package, no UI, runs on Linux too)          │
│  Model:     Book · SeriesRef · BookFormat · BookFileFormat ·  │
│             Shelf/ShelfTree/ShelfEdit · SmartCollection/      │
│             LibraryFilter/DuplicateReason · BookFolderName ·  │
│             TitleSort/AuthorSort · ISBN · ShortcutReference   │
│  Library:   Library + LibraryDescriptor + LibraryViewSettings │
│             IndexRebuilder · MetadataChange + MetadataEditor ·│
│             BookField/IdentifierEdit/TagEdit (what a typed    │
│             string does to a book) · AcrossBooks (what a      │
│             handful of books have in common)                  │
│  Index:     IndexSchema (migrations) · LibraryIndex (GRDB) ·  │
│             BookSort + BookOrder (the one SQL order)          │
│  Formats:   ZipReader · Inflate · XMLTree · OPFDocument ·     │
│             EPUBMetadata · FileNameMetadata · CoverFile ·     │
│             ZipWriter + SyntheticEPUB + MinimalPNG (fixtures) │
│  Calibre:   CalibreReader (metadata.db via a copy, WAL too) · │
│             CalibreCensus (the counting protocol) ·           │
│             CalibreImportSource → ImportCandidate ·           │
│             SyntheticCalibreLibrary (the fixture)             │
│  Import:    ImportPlanner → ImportRunner · ImportReport       │
│  Loading:   LoadPriority · WarmOrder · DecodeGate ·           │
│             InteractionWindow · CoverCacheKey/Policy          │
│  Hashing:   ContentHasher · FileDigest · PortableSHA256Hasher │
└───────────────────────────────────────────────────────────────┘
```

Rule: everything that can be **decided** without a window lives in `ShelfCore`;
everything that can be **drawn** without knowing the subject lives in SlateKit;
the app binds the two together. The core never imports AppKit, ImageIO or
PDFKit — the Linux CI job is what enforces that rather than good intentions.

The only external dependency in the core is GRDB.swift. See
[ADR 0003](adr/0003-zip-in-the-core.md) for why the ZIP reader is not libarchive
and [ADR 0004](adr/0004-slatekit-shared-with-selector.md) for the tag rule.

## What is where on disk

```
My Library/
  .shelf/
    library.sqlite      the index — a cache, deletable (ADR 0001)
    library.json        name, schema version, shelves, next book number
    covers/             the cover cache, keyed by book UUID + size
    Import-Report.txt   appended to, one block per import
  Austen, Jane/
    Pride and Prejudice (17)/
      Pride and Prejudice - Jane Austen.epub
      cover.png
      metadata.opf
```

Full schema: [docs/DATA-MODEL.md](DATA-MODEL.md).

## Data flow: opening a library

1. `LibraryModel.open(url:)` takes security-scoped access through
   `RecentLibrariesStore`, then `Library.open` reads `library.json` and refuses
   a library written by a newer Shelf.
2. `LibraryIndex(library:)` opens `.shelf/library.sqlite` as a `DatabasePool`
   (WAL) and runs the migrations.
3. `CoverDiskCache.cachedBookIDs()` lists which books have a cached cover — one
   directory read, which is what answers "Missing Cover" without a stat per book.
4. `LibraryModel.reload()` reads everything the window shows in one pass: all
   entries in the current sort order, the totals, and the tag/author/series/
   format facets.
5. The filter is applied in memory and the warmer starts in rings around the
   selection. The disk cache is trimmed once, in the background.

A library in iCloud Drive, Dropbox, OneDrive or Google Drive is *opened with a
warning*, not refused: SQLite in a synced folder can be corrupted, and here that
costs a rebuild rather than a library (`Library.syncWarning`).

## Data flow: the cover pipeline

Two sizes per book, and the reason there are two rather than one per slider
position is that a cache with a file per pixel width would decode the whole
library again every time the slider moved:

| | pixels | held for | roughly |
|---|---|---|---|
| `.grid` | 400 | every book, in memory | 40 KB each |
| `.large` | 1 000 | the selection only | 250 KB each |

`CoverLoader` is the coordinator, not the decoder: it caches results (one
byte-budgeted `NSCache` per size) and keeps a table of decodes under way, so the
same cover is never decoded twice at once. The decode itself runs in a detached
task through `CoverDecoder`, and `DecodeGate` allows four at a time. Every
request carries a `LoadPriority`: a cell asks `.interactive`, the warmer
`.background` — which stands still while a click is in flight.

`CoverDiskCache` sits inside `CoverLoader.decode`, on both sides of the gate:
the disk is *read before* the gate, because reading back a small HEIC is a
fraction of decoding a 1 600 px JPEG and queueing it behind four running decodes
would throw away most of the saving; the result is *written behind* the gate's
background lane, which already stands still while the user is working the window.

It lives **inside the library** (`.shelf/covers/`) rather than in
`~/Library/Caches`, because the key is the book's UUID: the cache belongs to the
library, moves with it, and a library on an external disk carries its covers
along. `CoverCachePolicy` holds the folder under 1 GB, oldest first, trimmed
once per open, and `Shelf ▸ Clear Cover Cache` names its current size.

**From Sprint 1, not later.** Selector's preview cache arrived in Sprint 6c,
after a sprint of "why is the second open slow"; with 8 000 books that is the
difference between a usable app and an unusable one (CONCEPT §13).

Scrolling is noticed through cells appearing rather than through
`onScrollPhaseChange`, which needs macOS 15 while Shelf targets 14 — a cell only
comes into existence when the grid scrolls or the window resizes, which is
exactly the signal wanted.

## Data flow: adding books

`ImportSheet` binds to `ImportModel` (`@MainActor @Observable`, owned by
`LibraryModel` so a run survives the sheet being closed). Choosing files or
dropping them runs `ImportModel.examine` on a detached task: each file's
metadata, cover and SHA-256, nothing written. The plan is then computed by
`ImportPlanner` against a snapshot of what the library already knows (digests,
ISBNs, title keys, formats per book) — one snapshot rather than three queries
per file.

What the sheet shows is that `ImportPlan`, and "Import" hands the very same
value to `ImportRunner`. Afterwards the index is written in batches of 500, the
report is appended to `.shelf/Import-Report.txt`, and the library's book-number
counter is stored. See [ADR 0002](adr/0002-copy-verify-then-trust.md).

## Data flow: editing metadata

The chain Sprint 2a built, and the order matters at every step:

```
a key press (EditingKeyMonitor) or a finished field in the inspector
  → BookField.apply / TagEdit / IdentifierEdit                    (ShelfCore)
      turns what was typed into .changed(Book) / .unchanged / .rejected
      — the rules for empty values, separators, decimals and check digits
  → LibraryModel.commit / setStars / toggleRead
      builds a MetadataChange from the *old* book: (before, after)
  → LibraryModel.apply
      1. registers change.inverse with the window's UndoManager   ← before any write
      2. names the action ("Rating"), so the menu reads "Undo Rating"
  → MetadataEditor.apply                                          (ShelfCore, off the main actor)
      3. reads the metadata.opf that is there
      4. lays only the changed fields over it
         — Calibre's custom columns, the shelves and the identifiers
           stay exactly as the file has them
      5. writes metadata.opf atomically                           ← the folder first
      6. LibraryIndex.save                                        ← the cache second
  → LibraryModel
      7. replaces the one entry in memory (not a reload: 5 000 entries is 350 ms)
      8. refreshes the totals, so "Unread" is right at once
      9. re-applies the filter, so a book just marked read leaves "Unread"
```

Undo is registered *before* the write because once the file is written nobody
can ask it what it used to say. Registering the inverse from inside the undo
block is what gives redo for nothing: `UndoManager` records whatever is
registered while undoing as the redo action. Measured from the key press to the
written file: 8 ms for a rating, 5 ms for a read status; and over 200 books
changing title, tags and description at once, 2.2 ms median and 13.6 ms at
worst, the search index included.

A **text** field is finished by ⏎ or by losing focus, and only then does any of
this happen. That is the whole of the debouncing: a timer would still write in
the middle of a word and would have to be flushed before the window closed.

No book file is opened for writing anywhere in that chain.

## Data flow: coming from Calibre

```
a Calibre folder
  → CalibreReader                                             (ShelfCore)
      copies metadata.db — and its -wal — into a cache folder of its own,
      opens the copy read-only, reads twelve tables, removes the copy
      (ADR 0009). The source is only ever read.
  → CalibreCensusTaker
      counts the database *and* the disk, because they disagree, and asks
      for the free space at the destination × 1.05
  → the sheet, or `shelf-tool calibre-dry`             ← nothing written yet
  → CalibreImportSource
      one ImportCandidate per file that is actually there, hashed, carrying
      Calibre's own metadata and Calibre's UUID
  → ImportPlanner → ImportRunner → ImportReport      (the Sprint 1 importer)
      the same copy-verify-then-trust run every import uses (ADR 0002)
```

Two orderings matter, and both were learned the hard way:

* **The columns' definitions go into `library.json` and the index *before* the
  books**, exactly as the shelf tree does — a value whose column the index has
  never heard of has nowhere to go (ADR 0010).
* **The index is written while the run goes on**, not after the last file.
  `ImportRunner` hands finished books to a `saveBatch` closure every 200, so a
  run that is killed leaves an index that matches the folder and the next run
  resumes. Writing it only at the end meant a killed import of 2 000 books left
  an index holding none, and the next run copied all 2 000 again.

## Data flow: rebuilding the index

`Library ▸ Rebuild Index from Folders` runs `IndexRebuilder` on a detached task,
erases the index and writes what the walk found. Digests are reused for files
whose size and modification date are unchanged, so a rebuild is not a re-hash of
the whole library. Folders that hold no readable book are *reported*, never
removed. This is the proof behind [ADR 0001](adr/0001-folder-is-the-truth.md) and
it is what makes the index safe to treat as a cache.

**The order matters, and silently.** The shelf tree is written *before* the
books: the index resolves each book's stored shelf paths against the shelves it
holds and skips what it cannot find, so saving the books first files every one
of them nowhere without an error
([ADR 0008](adr/0008-shelves-membership-in-the-book-hierarchy-in-library-json.md)).
A path that `library.json` has lost — a backup restored without its `.shelf`
folder — is *created* from what the books say, because the book said where it
stands and the folder is the truth.

## Data flow: shelves

```
  sidebar / drag / context menu / inspector
        ↓   ShelfEdit (may this name? may this go inside that? what happens
        ↓             to the books?)                       ← rules, in the core
  LibraryModel
        ↓   library.json  (the shape: what exists, inside what, in what order)
        ↓   metadata.opf  (per book: which shelves, as paths)  ← one undo group
        ↓   LibraryIndex  (a cache of both)
```

Membership is a field of the `Book`, which is what gives it undo, the
write-the-file-then-the-index order, and editing across a multiple selection for
nothing. Renaming a shelf therefore rewrites every book on it — a stored path is
a name, not a pointer — as one step on the undo stack.

## Data flow: several books at once

`LibraryModel.edit(_:actionName:undoManager:)` is the shape every action across a
selection takes: build a `MetadataChange` per book, drop the ones that change
nothing, and wrap the rest in an undo group named for how many books it touched.
What "the same value" and "Mixed" mean across a selection is `AcrossBooks`, in
the core, because a tag on *every* book and a tag on *some* of them are
different things and drawing them alike loses work.

## Reading a format

```
file → ZipReader (central directory) → META-INF/container.xml
     → the OPF → XMLTree → OPFDocument → Book + cover href
     → the cover's bytes
```

Every step is a place a real file goes wrong, and each has a fallback rather
than a failure: no `container.xml` → the first `.opf` in the archive; no OPF →
the file name; no cover in the manifest → the first image alphabetically; an
unreadable OPF → the book file; neither → the folder names. A book is never
refused because its metadata is odd, and the import report names what was
missing.

Namespaces are matched by *local name*, not by URI: EPUBs in the wild declare
prefixes wrongly often enough that resolving strictly would lose metadata that
is plainly there.

Formats other than EPUB and KEPUB import by file name in Sprint 1 and say so in
the report; `BookFileFormat.hasReadableMetadata` is the one place that changes in
Sprint 4.

## Concurrency

Swift 6 strict concurrency, complete. `LibraryModel` and `ImportModel` are
`@MainActor`; `LibraryIndex` is a `Sendable` final class over a GRDB pool;
`CoverLoader` and `CoverDiskCache` are actors; core types are `Sendable` value
types. Nothing slow runs on the main actor: reading files, hashing, decoding and
rebuilding all happen in detached tasks, and only their results hop back.

## Decisions

See [docs/adr](adr/).
