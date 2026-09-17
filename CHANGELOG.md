# Changelog

Newest first. Measured numbers belong here, with the machine they were measured
on and what was *not* measured.

## Sprint 4 – what an interrupted import leaves behind · 17 September 2026

### Fixed — a killed import no longer doubles its own books

`ImportRunner` writes a book's folder, file, cover and `metadata.opf` before the
book reaches `saveBatch`, and `saveBatch` runs every 200 books. A run that is
**killed** — a crash, a SIGKILL, the power going — therefore leaves up to 200
finished folders the index never heard of, and the next run over the same source
planned those books again and copied them into *second* folders. In the Sprint 3
measuring run that was 23 folders. Nothing was lost and nothing was overwritten,
which is exactly why it went unnoticed: the library simply grew a pile nobody
could see.

Note that **cancelling** was never the problem. The tidy path still writes its
short last batch (`ImportRunner.run`), so it leaves nothing behind. It is the
untidy death that does, and that is the one this fixes.

**The resume takes its own back.** Before it plans anything, an import now lists
the book folders the index does not hold (`OrphanedFolders.find`), and for each
one whose `metadata.opf` names a book *this very run is importing*
(`OrphanedFolders.claimable` — by UUID, never by title) it reads the folder into
the index exactly as a rebuild would (`OrphanedFolders.adopt` →
`IndexRebuilder.readFolder`). The planner then sees a library that already holds
those books and the ordinary duplicate rules do the rest: the same file is
recognised as already there, and a second format joins the book in the folder it
is already in. Nothing is copied and nothing is written into the folder.

Measured, on the 400-book synthetic library
(`~/Library/Caches/Shelf/measure-library-4/`, M-series Mac, macOS 15.6):

| | after the kill | after the resume |
|---|---|---|
| book folders on disk | 250 | 400 |
| books in the index | 200 | 400 |
| folders no book points at | 50 | **0** |
| titles appearing twice | 0 | **0** |

The kill is a real one: `SHELF_EXIT_AFTER=250 shelf-tool import` leaves the
process mid-run without unwinding and without writing its last batch. It is
section 9 of `Scripts/proof-run.sh`, so it runs with every proof from now on.
The control — what the same resume does *without* adoption — is a unit test
rather than a second measuring run: six books become ten folders
(`OrphanedFoldersTests.withoutAdoptionItDuplicates`).

### Added — `Library ▸ Find Orphaned Folders…`

What no run can claim is reported and shown, never tidied away. The import
report gained two blocks — `n` folders taken back from an interrupted run, and
`n orphaned folders` with their paths and the sentence "Nothing was removed" —
and the new menu item lists them with their titles, their paths, their size and
whether they still hold a book file.

**It takes two steps, on purpose.** The first lists what was found, with a
tick-box each. The second names **every file** that would move, and only there
is there a button that moves anything. That is the rule deleting on a device
follows (CONCEPT §8.3) applied to the library: Shelf's belief that a folder is
debris is a belief, and the person whose books these are gets to check it. What
moves goes to the **Trash**, never to `unlink` — the difference between a
mistake and a disaster is whether the folder can be dragged back out.

`shelf-tool orphans <library>` is the command-line half, and it stops at
listing.

## The app icon · 17 September 2026

### Added

**Shelf has its own icon.** The finished icon package Erik drew lives in
`docs/icon/` — the same place Selector keeps its — and its macOS variant is now
the app's `AppIcon` asset: ten PNGs from 16 to 1024 px, checked with
`sips -g pixelWidth -g pixelHeight` (16/32, 32/64, 128/256, 256/512, 512/1024 —
each `@2x` twice its base, as the catalog claims). `iconutil -c icns` on
`docs/icon/iconset/Shelf.iconset` is the independent cross-check: it produces a
422 KB `.icns` from the same source, while Xcode's `actool` compiles the catalog
to a 33 KB `AppIcon.icns` inside the bundle. Both draw the same picture; the
size difference is that `actool` re-encodes and shares, `iconutil` keeps the
PNGs as they came.

Proof: `docs/screenshots/sprint-4/icon-in-dock.jpg` and
`icon-window-and-dock.jpg`. At 16 px the two shelf boards and the coloured
spines still read as a bookcase — the individual books merge into bands of
colour, which is what that size can carry.

**Worth knowing for the next person.** The first launch after the build still
showed the generic placeholder in the Dock: the bundle was right (`AppIcon.icns`
present, `CFBundleIconFile` and `CFBundleIconName` both `AppIcon`), and
LaunchServices was serving the icon it had cached from every earlier build,
which had an empty icon set. `lsregister -f <app>` clears that. Nothing about
the build needed changing, and a fresh machine would not see it.

## Sprint 3 – Calibre import, and what Sprint 2c left open · 17 September 2026

### Added — the Calibre import

