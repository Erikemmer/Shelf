# Sprint 10, Schritt E2 screenshots — writing into a book's own file

Taken by `Scripts/write-into-book-shot.sh` against the five-book library
`shelf-tool epub-write-fixture` builds. 21 September 2026, window at
1440 × 877. **English here and German in `de/`** — the same script run
twice, with `SHELF_SHOT_LANGUAGE=de` picking the German names out of one
table (`Scripts/app-language.sh`), the way Sprint 9's cover screenshots do.

**Re-shot 22 September 2026** after a review of these very pictures found
four things wrong with the sheet itself, not the screenshots: a write that
would change nothing was still offered; the title row on `3-unwritten-field`
showed the same value twice with no explanation; two lines per field said
nothing about which was old and which was new; and two sentences in the
explanation read wrong ("beschrieben" reads as "described" in German, and
the Trash sentence sounded like a consolation rather than a limit). All four
are fixed in `WriteIntoBookSheet.swift` and `EPUBWrite.swift`, with tests, and
every picture below reflects the fix. Details in `CHANGELOG.md`.

**Re-shot again, same day**, after Erik asked three follow-up questions about
that first correction. Whether the title fix's fallback bug had a twin at
the author field: it did not need a second fix — `EPUBMetadata.read` guesses
an author from the file name the same way it guesses a title, a few lines
below, and the one `fallbackTitle: ""` already silenced both; a new test
(`EPUBWriteTests`) proves it rather than assuming it. Whether the "Nothing
to write" button actually looks disabled: it did not — `.disabled` alone
left it the same blue as the enabled button in `2-confirmation.jpg`, found
by looking at `3-unwritten-field.jpg` next to it, and an explicit `.opacity`
now dims it for real. And whether the counted "several books would not get
a new EPUB file" sentence, never rendered before, actually reads right in
both languages, plural included: `6-several-unchanged.jpg` is that check.

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
date and a description its own file does not have yet. A second book, "The
Quiet Harbour", gets one field of its own — a publisher — for a reason the
22 September fix itself created: once a book with nothing to write is
correctly left alone, "The Quiet Harbour" being *un*edited would have had
nothing to write either, and the DRM screenshot needs one book in the
selection that actually gets written next to the one that is refused.
Synthetic only, and built fresh on every run — no borrowed book, ever
(`CLAUDE.md`).

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

Every field `EPUBOPFPatch` can change, title to description, one line each:
"Not set → Erik & Erik Press", the old value, an arrow, the new value in
bold — never two stacked lines with nothing to say which is which. A field
that would not change shows one value only and says **"already the same"**,
off to the side, rather than repeating that value in a second, pointless
line. The explanation states plainly what will *not* happen (PDF, MOBI and
AZW3 untouched) beside what will (the current EPUB file to the Trash, no
⌘Z, and that getting it back afterwards is on whoever needs it) — the same
shape `DeleteFromDeviceSheet` uses for the one other irreversible thing in
this app.

*Judgement:* right, and the "I have read the list above" checkbox earns
its place here the same way it does there: this is Shelf's second
operation with no ⌘Z, and asking twice for one deliberate click is cheap
next to a book file that cannot be put back by pressing a key.

**Corrected 22 September 2026:** the two-line "old above new" layout was
replaced with one line and an arrow, because it never said which value was
which — somebody had to infer "top is old" from position alone. The
explanation's two sentences were also reworded: "written into" reads as
"beschrieben" in German, which is genuinely ambiguous with "described"; and
"not away for good, but there is no ⌘Z for this" read as a consolation
where a limit was meant. Both are named findings in this same review, not
separate bugs.

## `3-unwritten-field.jpg` — nothing to write, and the one field that shows why

"Nameless" — the one EPUB with no `<dc:title>` element in its own file at
all, and, in this fixture, a book Shelf never edited either: every field it
holds matches the file, except the title, which the file does not have and
`EPUBOPFPatch` will never invent. Nothing in this plan would actually
change, so the sheet says **"Nothing to write"** / **"This EPUB file would
not change."** instead of offering a write that does nothing, and the
button is disabled. The list is still shown in full underneath — title
marked **"cannot be written"**, in the accent colour, everything else
**"already the same"** — because a field nobody can write into must never
just be absent from the list; the row is there, it is coloured differently,
it says why. That is the sprint's own lesson from Sprint 10 part 2, and it
still holds.

