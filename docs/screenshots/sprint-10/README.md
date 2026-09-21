# Sprint 10, Schritt E2 screenshots — writing into a book's own file

Taken by `Scripts/write-into-book-shot.sh` against the five-book library
`shelf-tool epub-write-fixture` builds. 21 September 2026, window at
1440 × 877. **English here and German in `de/`** — the same script run
twice, with `SHELF_SHOT_LANGUAGE=de` picking the German names out of one
table (`Scripts/app-language.sh`), the way Sprint 9's cover screenshots do.

**Every claim under a picture was checked against the disk, not against
the picture.** The run reads the book's own EPUB after the write and
fails if the field it asked for is not actually there — a screenshot of a
sheet that says "1 book was written into" looks exactly the same whether
or not the file on disk agrees with it. `2-confirmation.jpg` and
`5-after.jpg` are of the same book, "The Glass Almanac", before and after;
`unzip -p … OEBPS/content.opf | grep …` is what the run trusts, not the
window.

**What the fixture is**: `shelf-tool epub-write-fixture` (`Sources/shelf-
tool/main.swift`) builds three ordinary synthetic EPUBs, one announcing
Adobe DRM (`SyntheticEPUB.withAdobeDRM`), and one hand-built EPUB with a
`dc:creator` but no `dc:title` element at all — the one real case
`EPUBOPFPatch` never invents a title for. One ordinary book, "The Glass
Almanac", is then edited in Shelf: a publisher, a language, a published
date and a description its own file does not have yet. Synthetic only, and
built fresh on every run — no borrowed book, ever (`CLAUDE.md`).

**Found taking these, not before**: the inspector's `ScrollView` does not
answer `AXScrollToVisible` — tried, on the theory that a control found by
the accessibility API but scrolled out of the window could be scrolled
into view before being clicked. It is a genuine no-op for this SwiftUI
view, and the fix in the end was `Scripts/scroll-at.swift`, already in the
repository for exactly this reason. Recorded here because the next script
that needs to click something at the bottom of a long inspector will hit
the same wall.

---

## `1-menu.jpg` — what the button offers

"The Glass Almanac", already edited in Shelf with a publisher, a language,
a date and a description its own file does not have. The command sits at
the bottom of the inspector's **Formats** section, beside *Open in Default
App* and *Show in Finder* — not in the menu bar, for the reason the cover
commands aren't either (Sprint 9): this is about one book, or a selection,
never the whole library.

*Judgement:* right. Offered here because `EPUBWrite.isEligible` says so —
an EPUB, no DRM — and nowhere else does that check happen twice.

## `2-confirmation.jpg` — the confirmation, old beside new

Every field `EPUBOPFPatch` can change, title to description, each with the
book's own file's current value struck through above the value Shelf
would write, or **"already the same"** when nothing would change. Title
and author are unchanged and say so; publisher, published date and
description are new and are set in bold. The explanation states plainly
what will *not* happen (PDF, MOBI and AZW3 untouched) beside what will
(the original to the Trash, no ⌘Z) — the same shape `DeleteFromDeviceSheet`
uses for the one other irreversible thing in this app.

*Judgement:* right, and the "I have read the list above" checkbox earns
its place here the same way it does there: this is Shelf's second
operation with no ⌘Z, and asking twice for one deliberate click is cheap
next to a book file that cannot be put back by pressing a key.

## `3-unwritten-field.jpg` — a field the sheet marks, not drops

"Nameless" — the one EPUB with no `<dc:title>` element in its own file at
all. Title is marked **"cannot be written"**, in the accent colour, on the
very list that shows every other field going through cleanly. This is the
one field `EPUBOPFPatch` never invents on principle (a book without a
title does not happen, in the ordinary case) meeting the one book where
that principle actually bites.

*Judgement:* right, and this is the picture the sprint's own lesson from
Sprint 10 part 2 hangs on: a field nobody can write into must never just
be absent from the list. The row is there. It is coloured differently. It
says why.

## `4-drm-refused.jpg` — the DRM refusal, in a mixed selection

A DRM-protected book offers no command **on its own** — `isEligible` says
no, and the inspector's button for it never appears at all, which is why
this is a two-book selection ("The Quiet Harbour" and "A Protected Book"),
opened from the grid's own context menu rather than the inspector. The
plan writes into the one that qualifies and lists the other under **"Left
alone"**, with the DRM message named — the fact that this book has no
individual button never mattered, because a selection is still allowed to
include it, and the sheet is where its exclusion actually gets said out
loud rather than silently skipped.

*Judgement:* right. The DRM badge is visible on the format row in the
inspector too (`Adobe DRM`), so the same fact is said twice, in two
different controls, and agrees with itself.

## `5-after.jpg` — written, the original in the Trash

**Measured: `OEBPS/content.opf` inside the book's own file now holds
`<dc:publisher>Erik &amp; Erik Press</dc:publisher>`** — read directly out
of the new EPUB after the sheet closed, not assumed from the sheet having
said so. The sheet's own report: *"1 book was written into. No ⌘Z for
this. Each original is in the Trash and can be dragged back from there."*
The inspector on the right already shows the book's new size and its new
publisher, date, language and description — the same file the grid cell
points at, reread.

*Judgement:* right, and the wording is deliberate: not "Done", not "OK" —
a sentence that says what happened and repeats, one more time, that there
is no ⌘Z. Two sentences a person could miss the first time and still catch
the second.

---

## What these pictures do **not** show

- **No real library, no real DRM, no borrowed book.** The DRM book only
  *announces* Adobe DRM (`META-INF/encryption.xml`, unencrypted text
  behind it) — exactly what `CoverReplacementTests`' and
  `EPUBFileReplacementTests`' own fixtures do, and for the same reason
  (CONCEPT §12, CLAUDE.md).
- **No author added or removed.** `EPUBOPFPatch.Failure.authorCountMismatch`
  refuses that case outright; it has a test (`EPUBWriteTests`) but no
  screenshot, because the sheet's answer to it is the same "Left alone"
  shape `4-drm-refused.jpg` already shows for a different reason.
- **No batch of more than two books.** `EPUBWrite.run`'s own sequential
  guarantee — one book at a time, never a `TaskGroup` — is proven in
  `EPUBWriteTests` and in `shelf-tool epub-file-replace-proof` against all
  six real Gutenberg books, not photographed here; a screenshot of a
  progress bar moving from 1 to 2 says nothing a test does not already say
  better.
- **No identifiers.** `EPUBOPFPatch.Fields.identifiers` exists and is
  tested; the sheet does not show ISBNs and ASINs in its own list, on
  purpose, to keep six fields readable in one picture rather than a dozen.
