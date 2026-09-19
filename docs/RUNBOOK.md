# Runbook

What to do when something has to be done to a library rather than in it: back it
up, get it back, rebuild its index, move it to another drive, take it back to
Calibre, or pick up after a crash.

**Every path below was run once, by `Scripts/runbook-proof.sh`, and the output
is quoted rather than described.** Run it again after a change and the quotes
can be checked:

```
Scripts/runbook-proof.sh
```

It works inside `~/Library/Caches/Shelf/runbook-7b` and removes only what it
made there. Measured on Erik's Mac (M-series, macOS 15.6) on 19 September 2026
against a generated library of 20 EPUBs.

Like every script under `Scripts/` that opens the app, it refuses outright if
a Shelf is already running rather than trying to make it go away first
(`Scripts/no-foreign-shelf.sh`) — a script cannot tell a leftover from an
earlier run apart from a window Erik has open on purpose, and it is not its
call to guess.

---

## 1. What is the truth, and what is only a cache

This is the one thing to know before any of the rest. The **folders are the
truth**; the index is a cache that can be deleted at any time
([ADR 0001](adr/0001-folder-is-the-truth.md)).

```
the whole library folder:
5,4M	…/library
what is *only* a cache, and can be deleted at any time:
  0B	…/library/.shelf/covers
256K	…/library/.shelf/library.sqlite
 32K	…/library/.shelf/library.sqlite-shm
  0B	…/library/.shelf/library.sqlite-wal
what has to be kept:
  library.json          4,0K
  the book folders      20 of them
  a metadata.opf each   20 of them
```

| Path | What it is | Losing it costs |
|---|---|---|
| `<Author>/<Title> (n)/` | **the truth** — the book files, the cover, `metadata.opf` | the books |
| `.shelf/library.json` | **the truth** — the library's name, the shelf *shape*, the book counter, the view settings | the empty shelves and the counter; see below |
| `.shelf/library.sqlite*` | a cache — the index, FTS5, the facets | nothing; rebuilt from the folders |
| `.shelf/covers/` | a cache — decoded covers | nothing; redrawn on demand |
| `.shelf/Import-Report.txt` | a record — one block per import | the history of what was imported |

**`library.json` is the one file that is not derivable.** A shelf with no books
on it exists only there, because no book can remember a shelf it is not on
([ADR 0008](adr/0008-shelves-membership-in-the-book-hierarchy-in-library-json.md)),
and so does `nextBookNumber`. Everything else in it — which books are on which
shelf — is also written into each book's `metadata.opf`, which is what lets the
index be thrown away.

---

## 2. Back up

Copy the library folder and leave out the two things that rebuild themselves:

```
$ rsync -a --exclude ".shelf/covers/" --exclude ".shelf/library.sqlite*" \
    "<library>/" "<backup>/"
```

```
the backup, without the cache:
5,1M	…/backup
what is in it:
.shelf
Atwood, Adrian
Atwood, José
Atwood, Susanna
Austen, Becky
Import-Report.txt
library.json
```

5,4 MB became 5,1 MB — the cache was 256 KB of index and an empty cover folder.
On a real library the cover cache is the larger part of the saving: it is about
20 KB per book ([ADR 0005](adr/0005-cover-pipeline.md)), so a 5 000-book library
carries roughly 100 MB of it.

**The whole folder can be copied instead**, including the index, and nothing
goes wrong. The exclusions save space and avoid copying a SQLite file that may
be mid-write; the index is rebuilt in seconds either way.

**Shelf does not have to be closed.** The book files and the OPFs are only ever
written when a metadata change is made, atomically through a `.part` file, so a
copy taken while the app is open either has the old file or the new one. The
index is the exception, and it is the thing being left out.

---

## 3. Restore

Copy the backup back and rebuild the index:

```
$ cp -R "<backup>" "<restored>"
there is no index in the restored copy:
Import-Report.txt
library.json
$ shelf-tool rebuild "<restored>"
  after:  20 books
  folders with no readable book: 0
  books whose metadata came from the file rather than an OPF: 0
index and folders agree
  original: 20 books · restored: 20 books
```

In the app the same thing is `Library ▸ Rebuild Index from Folders` — or simply
opening the library, which builds an index when there is none.

---

## 4. Rebuild the index on its own

When the index is suspected — a crash, a full disk, a folder somebody edited by
hand in the Finder — throw it away and ask for it back. Nothing is at risk:
this reads the folders and writes only `.shelf/library.sqlite`.