**`File ▸ Import from Calibre…`** asks for the folder that holds `metadata.db`
and shows what is in it before a byte is copied. `metadata.db` is read **through
a copy**, never in place, and the write-ahead log is copied with it
([ADR 0009](docs/adr/0009-calibre-is-read-through-a-copy-of-metadata-db.md)) —
Calibre uses WAL, so while Calibre is open the newest rows are in the log and
not in the file, and a copy of the one file is the library as of the last
checkpoint.

**The counting protocol** counts the database *and* the disk, because they
disagree: `data` is what the library believes and the folder is what it has.
Books, authors, series, tags, formats per type, formats Shelf does not import,
each custom column with its kind, the files the database lists and the disk has
not got, the files on the disk it has never heard of, the ones with no cover,
the total size, and the free space × 1.05 — the same margin `ImportPlan` uses, so
the sheet and the runner cannot disagree about "enough room". Only room decides
whether Import can be clicked. Also `shelf-tool calibre-dry`, which prints the
same value and writes nothing anywhere.

**The import is the importer that was already there.** `ImportPlanner`,
`ImportRunner` and `ImportReport` were built in Sprint 1 and proved against
5 000 books; this is that run with a better source of metadata (ADR 0002).
Calibre's UUID becomes the book's identity, its 0…10 rating is kept whole so a
half star survives a round trip, and the cover comes from Calibre's `cover.jpg`
rather than out of the book file — somebody who replaced a bad cover did it
there.

**Calibre's custom columns, read-only**
([ADR 0010](docs/adr/0010-calibre-custom-columns-are-read-only.md)): the values
in each book's `metadata.opf` as one `shelf:custom` meta, the definitions in
`library.json`, both cached in the index, and a `From Calibre` section in the
inspector saying what kind each one is and that it cannot be edited. A datatype
this Shelf has never heard of is a line in the report with the others imported
around it; Calibre's own `calibre:user_metadata:` metas are left exactly where
they were found.

**`shelf-tool calibre-synthesise`** writes a Calibre library nobody wrote —
Calibre's folder layout and its table shapes — which is what the proof run and
the fixtures are made of. No borrowed book is in this repository.

### Fixed — four things the proof run found, and one that reading a screenshot did

None of these failed. That is what they have in common, and it is why they were
there.

- **An interrupted import started again instead of resuming.** The index was
  written once, after the last file, so a run killed after 1 394 of 2 000 books
  left an index holding **none** — and the next run planned all 2 000 again.
  3 394 files where 2 000 belonged. `ImportRunner` now hands finished books to a
  `saveBatch` closure every 200, so an interruption leaves an index that matches
  the folder. The next run then reads `1600 new books · 400 skipped`.
- **And then the resumed run died** on `UNIQUE constraint failed: books.number`,
  because the counter is stored when a run *finishes*. The start is now
  `max(library.json's counter, the highest number in the index + 1)`, which
  never goes backwards, so a deleted book's number is still not reused.
- **A rebuild died on the same constraint.** That is the one failure ADR 0001
  cannot survive: the index is a cache *because* it can always be built again.
  `books.number` is unique because two books in one folder would overwrite each
  other — a rule about folders, not an invariant the cache may die over. A book
  whose number is taken gets a free one; the folder on disk is not renamed.
- **The window erased the custom columns it had just imported.** `runImport`
  wrote its cached `library.json` back over the one the import had written,
  taking the column *names* with it. The values were in every OPF and in the
  index and the inspector had nothing to label them with.
- **The grid drew one selection border for eight selected books** — the cell
  asked for the *anchor* rather than the selection. Found by looking at
  `docs/screenshots/sprint-2c/selection.jpg`, which is the argument for looking
  at screenshots rather than only taking them.

### Measured — Sprint 3

On this machine (Apple silicon, macOS 26), against a synthetic Calibre library
of **2 000 books** (`shelf-tool calibre-synthesise`), 41 MB in 6 001 files.

**Reading and counting**

| | |
|---|---|
| `calibre-dry`, database copied, read and counted | **3 s** |
| the import, hashing + copying + verifying + indexing | **6.9 s** |
| peak memory of the import process | **93 MB** |

**What came across**

    books 2000 · authors 3 · series 2 · tags 3 · formats 2000
    ISBNs 2000 · custom columns 4 · custom values 8000 · rated 800
    Calibre's UUIDs kept: 2000 of 2000

**The Calibre library, before and after.** Every file hashed with
`/usr/bin/shasum`, a tool that knows nothing about this code:

    6001 files, byte for byte identical
    nothing newer than metadata.db anywhere in it
    ten sampled copies: digest in the index == shasum on disk, 10 of 10

**Resume.** The import killed once copying had started, then run again:

    after the interruption: 400 in the index, 423 files on disk
    second run:  plan: 1600 new books · 400 skipped · 11.5 MB
    third run:   plan: 2000 skipped · 0 B

**Tests**: 376 in the core, up from 342 at the start of the sprint. SlateKit:
23, up from 11.

### The evidence Sprint 2c owed

Its screen locked in the middle of its run. This one was held awake with
`caffeinate -dimsu`, and the guard that only asked at the *start* now asks again
whenever a window-driven script is about to blame the app for something.

