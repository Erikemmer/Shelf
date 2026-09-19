# Sprint 8 screenshots

Taken by `make organize-shots` (`Scripts/organize-shot.sh`) against the 16-book
library `Scripts/organize-library.sh` builds, on 19 September 2026, window at
1440 × 950, English. Each picture has an accessibility tree beside it
(`ax-*.txt`), which is what the run checks its claims against — a picture
proves a layout and a tree proves a name.

**Every one of these was looked at, and looking at them found three defects that
no test had.** They are listed under each picture and all three are fixed.

Why this library is only sixteen books: the sidebar caps each section at twelve
rows, and with thirty books the tag list alone was eleven of them, which put the
Authors section — the one the merge is opened from — *below the window*. A
right-click below the window opens nothing and says nothing about having opened
nothing, which cost two runs before the point was printed out and looked at.

---

## `merge-dialog.jpg` — Rename / Merge

One person as three authors, which is the whole reason this sprint exists: the
sidebar behind the sheet lists **S. Fitzek 3**, **Fitzek, Sebastian 3** and
**Sebastian Fitzek 3**, and the sheet lists the same three with their counts so
the mess is visible in one place for the first time.

It reads well: the explanation says what will happen *and* what will not ("It
does not move any folder — 'Organize Library…' does that, and it asks first"),
the target field is pre-filled, and the count under it is computed from the
value the button executes.

> **Found here, and fixed.** With one spelling ticked and that same spelling
> typed, the line read **"No book carries that name"** — with three books
> listed one line above it, each saying "3 books". Two quite different nothings
> were being told alike. It now reads "3 books already read that way — nothing
> to change", and `NameMergePlan.carrying` is what tells them apart.

## `organize-preview.jpg` — the preview, with what it cannot do

"8 to move · 7 already right · 1 cannot be", then every `old → new` pair. The
pairs are worth reading: `Tchaikovsky, Terry/The Dispossessed State #13 (3) →
Fitzek, S/…` is a folder still carrying the author it had before the merge,
which is exactly what ADR 0007 said would accumulate and ADR 0018 is the answer
to.

> **Found here, and fixed.** The one book that **cannot** be moved was at the
> *bottom* of a scrolling list, under eight moves, and therefore below the
> fold. The long list is the part nobody reads line by line; the short one is
> the whole reason this is a preview. What cannot be done now comes first, in
> the accent colour, with the book named.

## `organize-report.jpg` — what actually happened

"Moved · 8 folders · Already right: 7 · Could not: 1 · Failed: 0", the line
about the eight author folders the moves left empty and removed, where the full
report is, and — next to Done — **Undo Organize**.

This is the only picture in this folder taken after a button that moves
something was pressed, and `Scripts/organize-shot.sh` refuses to run outside
`~/Library/Caches/Shelf` for that reason.

Worth noticing in the background: the sidebar still shows the three Fitzek
spellings. Correct — this run moved *folders*, and the three spellings are
three authors until somebody merges them. The two commands are deliberately
separate.

## `export-dialog.jpg` — Archive

The three presets are named for the question they answer, not for their
settings, and the lit one explains itself: "Everything: the book files, the
covers and a metadata.opf each. This can be imported back into Shelf with
nothing lost."

> **Found here, and fixed.** The format row drew eight checkboxes across a
> 620-point sheet and broke the words to fit: **"EPU B"**, **"AZW 3"**,
> **"MOB I"**. Worse, they sat ticked *and* disabled while "All" was on, which
> on a dark background reads as eight controls that will not respond. "All" now
> stands alone with "every format of every book" beside it, and the individual
> boxes appear only when it is off — wrapped five to a row.

## `export-books-only.jpg` — the honest sentence

The picture this sheet exists for. "Just the books" is lit, and the sentence
under it is in the accent colour rather than the quiet grey:

> The book files alone. The rating, the read status, the tags and the shelves
> will not go with them — they live in the metadata.opf, and that is not
> written.

`cover.jpg` and `metadata.opf` have gone unticked by themselves, so the words
and the switches agree. The same sentence is written into
`Shelf-Export-Report.txt` in the exported folder, because somebody reading that
folder in five years is the person who most needs it.

---

## What no picture here shows, and why

- **The export running, and its report.** It would mean writing a second copy
  of a library to take a photograph of a progress bar. The numbers are in
  `CHANGELOG.md` and every one of them comes from `make proof` section 12.
- **The German window.** These are English (`Scripts/app-language.sh` pins it,
  and says so in the run). The strings are all in the catalogue and the
  localisation tests cover them; what a picture could add is whether the
  *layout* survives longer German words, and that is a run of its own —
  `docs/BACKLOG.md` carries it with the five sheets Sprint 7 left unphotographed.