```
$ rm -f "<library>/.shelf/library.sqlite" \
        "<library>/.shelf/library.sqlite-wal" \
        "<library>/.shelf/library.sqlite-shm"
$ shelf-tool rebuild "<library>"
  after:  20 books
  folders with no readable book: 0
  books whose metadata came from the file rather than an OPF: 0
index and folders agree
```

The last line is the check worth reading. "folders with no readable book" counts
folders the rebuild walked into and found nothing it could read; "metadata came
from the file rather than an OPF" counts books whose `metadata.opf` was missing
or unreadable, so the metadata had to be taken out of the book file — which
loses the rating, the read status, the tags and the shelves, because those exist
only in the OPF.

In the app: `Library ▸ Rebuild Index from Folders`.

---

## 5. Move to another drive

There is nothing to migrate. Copy the folder and open it where it lands.

```
$ rsync -a "<library>/" "/Volumes/OtherDrive/library/"
$ shelf-tool rebuild "/Volumes/OtherDrive/library"
  folders with no readable book: 0
  books whose metadata came from the file rather than an OPF: 0
index and folders agree
```

Then `File ▸ Open Library…` and choose it there. Two things to know:

- **The old library stays in `File ▸ Open Recent`** and is greyed out while the
  drive it was on is unplugged, rather than disappearing. That is deliberate:
  seeing that a library is on a drive that is not connected is useful.
- **A library in iCloud Drive is opened with a warning.** SQLite in a synced
  folder is a known problem (CONCEPT §12). Shelf detects it, says so, and opens
  it anyway.

---

## 6. The way back to Calibre

Nothing has to be exported, because the layout **is** Calibre's: one folder per
author, one folder per book inside it, the book files and a `metadata.opf`
beside them.

```
the folder tree Calibre's “Add books from directories” walks:
…/library/Banks, Jane/The Long Way #7 (8)
…/library/Atwood, Adrian/The Ministry Justice #16 (12)
one book's folder:
cover.png
metadata.opf
The Long Way #7 - Jane Banks.epub
and the metadata Calibre reads out of it:
    <dc:title>The Long Way #7</dc:title>
    <dc:creator opf:role="aut" opf:file-as="Banks, Jane">Jane Banks</dc:creator>
    <dc:identifier id="uuid_id" opf:scheme="uuid">3922C84C-…</dc:identifier>
```

In Calibre: **Add books ▸ Add books from directories, including sub-directories
(one book per directory)**. Calibre reads the `metadata.opf` beside each file.

**What comes across**, because Shelf writes Calibre's own schema — Dublin Core
plus `calibre:` metas — into every OPF:

| In Shelf | In the OPF | Calibre reads it |
|---|---|---|
| title, authors | `dc:title`, `dc:creator` with `opf:file-as` | yes |
| publisher, date, language, description | `dc:publisher`, `dc:date`, `dc:language`, `dc:description` | yes |
| tags | one `dc:subject` each | yes |
| ISBN and the other identifiers | `dc:identifier` with `opf:scheme` | yes |
| series and its index | `calibre:series`, `calibre:series_index` | yes |
| rating | `calibre:rating` | yes |
| the sort title | `calibre:title_sort` | yes |
| the cover | `cover.png` / `.jpg` beside the book | yes |

**What does not**, and this is the honest part: Shelf's own three fields are
written as `shelf:read`, `shelf:shelves` and `shelf:custom`, and **Calibre
ignores a meta it does not know**. So the **read status** and the **shelves**
stay behind. They are not lost — they are in the OPF, in plain text, for
anything that cares to read them — but Calibre will not show them.

A shelf could be written as a Calibre custom column instead. It is not, because
a custom column has to be *declared* in Calibre's own database before a value
in an OPF means anything, and Shelf never writes to `metadata.db`
([ADR 0009](adr/0009-calibre-is-read-through-a-copy-of-metadata-db.md)).

**Since Sprint 8 there is a way to bring those two across as well**, and it is
the "For Calibre" export in §14. It writes the same files and *additionally*
maps each shelf to a tag Calibre does read:

| In Shelf | Also written | Calibre shows |
|---|---|---|
| on the shelf `Fiction/Sci-Fi` | `<dc:subject>Shelf/Fiction/Sci-Fi</dc:subject>` | a hierarchical tag `Shelf → Fiction → Sci-Fi` |
| read | `<dc:subject>Read</dc:subject>` | the tag `Read` |

It is a **mapping and not the fields**: Shelf's own `shelf:read` and
`shelf:shelves` are written beside the tags, not instead of them, so the same
folder still comes back into Shelf with nothing lost. Use it when the
destination is Calibre; use plain **Archive** when the destination is Shelf, or
a backup, or ten years from now.