- **The three missing screenshots** are in `docs/screenshots/sprint-2c/`: the
  table with its sort arrow, the inspector showing `Mixed` across eight books,
  and the context menu's *Add to Shelf ▸*, each with its accessibility tree.
- **The table at 4 996 rows**, `Scripts/table-scroll.sh`, twelve seconds of
  scrolling with `/usr/bin/sample` on the process:

      peak memory while scrolling:                  282 MB
      main-thread frames mentioning a cover decode:   0
      main-thread frames mentioning file I/O:         0
      main-thread frames mentioning SQLite:           0
      main-thread frames in SwiftUI/AppKit:       3 610
      main-thread frames in mach_msg (idle):         13

  That last pair is what makes the three noughts worth anything: the first
  working version of the script reported the same noughts with the main thread
  8 213 samples out of 8 440 *asleep*, because nothing had scrolled. It
  photographs the window before and after now and refuses to report a
  measurement of an idle app.

  **282 MB replaces Sprint 2c's 295 MB**, which was read while the screen was
  locked.

- **`Scripts/shelf-proof.sh` and `keyboard-proof.sh` both run green**, exit 0 —
  including the one path nothing had ever run: a shelf dragged onto the
  **SHELVES heading**, which is the only way to get a shelf back out of another
  one. `keyboard-proof` reads 5 of 5 both ways.

- **`965bad8` is clean.** The commit Sprint 2c made while `make smoke` had just
  failed, checked out into a worktree of its own and run unpiped:

      make test   exit 0   (336 tests)
      make app    exit 0
      make lint   exit 0
      make smoke  exit 0

  The failure was the leftover Shelf instance the proof script had left running,
  as Sprint 2c suspected. It is now measured rather than suspected.

### Not verified

Honestly, and in the order that matters.

- **Nothing has been run against a real Calibre library.** Everything above is a
  synthetic one, written by `calibre-synthesise` against Calibre's table shapes
  *as this session understands them*. The shapes were written out by hand
  precisely so the fixture would not agree with the reader by construction, but
  a hand-written shape is still a claim. `~/Downloads/Calibre Library Erik`
  holds a `metadata.db` with no book folders beside it; it would exercise the
  schema and not the import, and it has not been touched.

- **An interrupted import still copies up to 200 books twice.** The batch in
  flight when the process is killed was never indexed, so the resumed run copies
  those again — 23 of them in the measured run. Their files sit in folders no
  book points at. Nothing is lost, nothing is overwritten, the source is
  untouched, and a rebuild no longer trips over them. It is not nothing.

- **The table measurement is of *keyboard* scrolling.** `Scripts/scroll-at.swift`
  posts scroll-wheel events and reports success, and the SwiftUI `Table` does not
  move for them at all — byte for byte identical after twenty clicks inside the
  window, changed at once by one Page Down. Whether trackpad scrolling stays
  smooth while the cover cache fills is still the open question it was.

- **Shelf on a German Mac is still untested.** SlateKit speaks German again, and
  a German window would now mix the package's nine German words into Shelf's
  English ones — which is the state Selector is *not* in, and Shelf is, until
  Sprint 7. Nobody has run either under a German locale.

- **Selector has not been built against SlateKit 0.3.1.** The claim that raising
  its pin changes nothing rests on the defaults being what 0.1.6 drew and on
  seven tests that say so, not on a screenshot of Selector.

- **`Missing Cover` counts every book in a freshly imported library** until the
  cover cache has been warmed, because the collection is answered from the
  cache. It corrects itself as covers are drawn. Seen in
  `docs/screenshots/sprint-3/`; in the backlog.

### Changed — SlateKit 0.3.1, and Shelf looks exactly as it did

0.3.0 changed how two components that **Selector also draws** look, and Selector
is pinned to 0.1.6. The day it raised that pin for something else, its tag rows
and its rating rows would have been redrawn by a decision it never took part in.
A pin exists so that cannot happen, and 0.3.0 had made it possible.

0.3.1 turns all three of 0.3.0's appearance changes into options that default to
the older look:

| what 0.3.0 changed | how Shelf asks for it now | the package's default |
|---|---|---|
| chips grey instead of accent | `SlateChip(style: .neutral)` | `.accent`, the fill since 0.1.0 |
| the ✕ fades in under the pointer | `SlateChip(removeButton: .onHover)` | `.always`, as since 0.1.0 |
| no "3/5" beside the stars | `SlateStarRating(label: .unratedOnly)` | `.value`, as since 0.1.0 |

Shelf sets all three at its three call sites and is pixel-for-pixel what it was
on 0.3.0. **Selector can now raise its pin to 0.3.1 and see nothing change at
all** — which is the point. The placeholder-colour fix is not in the table and
does not need to be: `SlateEditableFields` arrived in 0.2.0, after 0.1.6, so no
shipping app has ever seen those fields look another way.

