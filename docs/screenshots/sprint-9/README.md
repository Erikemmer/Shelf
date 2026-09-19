# Sprint 9 screenshots — changing a cover

Taken by `Scripts/cover-shot.sh` against the seven-book library
`Scripts/cover-library.sh` builds, plus — for the two download pictures — the
twelve-book library `Scripts/online-library.sh` builds, whose books carry real
ISBNs. 19 September 2026, window at 1440 × 877 — first at commit `c4fd660`,
then again after the redo fix (`13-after-redo.jpg`, `13-edit-menu.jpg`) at the
head of this branch. **English here and German in `de/`** — the same script
run twice, with `SHELF_SHOT_LANGUAGE=de` picking the German names out of one
table (`Scripts/app-language.sh`).

**Every claim under a picture was checked against the disk, not against the
picture.** The run reads the book's folder and its `metadata.opf` after each
step and fails if the bytes, the pixel size or the generation are not what they
should be — because a screenshot of a window drawing a cached thumbnail looks
exactly like a screenshot of a window drawing the right file. The numbers below
are the run's own output.

**Looking at them found two defects that no test had** (the grid cell after
⌘Z, and the German field labels in the download sheet), both fixed in
`c4fd660` and both described where they were found. A third — ⇧⌘Z landing on
the wrong stack — was found by suspicion and a manual check before any
screenshot existed for it; `13-after-redo.jpg` and `13-edit-menu.jpg` are that
proof, added afterward.

---

## `1-cover-before.jpg` — what the menu offers

The three ways in, under the picture: **Set Cover…**, **Take Cover from Book
File** with a submenu arrow, and — after a divider — **Download Cover…**. The
menu is on the cover and not in the menu bar on purpose: a cover belongs to one
book, and the inspector is the one place in this window that is unambiguously
about one book.

*Judgement:* right. The divider does its job — the first two write from
something already on this Mac, the third goes to the network.

## `2-format-submenu.jpg` — which format the picture comes out of

This book is an EPUB, an AZW3, a MOBI **and** a PDF, and those carry four
different pictures. So it asks. A book with one format gets a plain item and no
question.

*Judgement:* right, though the submenu opens to the *left* because the
inspector is against the right edge of the window. That is macOS placing it,
not Shelf.

## `3-from-book-file.jpg` — the cover out of the PDF

`Take Cover from Book File ▸ PDF` → page 1 rendered. **Measured: `cover.png`,
666 × 1000, 18 KB, generation 1.** 1 000 px is `PDFFileReader.coverPixels`, and
`CoverImageRule` leaves it alone because it is under the ceiling and PNG is a
name a book folder can hold.

*Judgement:* right. The grid cell and the inspector both changed to the new
picture at once, which is the whole point of the generation.

## `4-file-panel.jpg` — the file chooser

**Cropped**, and the reason is a rule rather than taste: a sandboxed open panel
draws the *machine's* own Favorites down its left side, and one of the folders
on this Mac carries the former company name, which CLAUDE.md says appears
nowhere in this project. The panel is a remote view, so its sidebar cannot be
collapsed from here and its parts cannot be located and blanked — cropping is
the only reliable answer.

*Judgement:* right, and it shows something nobody set out to photograph:
**`not-a.txt` is greyed out**. That is `CoverImage.accepted` reaching the panel,
so the commonest mistake is not even offered.

## `5-cover-after.jpg` — Set Cover… with a 3 200 × 4 800 picture

**Measured: `cover.jpg`, 1 067 × 1 600, 46 KB, generation 2** — from a 271 KB
PNG. The ceiling (`CoverImageRule.maxEdgePixels`, 1 600) did its work and the
picture was written again as JPEG.

*Judgement:* right. Whether 1 600 px is the *right* ceiling is a judgement
about how covers look on a large display, and it is one for Erik — it is one
constant in one place (`docs/HANDOFF.md`).

## `6-after-undo.jpg` — ⌘Z

Back to the PDF's page 1, byte for byte. **Measured: `cover.png`, 666 × 1000,
18 KB, generation 3** — the generation counts *up*, never back, because it is a
counter and not a value. The Edit menu reads **Undo Cover**.

*Judgement:* right now, and **this picture is where the first defect was
found.** Before the fix, the inspector showed the restored picture and the grid
cell beside it still showed the replaced one. `applyCover` writes the
generation before the picture, and writing it is what invalidates the view, so
the cell woke while the old file was still on disk and was never woken again.
The grid now watches `coverRefreshRequest`, which is bumped once everything is
done. Nothing but looking at two pictures side by side would have caught it.

## `13-after-redo.jpg` and `13-edit-menu.jpg` — ⇧⌘Z

**Added after the run above — ⇧⌘Z did nothing for a cover until this fix.**
The cause: `applyCover` registered the redo from inside `Task { await
model.applyCover(...) }`, which returns before that registration ever runs, by
which time AppKit's `isUndoing` has already gone back to false. Every redo
landed on the *undo* stack instead of the redo stack; the Edit menu read a
disabled "Redo", and a second ⌘Z replayed the change forward again rather than
doing nothing or a real redo. Fixed by registering synchronously, exactly
where the metadata path already does it (`apply(_ change:)`).