`.shelf/` can be left where it is: it begins with a dot, and Calibre skips
hidden folders.

**One honest limit on this section.** The folder layout, the OPFs and what is in
them are quoted from a real library above, and they are what Calibre's importer
reads. What has **not** been done here is the import itself — running it would
mean writing into Erik's own Calibre library, which is not this project's to
touch. The claim is that Shelf writes Calibre's schema, and that is checked by
`Tests/ShelfCoreTests/OPFDocumentTests.swift` and by the Calibre *reader*, which
reads back what Calibre writes. The last step is Erik's to try.

---

## 7. A crash in the middle of an import

**Nothing is lost and nothing at the source is touched.** Run the same import
again; it resumes.

```
the import was killed after six seconds. What it left:
  book folders on disk: 1
the same import again, which resumes rather than starting over:
index holds 400 books
```

The resume works by UUID and file digest: a book already in the library is
recognised and skipped, and a folder the killed run left behind is *adopted*
rather than duplicated (`OrphanedFolders`, Sprint 4). Before that fix an
interrupted import copied up to a batch of books twice; the test that pins the
old behaviour is still there, named "without adoption the same resume doubles
the folders – the defect, pinned".

---

## 8. Folders no book points at

After a crash, or after something was moved in the Finder, ask:

```
$ shelf-tool orphans "<library>"
books in the index: 400
orphaned folders: 0
  (every folder in the library belongs to a book)
```

In the app: `Library ▸ Find Orphaned Folders…`. It **only looks**. The sheet
names every file before anything can move, and what moves goes to the Trash
rather than being deleted.

A killed import now leaves none, which is what the run above shows. The command
is still worth knowing, because a folder edited by hand in the Finder is the
other way to make one.

---

## 9. A crash in the middle of a transfer to a device

This is the one path with a rough edge, and it is quoted in full because the
numbers are the point.

```
before anything is sent:   0 book files · 0 .part · 0 in the manifest
killed after one second:   9 book files · 1 .part · 0 in the manifest
the same transfer again — every file is hashed on both sides before it counts:
Verified · 11 books · Skipped: 0 · Failed: 9
took 2 s
  FAILED Children We Became #8: a file of that name is already on the device
  FAILED Red Called Peace #17: a file of that name is already on the device
  … seven more of the same
manifest on the device: 11 files
afterwards:                20 book files · 0 .part · 11 in the manifest
```

**How many is 9 depends on the second the run was killed in** — a second run
read 8 and 12. The three numbers that do not vary are the ones that matter: no
`.part` survives, nothing is lost, and the manifest is short by exactly the
number the killed run had written.

Read that carefully, because the word "Failed" is alarming and the situation is
not:

- **Nothing was lost.** All 20 books are on the card. The nine that "failed" are
  the nine the killed run had already written.
- **The half-written file was swept up.** One `.part` before, none after: the
  runner removes its own `.part` files and nothing else
  ([ADR 0002](adr/0002-copy-verify-then-trust.md)).
- **The manifest is behind.** It holds 11 of the 20, because the killed run was
  stopped before it could record what it had written. Shelf's device manifest is
  a cache of "what I put here" and is written **every twenty files**
  (`TransferRunner.manifestBatchSize`), so a process that dies without warning
  can leave up to nineteen files on the card that no manifest knows about.

  A transfer that is *stopped* rather than killed — the Cancel button, or the
  `shelf-tool` exit the proof run uses — writes the manifest on the way out and
  resumes cleanly: `Skipped: 40 · Failed: 0` in `Scripts/proof-run.sh` section
  11. It is the untidy death that leaves the gap, which is to say a crash, a
  power cut, or a cable.

**What to do:** nothing, if the books being on the card is all that matters. The
nine show up in `Device ▸ Show What Is on the Device…` anyway — that view scans
the card and matches by name where the manifest has nothing to say — and the
grid's device badge finds them the same way.

**To make the card tidy again:** select those nine in `Device ▸ Show What Is on
the Device…`, delete them (the confirmation names every file —
[ADR 0014](adr/0014-deleting-on-a-device-needs-a-named-confirmation.md)), and
send them again. They will then be in the manifest.

**What is written down as a defect** rather than as a fact of life:
`docs/BACKLOG.md`, Sprint 5 — a resumed transfer should recognise a file it
wrote itself and skip it quietly instead of reporting nine failures.

---

## 10. Where the reports and the logs are