*Judgement:* right.

**Corrected 22 September 2026, two findings:**
- **Before:** this exact selection still showed "1 book will have its EPUB
  file replaced." and left the write button enabled, even though nothing in
  the plan would actually change anything. Confirming it would still have
  moved the original to the Trash and rewritten it — for no difference at
  all, the one accidental write ADR 0021 exists to prevent. A plan is now
  checked for at least one field that would really be written before the
  sheet offers to write it at all (`EPUBWrite.BookPlan.hasChange`,
  `EPUBWrite.run`).
- **Before:** the title row read "Nameless" above "Nameless" — the same
  value twice, marked unwritable, with nothing to explain the
  contradiction. The top value was never the file's own: `EPUBWrite.plan`
  read it with the same file-name fallback import uses when a title is
  missing, so it silently reproduced Shelf's own guess instead of showing
  that the file has no title at all. Fixed by reading "before" with no
  fallback, so a title the file genuinely lacks now shows as nothing, not
  as a guess that happens to agree.

**Corrected again, same day:** this is also the picture that caught the
disabled button not actually looking disabled — placed next to
`2-confirmation.jpg`'s enabled one, the "Write into the Book File" button
here was the same solid blue, `.disabled` having no visible effect of its
own against Slate's colours. It now carries an explicit `.opacity(0.4)`
alongside `.disabled`, visible in this picture as the muted, desaturated
button it was always meant to be.

## `4-drm-refused.jpg` — the DRM refusal, in a mixed selection

A DRM-protected book offers no command **on its own** — `isEligible` says
no, and the inspector's button for it never appears at all, which is why
this is a two-book selection ("The Quiet Harbour" and "A Protected Book"),
opened from the grid's own context menu rather than the inspector. "The
Quiet Harbour" carries a publisher Shelf knows and its own file does not
("Not set → Harbour House") — the one field this fixture gives it, so the
plan has something real to write. The plan writes into the one that
qualifies and lists the other under **"Left alone"**, with the DRM message
named — the fact that this book has no individual button never mattered,
because a selection is still allowed to include it, and the sheet is where
its exclusion actually gets said out loud rather than silently skipped.

*Judgement:* right. The DRM badge is visible on the format row in the
inspector too (`Adobe DRM`), so the same fact is said twice, in two
different controls, and agrees with itself.

**Corrected 22 September 2026:** "The Quiet Harbour" used to be one of the
three plain, unedited synthetic books — which meant every field in its plan
already matched the file, and after the "nothing to write" fix above, this
whole selection would have shown "Nothing to write" with neither book
getting anything, defeating the point of the picture. The fixture now gives
"The Quiet Harbour" one field of its own, so the screenshot still shows what
it always meant to: a real write next to a real refusal.

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

## `6-several-unchanged.jpg` — several books, none of which would change

"Cinders and Salt" (never edited — every field already matches its file)
and "Nameless" (its only difference, the title, is the one `EPUBOPFPatch`
can never write) selected together: neither has a real change, so the
sheet says **"Nothing to write"** and, below it, the sentence nothing had
ever actually rendered before this picture — **"2 books would not get a
new EPUB file."** / German **"2 Bücher bekämen keine neue EPUB-Datei."**,
the plural ("other") form, not the singular ("one") "1 Buch bekäme…" a
fixed `%lld`-less string would have produced in German regardless of the
count. Both books stay in the list, each marked **"Left alone — nothing
would change"**, with their own fields shown underneath — the same
transparency `4-drm-refused.jpg` gives a book excluded for a different
reason.

*Judgement:* right. The counted sentence only exists as a catalogue entry
in the strict sense — `Loc.count` reads its plural variations for a count
this sheet had never actually driven through it before today.

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