The rule this establishes, and it is now in `CLAUDE.md`: **an existing SlateKit
component keeps its previous look in the default; what is new arrives as an
option the host asks for.**

### Changed — SlateKit speaks German again

Removing the German localisation in 0.3.0 was wrong, and the reasoning was about
the wrong app. It argued that Shelf is English until Sprint 7, which is true —
and Shelf is not the only customer. **Selector ships German.** Taking out the
package's nine strings does not spare Selector a mixed window; it puts nine
English words into its German one, in an app that has already shipped. That two
apps are at different points is what binding by tag is *for*, not a reason for
the package to have one language.

The catalogue, the `resources:` clause and the eight `String(localized:)` call
sites are back, all nine keys with them. `Unrated` is **"Ohne Bewertung"** rather
than 0.1.5's "Unbewertet" — that reads as a verdict on the book, where the point
is that nothing has been said yet.

Three tests hold it, each watched failing before it was kept: every key has a
German unit in state `translated`; every plain-literal `String(localized:)` in
the sources is a key the catalogue knows; and the four keys the compiler builds
out of an interpolation are spelled out, because renaming one of those still
compiles and falls back to English without a word. SlateKit: **23 tests**, up
from 11.

Shelf's own UI stays English until Sprint 7. The strings in this package are the
package's own; Shelf's — "Mixed", "Add series…" and the rest — are Shelf's, and
they are translated when Shelf is.

## Sprint 2c – Shelves, the table, and acting on many books · 17 September 2026

### Added

- **Shelves.** Make one with **+** in the sidebar and name it in place, the way
  the Finder names a folder; drag a shelf onto another to put it inside; drag
  books onto a shelf; or use the context menu, or the inspector's *Shelves* row.
  Removing one asks first, naming the shelf and how many books come off it, and
  the message says what is *not* happening: "The books stay in the library. Only
  the shelf goes."
- **[ADR 0008](docs/adr/0008-shelves-membership-in-the-book-hierarchy-in-library-json.md)** —
  **a book carries its own shelves; `library.json` carries their shape.**
  Membership is a field of the `Book`, written into that book's `metadata.opf`
  as stored paths (`Fiction/Sci-Fi`); what shelves exist, inside what, in what
  order, lives in the library descriptor. The index holds both and is the
  authority for neither.
- **The table (⌘2)**: nine columns — Title, Author, Series, Rating, Tags,
  Format, Added, Read, Size — plus a tenth, *Changed*, hidden until asked for.
  Columns are chosen and resized from the header's own menu, and the layout is
  kept in `library.json`. The same books, the same selection, the same keys as
  the grid.
- **Sorting**: six fields, each both ways round. The direction is no longer
  baked into three of them, so every order reverses. Clicking a column header
  and picking from the sort menu do the same thing to the same value, and it is
  saved per library.
- **Multiple selection** — ⇧, ⌘, ⌘A — and **editing across it as one undo step**,
  named for how many books it touched ("Add to Shelf (12 books)"). Rating, read
  status, tags and shelves act on all of them; title, series and description
  stay locked. The inspector shows shared values and **Mixed**.
- **Duplicates**, the last greyed-out row in the sidebar, using the importer's
  own three rules asked of the whole library — and the inspector says *which*
  rule matched, because identical bytes is a fact and identical title-and-author
  is a guess that fits two editions and a translation.
- **Not on any Shelf**, answered from the book itself rather than from a second
  list, so the sidebar's count and the grid's filter read the same fact.
- **`shelf-tool shelve`, `unshelve`, `bulk-tag-undo`** — what section 8 of the
  proof run is made of, and what arranges a library before it is photographed.
- **`Scripts/shelf-proof.sh`, `keyboard-proof.sh`, `shots-2c.sh`**, and the three
  small tools they drive the window with (`cell-point.swift`, `click-at.swift`,
  `drag-at.swift`).

### Changed — the look, through SlateKit 0.3.0

Four corrections, all of them to things the package said louder than it should.
Three of them change **Selector** too, once it raises its pin from 0.1.6.

- **Tag chips are grey.** They had been `Slate.accent` since 0.1.0 — the same
  yellow-orange as the selected row and the focused field. That colour means
  *selected*, and eight tags in it make a window look as though eight things
  were chosen. The ✕ now waits for the pointer (or keyboard focus), faded rather
  than added, so a row of chips does not re-flow under the pointer.
- **An empty field prompts in a label's colour, not a value's.** SwiftUI hands
  a field's foreground colour to its placeholder unless told otherwise, so an
  empty inspector read as a filled one: "Add publisher…" in the same ink as
  "Orbit".
- **The stars no longer write "3/5" beside themselves.** Five drawn stars are
  the statement. *Unrated* stays — zero is the one rating with no picture of
  its own.
- **The package speaks English again.** The German localisation added in 0.1.5
  is removed. Shelf and Selector are English until their own Sprint 7, so those
  nine words would have appeared in German inside an otherwise English window.
  Localising is a decision about a whole app, taken for the whole app at once.