`13-after-redo.jpg` is not distinguishable from `5-cover-after.jpg` by the
picture alone — a redo that lands on the wrong stack still shows the right
picture the *first* time. **Measured: `cover.jpg`, 1 067 × 1 600, 46 KB,
generation 4** — the same file and pixel size `5-cover-after.jpg` reports, and
the run asserts they match rather than trusting the screenshot.
`13-edit-menu.jpg`, cropped from the same moment, is what actually tells the
two apart: **Undo Cover**, enabled; **Redo**, disabled — the alternating
pattern a working undo/redo stack produces, not the "Redo" that stayed
enabled and kept replaying forward under the bug.

**The Trash grows by one on every ⌘Z and every ⇧⌘Z, not only on the first
replacement.** Undo and redo are not special: each one goes down
`applyCover` like any other change, and every write of a cover displaces
whatever was there through `FolderDisposal` — never `removeItem`. Measured
this run: **246 → 247 items** across one round trip (undo, then redo). A
library where covers are set and undone often will have a Trash that
remembers every one of them; that is `FolderDisposal`'s whole point — a
person can look in the Trash and get any of them back — not a defect in
this feature.

*Judgement:* right, and this is the picture that proves it rather than
merely showing it.

## `7-not-an-image.jpg` — a text file dropped on the cover

The refusal under the menu: *"That is not an image Shelf recognises, so nothing
was written."* **Measured: the folder is byte for byte what it was.**

*Judgement:* right. The sentence says what happened *and* what did not, which
is the half most error messages leave out.

## `8-dropped.jpg` — a picture dragged from the Finder

**Measured: `cover.png`, 600 × 900, 21 KB, generation 4** — under the ceiling
and a format the folder can name, so it was written **byte for byte**, not
re-encoded.

*Judgement:* right.

## `9-first-cover.jpg` — a book that had no cover at all

`Take Cover from Book File` on a book whose cover had been taken away.
**Measured: `cover.png` appears, and the sidebar's `Missing Cover` goes 2 → 1.**
⌘Z afterwards takes the file away again and puts the count back to 2 — the run
checks both.

*Judgement:* right, and the sidebar count is the part worth having photographed:
it is answered from the *folders* and not from the cover cache, which is a
defect this project already paid for once (`CoverFile.booksWithACover`).

## `10-replace-cover.jpg` — Download Cover… over a cover that is already there

The picture this sprint's one reversed decision hangs on
([ADR 0020](../../adr/0020-a-cover-may-be-replaced-and-what-guards-it-instead.md)).
Sprint 6 refused this outright. What replaces the refusal is in this one frame:
the book's current cover in the inspector on the right, what would replace it
previewed in the middle, and a button that says **Replace Cover** rather than
*Use This Cover*.

*Judgement:* right, and the honest reading is that the *preview* does the work,
not the button. Erik should say whether the wording warns him enough — it is in
`docs/HANDOFF.md` as a question, not as a decision.

**"Google Books answered 429."** is at the bottom, as it has been for every
request this project has ever made. So this is Open Library alone; the
two-services-disagreeing case still has never been photographed.

## `11-downloaded.jpg` — and after pressing it

**Measured: `cover.jpg`, 330 × 500, 79 KB, generation 1.** The grid cell, the
inspector and the sheet's own preview all show the 1949 jacket, and the note
reads *"Saved as cover.jpg next to the book."*

*Judgement:* right.

## `12-after-restart.jpg` — the app quit and started again

The claim the whole `coverGeneration` field exists to make. Quit, relaunch,
look: the downloaded jacket is in the grid and in the inspector.

*Judgement:* right. **`Library ▸ Rebuild Index from Folders` was checked by
hand and is not in this set** — the index was thrown away and rebuilt from the
folders, the cover stayed, and `sqlite3` reported `cover_generation = 1` with
migration `v3-cover-generation` applied. It is not scripted here, so treat it as
measured once rather than as measured every run.

---

## What these pictures do **not** show

- **The picture half has no tests.** `CoverImage` needs ImageIO, and
  `ShelfCoreTests` is the only test target this project has and it runs on
  Linux. The pixel sizes quoted above are this run reading the disk — they are
  evidence, not a regression test. An app-side test target is the honest fix
  (`docs/BACKLOG.md`).
- **HEIC and TIFF were never set as a cover here.** The rule that transcodes
  them is tested (`CoverImageRuleTests`); the transcoding is not, and no HEIC
  was put through the real panel.
- **No real e-reader, no real Calibre library, no genuinely DRM-protected
  file.** Unchanged from `docs/HANDOFF.md`.
- **A cover has never been replaced on a library of thousands.** Seven books
  and twelve books. Nothing here says what `.shelf/covers/` does when somebody
  replaces two hundred covers in an afternoon.