**Per library, `~/…/<library>/.shelf/Import-Report.txt`.** Appended to, one
block per import, never overwritten:

```
  formats added to existing books: 0

Imported with something missing: 1
  Vol. 1 2 Gideon Called Peace and the Very Long Subtitle…: no cover in the file

Nothing at the source was changed, moved or deleted.
```

**The app's own log goes to the unified log, not to a file.** It is quiet on
purpose: `notice` and above, plus one `error` for every message the window
shows. So there is something to read only when something has gone wrong.

```
$ log show --last 1h --predicate 'subsystem == "de.erikemmer.shelf"' --info
```

The proof run provokes one, by opening a library whose `schemaVersion` is 99:

```
2026-09-19 08:47:56.540756+0200  Error  Shelf: [de.erikemmer.shelf:library]
Es war nicht möglich, „from-the-future“ zu öffnen: sie wurde von einem neueren
Shelf geschrieben (Format 99; dieses liest 1). Aktualisieren Sie Shelf, um sie
zu öffnen.
```

The categories are `library`, `cover-cache`, `online` and `timing`. To watch one
of them live:

```
$ log stream --predicate 'subsystem == "de.erikemmer.shelf" && category == "library"'
```

`SHELF_TIMING=1` in the environment turns on the `timing` category, which is how
"852 ms cold, 768 ms warm" in `CHANGELOG.md` was measured.

**There is no crash log to look for beyond the system's own.** A crash lands in
`~/Library/Logs/DiagnosticReports/Shelf-*.ips` like any other app's.

---

## 11. Shelf refuses to open a library

Three refusals, all deliberate, all with the same shape: it says what happened
and what to do.

| What it says | What it means | What to do |
|---|---|---|
| "…is not a Shelf library. Use New Library… to make one there." | the folder has no `.shelf/library.json` | open the right folder, or make a library there |
| "it was written by a newer Shelf (format 99; this one reads 1)" | `schemaVersion` is higher than this build understands | update Shelf. **Do not** edit the number down: a newer Shelf may hold fields this one would drop on the next write |
| "the index of “…” could not be opened (…). The books are safe – the index can be rebuilt from the folders." | `library.sqlite` is corrupt or locked | §4 above |

---

## 12. The one thing Shelf never does

It never writes, deletes or overwrites a **book file** (CONCEPT §4). Every path
in this runbook is a copy, a read, or a write to `metadata.opf` and the index.
If a path ever seems to need a book file changed, it is the wrong path.

---

## 13. Tidy the library up

Two commands, and the order matters: the first changes what the books *say*,
the second changes where they *are*.

### Spellings: one person, one name

Right-click an author, a series, a publisher or a tag in the sidebar →
**Rename…** or **Merge into…**. Tick every spelling that is the same thing,
type the one they should all have, and press the button. The count under it is
computed from the very value the button executes.

```
$ shelf-tool names <library> author
36 authors
  14	Sebastian Fitzek
  13	Fitzek, Sebastian
  13	S. Fitzek
$ shelf-tool merge <library> author "Sebastian Fitzek" "Fitzek, Sebastian" "S. Fitzek"
plan: 26 books · 2 spellings · → “Sebastian Fitzek”
Merge Authors: 26 books · 0 s
no folder was moved — that is `organize`
```

**Shelf proposes nothing.** There is no "we found 12 probable duplicates":
which spellings are one person is a decision, and
[ADR 0018](adr/0018-renaming-merging-and-organising-are-deliberate-operations.md)
says why it is not this program's to make.

It writes one `metadata.opf` per book and one index row per book, as **one**
step on the undo stack — ⌘Z puts all 40 back. It does **not** move any folder,
and it offers to afterwards: *"40 books changed — tidy the folders now?"*

### Folders: `Library ▸ Organize Library…`

The preview first, always. It shows every `old → new`, how many are already
right, and everything it cannot touch.

```
$ shelf-tool organize <library>
volume folds case: yes
plan: 202 to move · 4794 already right · 2 cannot be
  Atwood, Adrian/Piranesi #34 (8)
    → Fitzek, Sebastian/Piranesi #34 (8)
  …
  something is already there, and it is not empty: 2
nothing was moved — add --run
```

Then, and only then:

```
$ shelf-tool organize <library> --run
Moved · 202 folders · Already right: 4794 · Could not: 2 · Failed: 0
```

What it guarantees, and what each one is worth knowing:

- **Folders move; the bytes inside them do not.** Every folder is hashed before
  the move and again after, and a folder whose contents differ is put straight
  back and named in the report.
