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

`.shelf/` can be left where it is. Calibre ignores a folder beginning with a dot.

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
  a cache of "what I put here", and a killed process does not get to update it.

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
