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
│  Views:    ContentView · WelcomeView · SidebarView ·          │
│            CoverGridView (grid + cell + search) ·             │
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
├───────────────────────────────────────────────────────────────┤
│  ShelfCore (Swift package, no UI, runs on Linux too)          │
│  Model:     Book · SeriesRef · BookFormat · BookFileFormat ·  │
│             Shelf/ShelfTree · SmartCollection/LibraryFilter · │
│             BookFolderName · TitleSort/AuthorSort ·           │
│             ShortcutReference                                 │
│  Library:   Library + LibraryDescriptor · IndexRebuilder      │
│  Index:     IndexSchema (migrations) · LibraryIndex (GRDB)    │
│  Formats:   ZipReader · Inflate · XMLTree · OPFDocument ·     │
│             EPUBMetadata · FileNameMetadata · CoverFile ·     │
│             ZipWriter + SyntheticEPUB + MinimalPNG (fixtures) │
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

## Data flow: rebuilding the index

`Library ▸ Rebuild Index from Folders` runs `IndexRebuilder` on a detached task,
erases the index and writes what the walk found. Digests are reused for files
whose size and modification date are unchanged, so a rebuild is not a re-hash of
the whole library. Folders that hold no readable book are *reported*, never
removed. This is the proof behind [ADR 0001](adr/0001-folder-is-the-truth.md) and
it is what makes the index safe to treat as a cache.

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