SlateKit has a `CHANGELOG.md` now, because two apps bind it by tag and that only
works if the person raising a pin can read what moves.

### Changed — in Shelf

- **The inspector's placeholders invite a value instead of stating a format**:
  "Add series…", "Add publisher…", "Add date…", "Add language…", "Add ISBN…".
  The format moved into the help text, where it is there when wanted and
  invisible when not. `BookField` owns both, next to the label.
- **One focus for the window.** The grid and the search field had a
  `@FocusState` each, and handing the keyboard from one to the other meant
  setting one true while the other still was. One value, `WindowFocus`, replaces
  both.
- **Escape in the search field empties it** as well as handing the keyboard to
  the grid, and ⏎ hands it on rather than dropping it.
- **⌘A** selects every book the filter shows — in the Library menu, where
  SwiftUI's own Select All cannot fight it.
- **A shelf path in an OPF is written as a path.** `JSONEncoder` escapes a
  slash by default, so `Fiction/Sci-Fi` went into the file as
  `Fiction\/Sci-Fi`: legal, and unreadable in a field whose argument for being
  JSON was that it is lossless *and* readable.

### Measured

On this machine (Apple silicon, macOS 26), against a synthetic library of
**4 996 books** — 5 000 generated, four of them duplicates the importer refused.
`Scripts/proof-run.sh`, sections 7 and 8.

**Putting a book on a shelf**, 1 000 assignments in 10 batches, each through the
same `MetadataChange` path a drag uses:

| | |
|---|---|
| median of the batch medians | **2.5 ms** |
| worst single assignment | **14.0 ms** |
| batches with anything over the 20 ms target | **0 of 10** |

**The sidebar's arithmetic against SQL.** The sidebar counts a shelf by walking
the books it holds in memory; this asks the database the same question a
different way, which is the only version of the check worth running — a sidebar
agreeing with itself is worth nothing.

    Fiction                  500 books   (this shelf and everything inside it)
    Fiction/Science Fiction   200 books
    Non-Fiction               300 books
    To Read                   100 books
    on a shelf 1000 · on none 3996 · sum 4996 of 4996

**Fifty books tagged at once and undone**, which is what ⌘Z does to a multiple
selection:

    tagged 50 books in 137.5 ms, undone in 131.4 ms
    metadata.opf byte for byte as before:  50 of 50
    EPUBs untouched:                       50 of 50
    books the index still finds under the tag: 0

**The index thrown away and rebuilt from the folders**, with twenty shelves
three levels deep:

    books back on a shelf: 1000 of 1000
    shelves back:            20 of 20
    the empty shelf among them: yes — no book can remember it, library.json can

**Editing one field** (section 7, re-measured this sprint): median **2.4 ms**,
worst **23.8 ms**, none over the 50 ms target, across 200 books — including the
search index. **Searching** 4 996 books for a tag that did not exist five seconds
earlier: median **0.7 ms**, worst **0.8 ms**, first search on a cold page cache
**1.4 ms**.

**Memory**: peak **295 MB** with 4 996 books open and 4 901 covers in the cache,
against CONCEPT §11's 1.5 GB. Measured by `make smoke` — see *Not verified* for
what that number does and does not cover.

**Tests**: 342 in the core, up from 313 at the start of the sprint. SlateKit: 11,
and every colour pair still clears WCAG AA.


### Not verified

Honestly, and in the order that matters.

- **Three of the four screenshots are missing.** The table with its sort arrow,
  the inspector showing `Mixed`, and the context menu's *Add to Shelf ▸* were
  never taken: **the Mac's screen locked in the middle of the run**
  (`CGSSessionScreenIsLocked = Yes`, 14:36:08, confirmed through `ioreg`), and it
  stayed locked for the rest of the session. I did not drive the window after
  that — posting clicks and keystrokes into somebody's locked session is not
  mine to do. `docs/screenshots/sprint-2c/README.md` says what each was to show
  and what stands in for it.

  The one image that is there was drawn before the lock, and it carries the
  shelves, the counts, the new placeholders and *Unrated*.

- **The table has not been scrolled at 5 000 rows.** The `sample` run Sprint 1
  did for the grid needs a window, and the window was locked away. The table is
  a SwiftUI `Table`, which recycles rows, and nothing in a row reads a file —
  but that is an argument, not a measurement, and the brief asked for a
  measurement.

- **"Clicking a cover does not take the keyboard from the search field" is not
  fixed, and I cannot show that it ever was broken.** `Scripts/keyboard-proof.sh`
  reads **5 of 5** on this build and **5 of 5 on the build from before the
  change too**. The one-focus-per-window change is a simplification that removes
  the state the symptom was blamed on; the symptom itself could not be
  reproduced in five rounds either way. What *is* measured, 0 of 5 before and
  5 of 5 after, is Escape in the search field clearing it.