- **Nothing is overwritten and nothing is deleted.** The one folder it touches
  at all is an author folder the run itself has just *emptied* — "Atwood,
  Adrian", after its last book moved to "Fitzek, Sebastian" — and that goes to
  the **Trash**, where you can drag it back out. Each one is named in the
  report. A folder still holding anything of yours is left exactly where it is;
  the only things it will ignore are the file system's own leavings
  (`.DS_Store`, `.localized`, Spotlight's, `Thumbs.db`), because a folder the
  Finder has once been looked into is not a folder somebody put something in.
- **It can be interrupted.** A manifest is written every twenty moves and
  immediately before the one move that has a halfway state. Run it again and it
  picks up.
- **There is a way back**, and it survives a crash because it is a file rather
  than the window's undo stack: `Undo Organize`, or `shelf-tool organize-undo`.

**A setting, off by default:** *Shelf ▸ Keep Folders in Step with Metadata
Changes*. Off, because a path can be referenced from a script, a hardlink
backup or a Finder alias, and somebody who has those must not be surprised. On,
a metadata change *offers* an organise — it still never moves a folder inside
a keystroke.

### If a run was killed

Nothing is lost and there is nothing to repair by hand. The folders are the
truth, so every book is findable at whichever path it is at, and a rebuild
finds them all:

```
$ shelf-tool organize <library> --run
25 books were already at their new folder — the index says so now
plan: 34 to move · 26 already right
Moved · 34 folders · Already right: 26 · Could not: 0 · Failed: 0
```

The first line is the repair: a run killed between two index writes leaves
books at their new folder while the index still says the old one. That is the
*cache* being wrong, and it is put right before anything else is decided — by
the UUID in each `metadata.opf`, never by title.

---

## 14. Export, and back again

**What the library is worth is not the book files.** The ratings, the read
status, the tags and the shelves are only in `metadata.opf` — never inside a
book file, because a book file is never written. So the whole question of an
export is whether the OPFs come with it.

`File ▸ Export Library…` (or *Export Selected Books…*), three presets:

| | What it is for | What it writes |
|---|---|---|
| **Archive** | keeping it, backing it up, moving to another Mac | the books, the covers, a `metadata.opf` each |
| **Just the books** | handing somebody files who has no Shelf | the book files, and nothing else |
| **For Calibre** | going back to Calibre without losing the shelves | Archive, plus the mapping in §6 |

**"Just the books" says what it costs, before anything is pressed** — in the
dialogue and again in the report written into the folder:

```
NOT in this export, because no metadata.opf was written:
  the rating, the read status, the tags and the shelves.
  They are in the library's own OPFs and nowhere else.
```

### Getting it back

An archive is a library. Import the folder and everything returns:

```
$ shelf-tool export <library> <folder> archive
preset: Archive
plan: 4996 books · 14988 new · 1.3 GB to write
Written · 14988 new · 0 changed · 0 unchanged · Failed: 0

$ shelf-tool import <folder> <a new, empty library>
shelves registered before the books: 20
index holds 4996 books

$ shelf-tool compare <library> <the new one>
books: 4996 and 4996
compared by UUID: 4996
the two libraries agree on titles, authors, ratings, read status, series, shelves and tags
```

In the app it is `File ▸ Add Books…` on the exported folder, or dropping it on
the window. The import reads each `metadata.opf` and takes its word for
everything, the UUID included — which is what makes it come back as *the same
library* rather than as a new one holding the same files.

### Running it again

The same folder, a second time, writes only the differences:

```
plan: 4996 books · 37 new · 4 changed · 14947 unchanged · 12.1 MB to write
```

It compares the library against a manifest at the destination
(`.shelf-export.json`); it never reads the exported files to find out what a
book is. An exported OPF you have edited is a copy, and the next export
overwrites it: this is an export, not a sync.

A book whose title has changed has a new file name, and the file under the old
name is **taken away** — otherwise the folder holds the book twice and the
older copy wins the next import. Only files the manifest names, only at the
size it wrote them; anything you have changed is left alone and named in the
report.

### Two copies, one on the disk

On the same volume, tick **Hard links where possible**. A link costs a
directory entry and no bytes, which is what makes archiving a large library
something you will actually do. It is safe here because Shelf never writes a
book file, so the two names cannot come to differ.

```
EPUBs in the library: 4996 · in the export: 4996
distinct inodes across both: 4996
```

**It is not a backup.** One copy of the bytes with two names: a disk failure
takes both. Across a volume boundary it is a copy, without asking, because a
link cannot cross one.
