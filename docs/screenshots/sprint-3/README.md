# Sprint 3 – the Calibre import at the window

Taken by `Scripts/calibre-shot.sh`, which drives the real window: File ▸ Import
from Calibre…, the open panel, the counting protocol, the Import button, and
then the inspector of a book that came across. Against the five-book fixture
`shelf-tool calibre-synthesise` writes, at 1440 × 877.

The command line proves the same import against 2 000 books; these prove the
*window* shows it, which is the claim CONCEPT §7.3 actually makes.

## `calibre-sheet.jpg` – before a byte is copied

The plan on top — `4 new books · 23.8 KB` — and under it what is *in the
Calibre library*, which is a different question:

    Books                                    5
    Authors                                  3
    Series                                   2
    Tags                                     3
    #read_date                            Date
    #owned                              Yes/No
    #shelf_note                           Text
    #pages                              Number
    #mood            unknowable – not imported
    Listed in metadata.db, not on the disk    1
    On the disk, not in metadata.db           1
    Without a cover                           1

Five books and four new ones, because one book's file is listed in
`metadata.db` and is not there. The custom column of a kind this Shelf has never
heard of is named in `Slate.deny` with the sentence that matters — *Everything
else is imported* — rather than stopping anything.

`Nothing in the Calibre library is changed, moved or deleted.`

## `calibre-report.jpg` – afterwards

`Verified · 4 files · 4 new books`, `Copied 23.8 KB`, `Imported with something
missing 1` (the book Calibre has no cover for), and where the full report is.
The sidebar has gone from 120 books to 124, from 97 authors to 99, from 9 series
to 10.

## `calibre-inspector.jpg` – one of the imported books

Everything Calibre knew: *Le Guin, Ursula K.*, `Hainish Cycle 1`, **Book 1 of
4**, one star (Calibre's 2 of 10), *Gollancz*, `2019-04-01`, `eng`, added
**1 Jan 2024** — Calibre's own timestamp, not today — and the ISBN.

Below that, `FROM CALIBRE`:

    Date read     1. Nov 2023
    Owned         Yes
    Note          A note about book 1
    Pages         101

Each one carries `#read_date · Date · imported from Calibre, not editable`.
**Stored** as the canonical form (a date is a full ISO-8601 stamp, because that
is what goes into `metadata.opf` and has to come back out unchanged) and
**shown** in the reader's own region. The first version of this shot read
`2023-11-01T00:00:00+00:00`, which is a value a machine is pleased with.

Two of the five books are not in the grid: the one whose file is missing, and
the search is filtered. *Synthetic Book 4* shows the no-cover placeholder, which
is the fixture's coverless book arriving as one.

### What these shots caught that nothing else did

The inspector showed **no** Calibre section at first, and nothing had failed:
the values were in every book's `metadata.opf` and in the index. `LibraryModel`
wrote its own, older `library.json` back after the import, over the one the
import had just written — taking the columns' *names* with it. The values had
nowhere to be shown from. `runImport` re-reads the descriptor now instead of
writing a cached copy back.