- **The screen lock is very probably what Sprint 2b recorded as "an app with no
  window", but that is inference.** Today's two sightings match it exactly
  (`window-count` reading `5 0 0`, no crash report, app alive at 0 % CPU), and
  the state is reproducible by locking the screen. I have no record of the lock
  state at the moment of the Sprint 2b sighting, so I cannot say it was the same.

- **The memory number was taken with the screen locked.** 295 MB is a real
  reading of a real process holding 4 996 books and 4 901 covers, but a window
  that is not being composited may do less than one that is. It is not a
  measurement of scrolling the table.

- **One commit was made while `make smoke` had just failed.** `965bad8`
  (*Duplicates*). I had piped `make smoke` through `tail`, which hid its exit
  code behind `tail`'s. The cause was a Shelf instance left running by the proof
  script, not the code: run again immediately afterwards, three times, it passed
  with exit code 0. I stopped piping the check after that.

- **Shelf on a German Mac is still untested.** SlateKit's own German strings are
  gone, so the "two languages in one window" problem is gone with them, but
  nobody has run Shelf under a German locale.

- **Selector has not been built against SlateKit 0.3.0.** It is pinned to 0.1.6
  and unaffected until somebody raises that pin; what the three visual changes
  look like *there* is unverified.

- **`Scripts/shelf-proof.sh` and `keyboard-proof.sh` have not been re-run since
  they gained the screen-awake guard**, because the screen has been locked ever
  since. Both passed in full before it; the guard itself was tested on its own,
  including the bug it had at first — `grep -q` under `set -o pipefail` makes the
  pipeline exit 141, so the check read a *successful match* as a failure and
  waved a locked screen straight through.

- **Dragging a shelf onto the *Shelves* heading** — the way to take a shelf back
  out of another — is implemented and was not exercised by the proof script,
  which only drags a shelf onto another shelf.


## Sprint 2b – All the fields, tags and series · 17 September 2026

### Added

- **Every metadata field is editable**, and the rules for each one live in the
  core rather than in a text field: `BookField`, `IdentifierEdit`, `TagEdit` and
  `ISBN` decide what an empty field means, how several authors are separated,
  whether "2,5" is a number, whether an ISBN can be that number at all. The
  inspector is three lines per field. One property is tested for every field at
  once — **what a field shows, the same field accepts back** — and it failed when
  written, for a real reason: `published` stores a moment and shows a day, so
  committing an untouched field would have moved the book's date to midnight.
- **Debouncing, in the form it turned out to need**: a field is written when it
  is *finished* — ⏎, or the focus leaving it — and Escape discards. Not a timer:
  a timer still writes in the middle of a word and has to be flushed before the
  window closes. Undo is one step per finished field.
- **Tags as chips**, in Selector's shape: a field reading "Add tag… (T)", the
  completions under it, the chips below that. ⏎ adds, ⌫ in an empty field
  removes the last, the chip's ✕ removes that one. Completion comes from the
  sidebar's own tag facets, so it is not a second query, and a tag that differs
  only in case keeps the spelling the library already uses. **T** focuses the
  field, shows the inspector if it is hidden, and scrolls the field into view.
- **Series**: the sidebar filters, the grid inside a series is ordered by series
  index whatever the sort menu says, and the inspector reads "Book 3 of 7" —
  counted from this library, and the help says so.
- **Search covers the six fields CONCEPT §4 asks for**, ISBN included. FTS5 has
  no `ALTER TABLE … ADD COLUMN`, so migration 2 rebuilds the table and refills
  it from the tables it summarises. Both spellings of an ISBN are indexed.
- **[ADR 0007](docs/adr/0007-a-metadata-change-does-not-rename-the-folder.md)** —
  a metadata change does not rename the book's folder. The UUID holds the
  identity; a rename is the one file operation that can lose a book, and it
  would happen at the worst moment. "Reorganize Library…" becomes its own
  command with a preview.
- **`shelf-tool bulk-edit`, `epub-digests`, `search-time`, `verify-edits`** —
  what section 7 of the proof run is made of.

### Fixed

1. **A line break inside an OPF attribute came back as a space.** XML
   attribute-value normalisation replaces a literal tab, newline or carriage
   return in an attribute *before* the parser reports it, and
   `calibre:title_sort`, `calibre:series`, `opf:file-as` and Calibre's custom
   columns are all attributes holding text a person typed. There are two
   escaping functions now. Two more layers of the same defect were underneath:
   XML line-ending normalisation turns a literal CR in element text into LF, and
   **`"\r\n"` is a single `Character` in Swift**, so `case "\r"` never matched a
   Windows line break at all — both escaping functions walk unicode scalars.
2. **The editing keys died once a text field had been typed in.** 1–5, 0, R and
   T were handled by `.onKeyPress` on the grid; after an inspector field had
   held focus, the accessibility tree reported focus on the *window* and on no
   control, where that handler never fires — and clicking a cover could not
   revive it, because the grid's `@FocusState` still said `true` and assigning
   `true` is not a change. Measured: a tag typed through T landed **0 times out
   of 5**. `EditingKeyMonitor`, a local `NSEvent` monitor, does not depend on
   SwiftUI focus; its one rule is to keep out of text being typed, which is the
   definite question "is the first responder a field editor". Measured again
   afterwards: **5 of 5**.
3. **The sidebar buried Series, Formats and Devices.** A section could take 200
   rows and a 120-book library already has 97 authors. Twelve per section, with
   the "+ N more — use ⌘F" line that was already written for it.
4. **One window wrote "epub" in the sidebar and "EPUB" in the inspector.** One
   spelling now, `BookFileFormat.label`, with a test over every case.
5. **The smoke test called an app with no window "ok"** — twice. First because
   it only asserted that a window *exists*; then, after that was fixed, because
   the one thing "on screen" found was a **menu-bar strip**, one of the four
   1512 × 33 windows every app carries. `window-count.swift` prints a third
   number now, and the assertion looks five times before failing, because the
   reading flickers.
6. **The screenshot script reported success for work it had not done**: it
   photographed a stale instance four times (a `quit` is refused while a sheet
   is open), asked the wrong Selector process for a window, never scrolled the
   sidebar (System Events has no `scroll` command — `sidebar.png` was a
   byte-for-byte copy of `library.png`), and kept the 1.2 MB PNGs it said it had
   replaced.
7. **SlateKit 0.2.0 and 0.2.1** — the editable fields, and then the look of
   them: a field showing its background at all times made nine filled boxes that
   read as a form, where Selector's inspector reads as a column of values that
   happen to be editable. Also the welcome screen's shortcut line, which squeezed
   its labels instead of wrapping, and the tag chips, which claimed the tag
   field's help text in place of their own.

### Measured

MacBook Pro, Apple silicon, macOS 26.6.2, Release build.
`Scripts/proof-run.sh ~/Library/Caches/Shelf/proof-2b`, 5 000 synthetic EPUBs
(4 996 books after the duplicate check), 200 of them edited.

| | median | slowest | target |
|---|---|---|---|
| one change — title, tag and description, `metadata.opf` **and** the search index | **2.2 ms** | **13.6 ms** | 50 ms |
| searching 4 996 books for a tag that did not exist a second earlier | **0.6 ms** | 0.7 ms | 100 ms |
| the same search, cold page cache | 1.2 ms | | |

95th percentile of a change: 4.1 ms. **None of the 200 was over the 50 ms
target.**

Memory, with the 4 996-book library open in the window and 16 tags typed into
the inspector by keyboard: **250 MB before, 262 MB at the peak** — against the
1.5 GB the concept allows. All 16 were written and are findable.

And the three claims the sprint is really about:

```
══ are those 200 book files still byte for byte what they were?
  every one of them is unchanged ✓
══ throwing the index away again, and asking the folders about all 200
checked 200 books
  titles without the suffix:      0
  books without the tag:          0
  descriptions that do not match: 0
  found by searching for the tag: 200
  every change survived ✓
```

**313 core tests**, 49 of them new. Three were checked by removing the fix and
watching them fail: the search migration (an existing library loses its *whole*
search index without the refill, not only the ISBN), the carriage return in a
description, and the line break in an attribute.

The evidence at the window is in `docs/screenshots/sprint-2b/`:

- `inspector-tags.jpg` — the tag field with "fa" typed and focused, "fantasy"
  and "favourites" offered under it, the book's own tags as chips with ✕, and
  the sidebar's tag counts beside it.
- `ax-tree.txt` — the same thing as the accessibility tree reads it: every field
  with a name and a value where Sprint 1 had static text, the suggestions and
  the chips as buttons of their own, each saying what it does.
- `opf-diff.txt` — one book's `metadata.opf` before and after, with the EPUB's
  SHA-256 on both sides of it. Four lines change; `calibre:title_sort` follows
  the title without being asked; the EPUB is the same string.

### Not verified

- **Clicking a cover does not reliably take the keyboard back from the search
  field.** After a search, the editing keys keep going into the search box until
  Escape is pressed there. Escape works, is a normal macOS idiom, and is the
  documented way out; the rest is in `docs/BACKLOG.md`. Three attempts at a fix
  (AppKit's `makeFirstResponder(nil)`, a model-owned focus flag, clearing the
  `@FocusState` first) each improved it without settling it.
- **One launch produced no window at all.** The app ran at 0 % CPU with a menu
  bar and no window in its accessibility tree. It happened once, was not
  reproducible in six further cold starts, and left no crash report. It is the
  reason the smoke test's window check was tightened twice; if it returns, the
  smoke test will now say so instead of printing "ok".
- **The window was driven by AppleScript, not by hand.** Every claim above about
  the keyboard was measured that way — clicks at fixed coordinates, keystrokes
  with delays. It found real defects, but it is not a person using the app, and
  a few of its failures turned out to be the coordinates rather than the code.
- **German** is Sprint 7, but SlateKit localises *its own* strings from 0.1.1.
  On a German Mac the package's words ("Unrated", "Remove") will appear in
  German beside Shelf's English ones. Not checked on a German system.

### Somebody has now seen the window

The Screen Recording permission exists, so `Scripts/screenshots.sh` ran for the
first time. Five shots in `docs/screenshots/sprint-1/`, Shelf and Selector at
the same size (1440 × 877 points, 2880 × 1754 pixels), against a **120-book**
library in `~/Library/Caches/Shelf/measure-library-2b`.

**The four pixels, out of both files:**

| point in the window | Shelf | Selector | |
|---|---|---|---|
| sidebar background | `#2B2B2B` | `#2B2B2B` | identical |
| main area | `#161616` | `#293A41` | not comparable |
| inspector background | `#2B2B2B` | `#2B2B2B` | identical |
| selected sidebar row | `#52472F` | `#52472F` | identical |

Three of the four are identical to the byte. The fourth is not a finding: the
probe's second point sits in the middle of the content area, and Selector's is
filled with a photograph while Shelf's is the empty ground behind a cover grid.
A photograph cannot equal a background, so that point compares nothing. It is
left in place and named here rather than quietly moved to a spot that would
agree — the honest version of "looks like Selector" is *the chrome is the same
colour, and the content is the content*.

**What each shot shows, having looked at it:**

- **`welcome.png`** — centred column, amber primary button, quiet dark ground:
  Selector's welcome screen with Shelf's words in it. One real defect: the
  shortcut line squeezes five hints into one row, so three of the five labels
  wrap onto two and three lines ("Open / Library…", "Move / through the /
  grid"). It is ragged and it is the first thing a new user reads. The line is
  `SlateShortcutLine`, so the fix belongs in SlateKit. The app icon is still the
  system placeholder (`AppIcon.appiconset` is empty — `docs/BACKLOG.md`). The
  three greyed recent libraries with a "?" are correct: they no longer exist.
- **`library.jpg`** — the three columns at Selector's proportions, five columns
  of covers with captions, the selection in an amber ring. The inspector runs
  cover → title → author → RATING → DETAILS → TAGS → DESCRIPTION → FORMATS,
  which is the order CONCEPT §3.2 asks for. Nothing is cut off except the
  caption row at the scroll edge, which is what a scroll edge does. Two defects,
  both fixed in this sprint: the sidebar said "Shelves arrive in Sprint 2" while
  Sprint 2 was running, and it wrote "epub" twelve centimetres from the
  inspector's "EPUB".
- **`sidebar.jpg`** — the sidebar scrolled down, which is the shot that shows
  the defect the row cap fixes: AUTHORS now stops after twelve names with
  "+ 85 more — use ⌘F", and SERIES (nine series with counts), FORMATS and
  DEVICES are on screen behind it. Before the cap they were about a thousand
  points below the fold. The library's own row stays pinned above the scroll
  area with its amber tint, as Selector's collection header does.
- **`import-sheet.jpg`** — the counting protocol before anything is copied:
  "120 skipped · 0 B", the four counters at zero, the reason ("already in the
  library (identical file)") and the sentence that the source is only read. The
  primary button reads "Nothing to Import" and does nothing, which is the honest
  label for that state. A centred overlay panel over a dimmed window — Selector's
  idiom, not a system dialog.
- **`selector-reference.jpg`** — Selector itself, and it answered two design
  questions for this sprint rather than only confirming colours: its tag control
  is a rounded field reading **"Add tag… (T)"** with the chips *beneath* it, and
  its note control is the same shape reading **"Add a note… (N)"**. That is the
  shape Shelf's tag and description fields take, so 2b copies a decision instead
  of inventing one. It also settles a suspicion from the first Shelf shot: the
  blue Inspector toggle in the toolbar is Selector's own look, not a Shelf
  inconsistency.

One observation that is data and not a defect: **"Unread" reads 120 of 120**,
because a freshly imported EPUB carries no read status — `shelf:read` is Shelf's
own field and the file has never had one. Correct, and it makes "Unread" useless
as a subject for a screenshot until something has been marked read.

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

| | layer-0 windows | of those, on screen | windows the accessibility API reports |
|---|---|---|---|
| Shelf, library open | 5 | 1 | **1** |
| Selector, no window open | 5 | 0 | 0 |
| **Selector, one document window open** | **6** | **1** | — |

Four of those windows are **1512 × 33 at (0, 0)** and never on screen, and every
app has them: they are the system's menu bar, not the app's. Selector with a
window open — "372_FUJI — Selector", 1400 × 861 — reports those four, its
window, and one more 500 × 500 panel: **six**, which is exactly the number Shelf
was suspected for. Shelf reports **five**, one fewer than a shipping app that
works.

Three quit-and-relaunch rounds and three kill-and-relaunch rounds stayed at one
window; the "six, growing by one per launch" was restored window state from a
saved-state folder that no longer exists and did not come back. The script and
the smoke test say so now, so the next reader does not have to find it again.

Selector was only ever read. The instance that was running when this session
started is still running, untouched.

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
