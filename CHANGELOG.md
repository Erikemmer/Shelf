# Changelog

Newest first. Measured numbers belong here, with the machine they were measured
on and what was *not* measured.

## Sprint 11, Aufräum-Sitzung, Teil A — which Shelf.app did we actually photograph? · 22 September 2026

Schritt 3's own finding: the "find the newest built `Shelf.app`" snippet
compares the app bundle *directory's* own mtime, which an incremental
Xcode build does not always bump. Erik counted twenty-one scripts under
`Scripts/` sharing it — every screenshot this project has ever taken sat
behind the same doubt.

`Scripts/current-shelf-app.sh` (sourced, the same shape
`no-foreign-shelf.sh` has) adds `verify_shelf_app_is_current`: it reads
`SHELF_BUILD_COMMIT` back out of a candidate's own `Info.plist` and
compares it with a fresh `git rev-parse HEAD` — never rebuilds, never
guesses which of several candidates was meant, aborts naming both commits
on a mismatch. `SHELF_BUILD_COMMIT` is a build setting `project.yml`
substitutes into `Info.plist` exactly the way `MARKETING_VERSION` already
is (`CFBundleShortVersionString: $(MARKETING_VERSION)`), set by `make
app` / `make app-debug` / `make bootstrap`'s own `xcodebuild …
SHELF_BUILD_COMMIT="$(git rev-parse HEAD)"`.

**The first version of this fix broke the app's own code signature.** A
build phase (`postbuildScripts`) that wrote the commit into the already-
built `Info.plist` ran *after* Xcode's own signing step, and
`codesign --verify` started failing with "invalid Info.plist (plist or
signature have been modified)" — caught before it was committed. A build
setting substituted before signing, the way every other `$(…)`-templated
`Info.plist` key in this project already works, has nothing to sign around.

All twenty-one scripts call `verify_shelf_app_is_current` before launching
anything. `Scripts/check-current-app-guard.sh`, wired into `make lint`,
fails the build if a twenty-second script is ever added without it —
proven both ways: red with the call removed from `cover-shot.sh`
(`current-shelf-app: Scripts/cover-shot.sh:123 starts a Shelf instance but
never calls verify_shelf_app_is_current`), green with it restored.

**Whether old screenshots were affected**, checked against two cheap,
already-committed ones (no foreign hardware, no extra permission):
`write-into-book-shot.sh` (Sprint 10) re-shot with a verified build came
back pixel-for-pixel identical to the committed `1-menu.jpg` and
`2-confirmation.jpg` (mean absolute byte difference 0.000/255, sampled
over ~500k bytes each). `orphan-shot.sh` (Sprint 4) re-shot came back
genuinely different — "10 folder(s)" → "10 folders" (`Loc.count`'s plural
handling), "267.9 KB" → "274 kB" (a later `ByteCount` formatting change) —
but every difference matches known wording and formatting work from later
sprints, not a wrong build photographed at the time. Reported, not fixed,
per instruction; both re-shot folders were restored to their committed
state (`git checkout`) afterward.

790 core tests (unchanged — no core code touched), `make lint` (both
checks), `make app` and `make smoke` clean. One commit.

## Sprint 11, Schritt 3 — the cover in "Write into the Book File" · 22 September 2026

Schritt 1 and 2 below built and proved `EPUBCoverPatch`; this is the window
half Schritt 1's own entry said was still open — the cover as one more row
in the confirmation sheet ADR 0021 and Sprint 10 already built for text
fields, never a second command or a second sheet.

`EPUBWrite.BookPlan` gains `cover: CoverPlan` (`beforeBytes`, `afterBytes`,
`changed`). `plan(for:library:)` reads the book's own cover
(`EPUBMetadata`) and the `cover.<ext>` file beside it (`CoverFile.url`,
exactly what `Download Cover…` and `Replace Cover…` already leave there,
per ADR 0020) and, when they differ, patches the cover into the very same
archive the metadata patch already produced — one book, one consistent
`newContent`, never two patches that could each discard the other's work.
`hasChange` now counts a changed cover the same as a changed field, so
"Nothing to write" and the disabled write button both already followed
from it with no further window code. No cover row at all when Shelf has
nothing of its own to offer for a book (`afterBytes == nil`) — a judgement
call, not asked for explicitly: a book Shelf never generated or received a
cover for is not a field this sheet tracks the way title or author always
are.

The sheet describes a cover in words, never a picture: `CoverImage
.describe(_:)` (app layer, `CGImageSource`, never in the core — the core
still never decodes a pixel) turns bytes into `"JPG, 600 × 900"`; the
book's own current cover shows `"No cover in the book"` when it has none.
A cover already the same as what Shelf would write is tagged "already the
same", identically to an unchanged text field. Two new catalogue entries
("No cover in the book", "unreadable image"), both languages; "Cover"
itself already existed in the catalogue from elsewhere and is reused as-is.

3 new core tests (`EPUBWriteTests`): a cover that changes and is actually
written (read back from the rewritten file afterward), a cover already the
same (no change, `hasChange` false), and no cover file beside the book at
all (nothing to offer, no change). 790 core tests total, `make lint`,
`make app` and `make smoke` clean.

Screenshots in both languages, `docs/screenshots/sprint-11/`: a cover
Shelf would replace beside a field that also changes, a book with no cover
of its own that Shelf can add one to, a cover already the same, and the
state afterward — checked against the book's own file with `unzip` and
`cmp`, not against the picture. The three cover images are real, decodable
JPEGs made from Shelf's own app icon with `sips` (`Scripts/write-into-book-
cover-shot.sh`), never a borrowed image, so the sheet's own size
descriptions ("JPG, 300 × 450") are real numbers a real `CGImageSource`
decoded, not a made-up string. `docs/screenshots/sprint-11/README.md` has
the judgement under each picture, including two things found taking them
rather than before: a stale, five-day-old app build silently outranking a
freshly built one in the shared "newest `Shelf.app`" script snippet (looked
exactly like a missing German translation; `docs/BACKLOG.md` has it), and
the sheet's own "planning" state sometimes outlasting a fixed sleep once a
real cover's tens of KB are actually being hashed and re-archived.

`docs/adr/0021-…`'s status line now says what is actually built — metadata
since Sprint 10, and the cover since this Schritt — rather than "not yet
implemented in the window".

One commit.

## Sprint 11, Schritt 2 — three gaps in Schritt 1's own proof, closed · 22 September 2026

Schritt 1 below shipped `EPUBCoverPatch` proven against six real Gutenberg
books — but every one of them already had a cover, so its case b (adding a
cover where the manifest names none) had only ever run against synthetic
archives this project builds itself: the riskier half of the two cases, and
the one nobody had actually tried against a real book. Three gaps, each
closed with a test or a real measurement rather than a guess.

**Fall b, against real books.** `Scripts/strip-epub-cover.py` — a tool that
is not Shelf's own code, the same reason `Scripts/epub-crosscheck.py`
exists — removes a real book's cover image, its manifest `<item>`, and
every cover declaration (EPUB 2's `<meta name="cover">`, EPUB 3's
`properties="cover-image"`, or both) from a copy of a real EPUB, as a
text-level edit rather than a full XML round-trip, so nothing else in the
OPF changes. Run against copies of all six real books, then
`shelf-tool epub-cover-patch` against the six stripped copies: every one
now reports case b, and `EPUBMetadata` reads the new cover back correctly
in every one. Sizes, machine: this Mac, synthetic ~530-byte cover (the same
one Schritt 1 measures with) — alice-in-wonderland 82 956 → 86 979 bytes
(+4.85 %, EPUB 2 `<meta>` form), die-verwandlung 63 410 → 65 291 (+2.97 %,
EPUB 2 form — its own cover file is named `..._title-page.jpg`, not
`..._cover.jpg`, so this is a real case of a cover found by the manifest's
own declaration rather than by guessing from a file name), grimms-fairy-
tales 275 962 → 289 040 (+4.74 %, EPUB 2 form), les-miserables 9 872 668 →
9 945 915 (+0.74 %, both EPUB 2 and EPUB 3 forms — its own OPF still keeps
an NCX for backward compatibility, the same signal ADR 0021 already
documents), pride-and-prejudice EPUB2 and EPUB3 24 206 819 → 24 232 111 and
24 196 305 → 24 220 564 (+0.10 % each, EPUB 2 form for the EPUB2 file, both
forms for the EPUB3 one). `Scripts/real-epub-proof.sh` section 10.

Trying this against real books found a real defect in the *proof tooling*
itself, not in `EPUBCoverPatch`: `shelf-tool epub-cover-patch` decided its
printed "case a" / "case b" label from `EPUBMetadata.read(…).cover != nil`
— but `EPUBMetadata`'s own reader has a fallback ("no manifest cover → the
first image in the archive", built for a hand-made EPUB or a comic with no
declaration at all) that `EPUBCoverPatch`'s manifest-only decision does not
share. A stripped book with its declared cover gone but *some* other image
still inside it (les-miserables' own cover-page SVG wrapper; pride-and-
prejudice's illustrations) read back as "already has a cover" under the old
label while `EPUBCoverPatch` correctly took the case b branch — the tool
then checked case b's own result against case a's own expectations and
failed for no real reason. Fixed by reading the case from
`EPUBCoverPatch.Result.replacedExisting` itself, the ground truth of which
branch actually ran, rather than recomputing a second, disagreeing opinion.

Also asked: whether Gutenberg has an "EPUB (no images)" edition with no
cover at all, to add alongside the stripped copies. It does not — checked
against `74.epub.noimages` (Gutenberg book 74): "no images" still means an
illustration-free *text*, and Gutenberg's own EPUB generator adds a cover
image to every edition regardless, so a real, natively cover-less EPUB does
not appear to exist in Gutenberg's catalogue. `Scripts/real-epubs.sh` is
unchanged; the six stripped copies above are the only real-book proof of
Fall b there is.

**A real cover's actual size.** Schritt 1's own numbers below are all
measured against a synthetic ~530-byte cover, so every one of the six books
*shrank* — a number nobody replacing a cover for real would ever see. A new
`shelf-tool epub-cover-real-size` command patches a whole folder of books
with a REAL cover, read straight out of another EPUB with `EPUBMetadata`
rather than re-encoded. Run with the cover already inside
`pride-and-prejudice-epub3-images.epub` (229 591 bytes, JPEG) against all
six books: alice-in-wonderland 136 519 → 312 532 bytes (+128.93 %),
die-verwandlung 99 693 → 293 151 (+194.05 %), grimms-fairy-tales 531 353 →
504 251 (−5.10 % — its own existing cover happened to already be larger
than the real cover used here), les-miserables 10 123 259 → 10 132 626
(+0.09 %), and both pride-and-prejudice EPUB2 and EPUB3 — patched with
*their own* cover — reported "already had this exact cover, nothing
written", the first real-book proof of the third gap below.
`Scripts/real-epub-proof.sh` section 11. Schritt 1's own shrinking numbers
above stay in this file as they were measured; they are an artifact of the
tiny synthetic test cover, not of what a real cover replacement costs — the
numbers in this paragraph are that cost.

**The same cover is not a change.** `EPUBCoverPatch.Result` gains
`changed: Bool` — `false` only in case a, when the new cover is already,
byte for byte, what the manifest's own cover entry holds; `entries` is then
`archive`'s own entries carried forward completely untouched, so a caller
that skips writing when `changed` is `false` truly writes nothing. Always
`true` in case b: adding a cover where none exists is always a change. One
new core test, `identicalCoverIsNoChange`, proves zero entries differ
either way; the pride-and-prejudice self-application above is the same
claim proven against a real book. This is the foundation Schritt 3 (Erik's
word required first) would build "Nothing to write" in the window on, the
same rule Sprint 10 already gives metadata fields — a cover write that
would change nothing must never move a book's file to the Trash for no
difference at all.

787 core tests (1 new), `make lint`, `make app` and `make smoke` clean. One
commit. `docs/adr/0021-…`, `docs/ARCHITECTURE.md` and the window are
untouched — no window changes here either.

## Sprint 11, Schritt 1 — a cover into an EPUB's own archive, in the core · 22 September 2026

`docs/adr/0021-…` promised a cover as well as metadata; Sprint 10 built only
the metadata half. `EPUBCoverPatch` is the rest, on the same footing as
`EPUBOPFPatch`: no window yet, proven synthetically and against the six real
Gutenberg books.

Two cases, decided by the manifest itself. **a) It already names a cover:**
only that entry's bytes are replaced, at the path it already has — an EPUB 2
cover page is often its own XHTML file that embeds the image by that exact
href, and moving the file would point that page at nothing. A new image in a
different format from the old one is still written at the old path; only the
manifest's `media-type` is corrected. **b) It does not:** a new manifest item
is added, with a cover declaration in whichever form the file itself already
uses — EPUB 2's `<meta name="cover" content="id">`, EPUB 3's
`properties="cover-image"`, or both. The "both" rule was not guessed: reading
`pride-and-prejudice-epub3-images.epub`'s own `content.opf` while building
this showed a real EPUB 3 book that still carries `<spine toc="…">` naming an
NCX, kept for readers that only understand EPUB 2 — a book that goes to that
trouble for its table of contents gets both forms of the cover declaration
too. The cover image is always written stored, never deflated (JPEG and PNG
are already compressed; a second pass costs bytes for nothing). Nothing here
decodes, scales or re-encodes a pixel — the bytes go in exactly as they sit
next to the book — and DRM is refused in the core, before anything is read.

10 new core tests, synthetic archives only, covering: both cases in both EPUB
generations, the format-mismatch correction, the "both forms" rule, an id/path
collision avoided, and DRM refused before anything is touched.

The sharper proof: after a pure cover change, **exactly one entry of the
archive differs** (the image) when the format did not change, and **exactly
two** (the image and the OPF) when it did — `shelf-tool epub-cover-patch`,
run from `Scripts/real-epub-proof.sh`, against the same six Gutenberg books
Sprint 10 already proves `EPUBOPFPatch` against. All six turned out to
already have a cover (case a) — `alice-in-wonderland-epub2-noimages.epub`,
`die-verwandlung-epub2-images.epub`, `grimms-fairy-tales-epub2-images.epub`,
`les-miserables-epub3-images.epub`, `pride-and-prejudice-epub2-images.epub`
and `pride-and-prejudice-epub3-images.epub`, every one of them JPEG — so
case b (no cover at all) is proven only by the synthetic tests, not against
a real book; nothing in the six offered the chance. Run against a synthetic
cover in the book's own format (one entry differs, confirmed for all six)
and again in a different one (two entries differ, `media-type` corrected
from `image/jpeg` to `image/png`, confirmed for all six); `EPUBMetadata`
reads the new cover back out of the result every time; the independent
Python cross-check (`Scripts/epub-crosscheck.py`) agrees. Sizes, machine:
this Mac, synthetic ~530-byte cover replacing what was there before, so
every book *shrank*: Alice in Wonderland 136 519 → 83 467 bytes (−38.9 %),
Die Verwandlung 99 693 → 64 086 (−35.7 %), Grimms' Fairy Tales 531 353 →
275 186 (−48.2 %), Les Misérables 10 123 259 → 9 903 561 (−2.2 %), Pride and
Prejudice EPUB2 24 846 132 → 24 617 067 (−0.9 %), EPUB3 24 835 578 →
24 606 513 (−0.9 %) — a real cover replacement would typically grow a book
instead, since Shelf's own covers are not shrunk to shelf-tool's tiny test
size.

Two of `EPUBOPFPatch`'s own private tag-scanning helpers (finding a raw
tag's span, and its attributes' local names) are `internal` rather than
`private` as of this sprint, so `EPUBCoverPatch` can share them rather than
carrying a second copy of the same edge cases (a quoted `>`, a self-closing
tag). `OPFDocument.readCoverPath` is `coverPath` and `public` for the same
reason: `EPUBCoverPatch` asks the exact question a read already answers, so
a write replaces exactly what a read would have shown.

786 core tests (10 new), `make lint`, `make app` and `make smoke` clean. One
commit. No window changes — `EPUBWrite` and `WriteIntoBookSheet` are
untouched; the cover does not yet appear in "Write into the Book File"'s own
plan. That is Sprint 11's Schritt 2, on Erik's word.

## Sprint 10, Schritt E2 — three follow-up questions about the last fix · 22 September 2026

Erik asked three questions about the correction below, each with a test or a
screenshot deciding it rather than a guess.

**Did the title fallback bug have a twin at the author field?** It did, in
the code (`EPUBMetadata.read` guesses an author from the file name the same
way it guesses a title, a few lines below), but not in the fix: the
correction's one `fallbackTitle: ""` already silences both guesses at once,
because both read the same parameter. A new test —
`EPUBWriteTests.planShowsAMissingAuthorAsNotSetRatherThanGuessed` — builds
an EPUB whose OPF has neither `<dc:title>` nor `<dc:creator>`, named so a
guess would have found "Author" *and* "Title" in it, and passed on the
first run, no production change needed. A comment now marks the fix site
with the general rule: a read comparing a file's current state against
what Shelf would write never guesses; guessing belongs to import alone,
where a guessed title is better than none. `MobiMetadata.read` has the
same fallback and was left alone — noted in `docs/BACKLOG.md`, not fixed,
since nothing in v1.0 writes into a MOBI or compares one against anything.

**Did the disabled write button actually look disabled?** No. Checked
against `3-unwritten-field.jpg` next to `2-confirmation.jpg`'s enabled
button: same solid blue, `.disabled` alone having no visible effect
against Slate's own colours. `WriteIntoBookSheet`'s button now carries an
explicit `.opacity(0.4)` alongside `.disabled`, confirmed by re-shooting
the same picture in both languages. `docs/BACKLOG.md` notes that
`DeleteFromDeviceSheet`'s own confirm button may have the same gap —
not checked this time, since it was not asked for.

**Did the plural "several books would not get a new EPUB file" sentence
actually render right?** Nobody had ever driven it through `Loc.count`
before today — no test, no screenshot. A new screenshot,
`6-several-unchanged.jpg`, selects "Cinders and Salt" (never edited) and
"Nameless" (nothing left to change once its title is set aside) together;
the sheet reads "2 books would not get a new EPUB file." in English and
"2 Bücher bekämen keine neue EPUB-Datei." in German — the plural ("other")
category, correctly distinct from the singular "1 Buch bekäme…" a bare
`%lld` string cannot produce on its own in German. A new core test,
`planForSeveralUnchangedBooksHasNoneWithChange`, proves the same count at
the `EPUBWrite.Plan` level, across a selection rather than one book alone.

776 core tests (2 new), `make lint` and `make smoke` clean, `make app`
built. One commit.

## Sprint 10, Schritt E2 — four corrections found by looking at its own screenshots · 22 September 2026

Erik looked at Schritt E2's own screenshots (`docs/screenshots/sprint-10/`)
and found four things wrong with the sheet, not the pictures.

**A write that would change nothing was still offered.** In
`3-unwritten-field.jpg`, all six fields of "Nameless" are either "already
the same" or "cannot be written" — nothing would actually change — and the
sheet still said "1 book will have its EPUB file replaced." with the button
enabled. Confirming it would have moved a hashed, verified original to the
Trash and rewritten it, for no difference at all: exactly the accidental
write ADR 0021 exists to prevent. `EPUBWrite.BookPlan` now has `hasChange`
— true only when at least one field is both `willBeWritten` and `changed`,
the sheet's own two tags read back rather than a separate count that could
disagree with the list — and `EPUBWrite.run` never touches a plan where it
is `false`, recording a new `BookOutcome.Result.noChange` instead. The sheet
shows **"Nothing to write" / "This EPUB file would not change."** and
disables the button when every book in the plan is like this; in a mixed
selection, a book with nothing to change stays in the list, marked **"Left
alone — nothing would change"**, and is the one book `run` leaves alone.

**The title row on that same screenshot read "Nameless" above "Nameless"**
— marked unwritable, with nothing to say why the two lines agreed. They
were never both real: `EPUBWrite.plan` read the file's own "before" title
with `fallbackTitle: epub.fileName`, the same fallback import uses so a
title-less book still gets *something* — which meant a file with no title
element at all read back as Shelf's own guess, because it is the same
guess, guessed from the same file name. Fixed by reading "before" with no
fallback (`fallbackTitle: ""`): a title the file genuinely does not have
now shows as nothing, never as a value that happens to match.

**Two lines per field became one, with an arrow.** "Old above new, neither
labelled" asked a reader to infer which was which from position. Every
field row is now one line: `Not set → Erik & Erik Press`, the old value,
an arrow, the new value in bold — collapsing to a single, unstruck value
when the field is already the same or cannot be written, never two
identical lines. The arrow is glued to the new value with a non-breaking
space, so a wrap can only fall inside the old value or the new one.

**Two sentences in the explanation were reworded.** "Only the EPUB is
written into" reads as "beschrieben" in German, genuinely ambiguous with
"described". "Not away for good, but there is no ⌘Z for this" read as a
consolation where a limit was meant. Both are now:

> Only the EPUB file is written to. PDF, MOBI and AZW3 stay exactly as they
> are. Each book's current EPUB file moves to the Trash — not gone for
> good, but ⌘Z will not bring it back. Anyone who needs it can get it back
> from the Trash themselves.

German: *"Geschrieben wird nur in die EPUB-Datei. PDF, MOBI und AZW3 bleiben
genau, wie sie sind. Die bisherige EPUB-Datei jedes Buchs wandert in den
Papierkorb – sie ist also nicht endgültig weg, aber ⌘Z holt sie nicht
zurück. Wer sie braucht, holt sie selbst aus dem Papierkorb."*

**One side question, answered, nothing changed:** the description "Added in
Shelf, not yet in the book's own file." in `2-confirmation.jpg` is sample
content the fixture writes into a synthetic book (`shelf-tool
epub-write-fixture`), the same way "The Glass Almanac" is a title and "Erik
& Erik Press" is a publisher — English on purpose, like every other piece
of sample content in this fixture, not a Shelf UI string that missed
translation. It never goes through `Loc`.

`shelf-tool epub-write-fixture` now also gives "The Quiet Harbour" a
publisher of its own ("Harbour House") — a consequence of the first fix
above: that book was never edited, so once a plan with nothing to change is
correctly left alone, the DRM screenshot's two-book selection would have
had nothing left to write at all. Tests: `EPUBWriteTests` — a title the
file lacks reads back as not set rather than guessed, a plan with nothing
real to change has `hasChange == false`, one with a real field does not,
and `run` leaves a no-change plan's file, Trash and index untouched. 774
core tests, all green. `make lint` clean, `make smoke` clean, one commit.

**Proof:** all five screenshots retaken in English and German, all five
still pass the same on-disk checks `write-into-book-shot.sh` always ran —
none were loosened to make this pass.

## Sprint 10, Schritt E2 — "Write into the Book File", in the window · 21 September 2026

The rule that a book file is never written falls here for the first time
in the window itself, on explicit instruction only — never in passing,
never from a menu bar
([ADR 0021](docs/adr/0021-metadata-and-a-cover-may-be-written-into-an-epub.md)).

`EPUBWrite` (`Sources/ShelfCore/Library/EPUBWrite.swift`) is the plan-then-
run core: `plan(for:library:)` reads an entry's EPUB, computes what six
fields — title, authors, publisher, published date, language, description
— would change against what `entry.book` now holds, and produces the
exact bytes `run` will write, so what a confirmation shows and what
actually gets written can never drift apart. A book with no EPUB, DRM, an
author count that does not match its file, or any other preflight refusal
is named in `Plan.skipped`, never silently dropped. `run` writes a
selection's books one at a time — a plain loop, never a `TaskGroup` — the
same rule `EPUBFileReplacement` itself states, restated at the one new
caller that could otherwise reach for concurrency.

`WriteIntoBookSheet` is the window: reachable from the inspector's
**Formats** section and from the grid/table's own context menu
(`BookMenu`), never the menu bar — the same reason `CoverReplacement`'s
commands live in the inspector and nowhere else. The confirmation names
every book and every field, old struck through above new, "already the
same" for what would not change, and — in the accent colour, on the same
list — **"cannot be written"** for a field `EPUBOPFPatch` genuinely cannot
place (a `dc:title` with no element in the file to replace; the one real
case `EPUBOPFPatch` never invents a title for). A mixed selection writes
into what qualifies and lists the rest under **"Left alone"**, by name and
by reason. States plainly what will *not* happen — only the EPUB, PDF/
MOBI/AZW3 untouched — beside what will: the original to the Trash, no ⌘Z,
said once in the confirmation and once again after it is done. A checkbox
("I have read the list above") gates the button, the same second
deliberate act `DeleteFromDeviceSheet` already asks for Shelf's other
irreversible operation.

Every new sentence goes through `Loc.string`/`Loc.count`/`Loc.core`,
enforced by `LocalisationTests` — 26 new catalogue entries, English and
German both, including a genuine plural pair ("1 book will have its EPUB
file replaced." / "%lld books…"). Every field row carries its own
VoiceOver label, read as a sentence ("Publisher changes from nothing to
Erik & Erik Press") rather than the two-line visual layout taken literally.

**Proof:** `Scripts/write-into-book-shot.sh`, against the five-book
library `shelf-tool epub-write-fixture` builds (three ordinary synthetic
books, one announcing Adobe DRM, one EPUB with no `<dc:title>` element at
all). Five pictures, both languages, `docs/screenshots/sprint-10/` (and
`/de`) with a README carrying a verdict under each: the command itself,
the confirmation with a real old→new, the unwritable-title marker, the
DRM refusal inside a mixed selection, and the state afterward. Every claim
checked against the book's own file on disk — `2-confirmation.jpg` and
`5-after.jpg` are the same book before and after, and the run reads
`OEBPS/content.opf` back out of the new EPUB and fails if the publisher it
asked for is not actually there.

**Found taking the screenshots, not before:** the inspector is one long
`ScrollView`, and the new button sits well past the first screenful for
any book with a description. `AXScrollToVisible` — tried on the theory
that an off-screen control found by the accessibility API could be
scrolled into view before being clicked — is a genuine no-op against this
SwiftUI view; `Scripts/scroll-at.swift`, a real scroll-wheel event already
in the repository for exactly this reason, is the actual fix. Separately:
"Write into the Book File" (the sheet's own button) is a prefix of "Write
into the Book File…" (the inspector's, left dimmed behind the sheet), and
`cell-point.swift`'s prefix matching found the dimmed one first — fixed by
asking for the second occurrence explicitly, not by changing the button
text. `click-at.swift` gained a `cmd` word (holds ⌘ for the click) to
demonstrate the DRM refusal inside a two-book selection.

**`CLAUDE.md` and `docs/CONCEPT.md` updated last, only now that this is
proven working** — the old, unqualified "a book file is never written"
wording is kept as a quoted sentence in each of the three places it
appeared, with today's date and the reason it fell.

`docs/BACKLOG.md` marks Schritt E2 done; Sprint 10 is now complete except
for what its own "found on the way" lists still carry forward.

## Sprint 10, Schritt E1, Korrektur 2 — the Trash is hashed and checked, not trusted · 21 September 2026

Korrektur 1 said "original disposed of, not verified" and left it there:
`FolderDisposal.dispose` returned nothing, so a caller had no way to
confirm what actually landed in the Trash was the file that used to be in
the book's folder — only that `trashItem` didn't throw.

`FolderDisposal.dispose` now returns the destination, `URL?` — what
`trashItem`'s own `resultingItemURL` reports, `nil` for a disposal that
cannot say one (a test double, mostly). `EPUBFileReplacement.DisposalOutcome
.trashed` carries it: `.trashed(at: URL?)`. `shelf-tool
epub-file-replace-proof` uses it to do what Korrektur 1 only reported —
hash the file at that URL and check it against the digest the folder held
before the swap, the same "copy, verify, then trust" ADR 0002 already asks
of everything else. The report now names the count: for how many of the
six real books this was actually proven, not assumed.

`CoverReplacement.swift` and `OrganizeRunner.swift` call `dispose` for its
side effect only and needed no change — a caller ignoring an extra return
value is exactly what "the callers that don't need the URL, ignore it"
meant. Their own test doubles (`CoverReplacementTests`, `OrganizeTests`)
and `EPUBFileReplacementTests`' `Bin` do construct `FolderDisposal`
closures, and those needed one line each to return the destination they
already know, to satisfy the new signature — mechanical, no behaviour
changed.

764 core tests, still — the whole path's own test now confirms
`.trashed(at:)` against the exact URL the test double moved the file to,
not merely that some disposal happened.

**Measured — all six real books, `shelf-tool epub-file-replace-proof`,
this Mac:** original verified bit-identical in the real Trash for **6 of
6 books**.

## Sprint 10, Schritt E1, Korrektur 1 — the swap is two renames, not a rename either side of the Trash · 21 September 2026

`EPUBFileReplacement.replace` had a gap: original into the Trash, *then*
the new file renamed onto its path. `trashItem` is not a rename — it can be
slow, it can go through iCloud, it can hang — and for however long it
takes, the book has no file at all. If the process died in that window,
the folder held only a `.part` and the index still said the book had an
EPUB.

The swap is now two plain renames within the book's own folder, and
disposal comes last:

1. The original is renamed aside, in place, to a second
   `.shelf-epub-write-*-original.part` name.
2. The new file is renamed onto the original's exact path.
3. Only now — with the book already correct — is the renamed-aside
   original offered to `FolderDisposal`.

If step 1 fails, nothing has moved. If step 2 fails, step 1 is undone and
the `.part` is swept. Either way the original refusal behaviour holds. Step
3 is different on purpose: a disposal that refuses at that point is not
this call failing, because the book already has the file it is meant to
have. It is reported as a fact — `Result.originalDisposal`, `.trashed` or
`.leftAsDebris(name:reason:)` — never thrown. `Refusal.cannotDisplace` is
gone; there is nothing left it could mean. Debris from a refused disposal
sits under `EPUBFileReplacement.partialPrefix` in the book's own folder
until the next call there sweeps it, exactly like any other `.part`.

`CoverReplacement` has the same trash-before-swap gap and is deliberately
untouched — `docs/BACKLOG.md` has it as its own line. A cover is a small
picture kept in memory; a book kept nowhere for however long `trashItem`
takes is a different weight of problem, and worth fixing here first.

764 core tests, up from 763 — the whole path re-proven against the new
order, plus a disposal-failure case that used to be a thrown refusal and
now proves the book stays correct and the debris is named and swept, and a
case proving that debris is actually swept by the next call in that
folder. `shelf-tool epub-file-replace-proof` carries the same change.

## Sprint 10, Schritt E1 — a book's own file may now be replaced · 21 September 2026

The rule that a book file is never written, deleted or overwritten falls
here for the first time, in the controlled way `docs/adr/0021-…` describes.
`EPUBFileReplacement` is the whole of it, and no window calls it yet:

1. **Preflight, before a byte is touched** — is it a readable EPUB, is it
   free of `META-INF/encryption.xml` (`DRMProbe`'s own check, reused, not
   reimplemented), can its folder actually be written to. A read-only
   volume is named here, not discovered halfway through a write.
2. The new bytes are written under a `.shelf-epub-write-*.part` name next
   to the original — the same prefix pattern `ImportRunner`, `ExportRunner`
   and `CoverReplacement` already use, and swept the same way on an
   interrupted run's next attempt.
3. **Read back with Shelf's own reader**, `EPUBMetadata.read` — the same
   one `BookFileReader` trusts for an import. Title, author (if the
   original had one) and cover (if the original had one) all have to come
   back, and the archive has to open at all, before the new file counts
   for anything.
4. The bytes on disk are hashed and checked against what was meant to be
   written — `ContentHasher`'s own "copy, verify, then trust"
   (`docs/adr/0002-…`), applied to a generated file rather than a copied
   one.
5. The original goes to the Trash through `FolderDisposal`, never
   `removeItem`. A disposal that refuses leaves the `.part` swept and the
   original exactly as it was.
6. The `.part` takes the original's exact path.

**No ⌘Z.** The Trash is the way back — the same answer a replaced cover
already gives to "I didn't mean that", written as its own sentence in
`EPUBFileReplacement`'s doc comment, on purpose: two different answers to
⌘Z for two kinds of file change would be worse than one consistent one.

**Only the index changes.** `BookFormat.byteSize`, `.sha256` and
`.modifiedAt` are re-derived from the file that is now actually there and
saved into `LibraryIndex` through `EPUBFileReplacement.commit`; nothing is
mirrored into `metadata.opf`, because all three are exactly the kind of
fact ADR 0001 already says stays out of the sidecar — re-derivable from the
folder at any time, and stale the moment anything else touches the file.
Confirmed as the right split before writing it, not after: a `shelf:
file_sha256` in the OPF would have been a second copy of a fact nobody
reads back out of there, going wrong the instant something else touches
the book.

**Sequential, never concurrent, across several books** — `commit` called in
a plain loop, never a `TaskGroup` or `async let`. At 24 MB and 187 entries
for a real, illustrated EPUB (the measurement below this one), the peak
memory a batch of replacements costs is one book's, not the whole batch's.

**Proof:** `shelf-tool epub-file-replace-proof`, wired into
`Scripts/real-epub-proof.sh` as its section 7 — the whole path against
copies of all six real books, one after another, through the *real* Trash
(this is the CLI process, not the `swift test` runner — see the finding
below), plus each of the five refusals proven once against a fresh real
copy, with a check after each that its folder holds exactly the original
file and nothing named `.shelf-epub-write-*`. 763 core tests, up from 754 –
`EPUBFileReplacementTests`, nine of them, against synthetic fixtures built
through `EPUBArchiveWriter` itself.

**Measured — all six real books replaced one after another, `/usr/bin/time
-l` around the whole run, this Mac:**

68.3 s real, 268 238 848 B (255.8 MB) maximum resident set size, 224 051 968 B
(213.7 MB) peak memory footprint. In the same range as the single 24 MB
book's own peak (135 MB, measured below) rather than six times it – the
batch's cost is the largest book's, not the sum of all six, which is what
"sequential, never concurrent" was for.

**A real, environment-specific bug found along the way, not a bug in this
type:** `FileManager.trashItem` fails reproducibly inside the `swift test`
runner process (`.cannotWrite("… couldn't be moved to "ShelfTests-…"
because an item with the same name already exists.")`), confirmed by two
standalone `swift` scripts that ran the identical sequence outside the test
harness and both succeeded. Not a `shelf-tool` or app-process problem —
only the Swift Testing runner. `EPUBFileReplacementTests` works around it
the way `CoverReplacementTests` already does: a `Bin` that moves to a local
sibling folder instead of asking the real Trash for anything.

## Sprint 10, part 2, extended — a missing field is created, not silently skipped · 21 September 2026

The entry below said "never invents structure" and left it there: a field
with no existing element to hold it did nothing, silently. For `dc:title`
and `dc:creator` that is right — a book without one does not happen, and a
new author raises the `id`/`refines` question adding one already refuses
on. For the other four it was the common case going unanswered: a real
Gutenberg EPUB usually has no `dc:publisher` at all, and Erik typing one in
and pressing "write into the book" would have changed nothing, silently.

`dc:publisher`, `dc:language`, `dc:date` and `dc:description` are now
**created** — as the last child of `<metadata>`, in whatever namespace
prefix the file's own Dublin Core elements already use (`dc:` beside
`dc:title`, no prefix beside a bare `<title>`) — when the book has none.
`EPUBOPFPatch.apply` now returns both the patched text and the name of
every field that still could not be written (`Result.unwritten`); nothing
is swallowed. Two related fixes along the way: an empty-authors-list source
archive with authors requested now correctly throws
`authorCountMismatch(existing: 0, new: …)` instead of silently doing
nothing, and an identifier scheme with no existing element to match is now
reported in `unwritten` rather than dropped. 754 core tests, up from 751 —
three new traps for the insertion path (a missing field is created; it goes
in with the file's own prefix, even when that prefix is none; a genuinely
missing title stays refused and is reported, not silently ignored).

**Measured — the OPF entry, all six real books, now with publisher and
description created rather than skipped** (none of the six had either
before):

| Book | OPF before → after | Absolute | Relative to the whole file |
|---|---|---|---|
| Die Verwandlung (EPUB2) | 845 → 2 186 bytes | +1 341 B | +1.3 % |
| Alice's Adventures in Wonderland (EPUB2) | 1 099 → 4 586 bytes | +3 487 B | +2.6 % |
| Grimms' Fairy Tales (EPUB2) | 1 740 → 14 288 bytes | +12 548 B | +2.4 % |
| Pride and Prejudice (EPUB3) | 3 719 → 27 468 bytes | +23 749 B | +0.10 % |
| Pride and Prejudice (EPUB2) | 3 666 → 28 459 bytes | +24 793 B | +0.10 % |
| Les Misérables (EPUB3) | 7 249 → 79 990 bytes | +72 741 B | +0.72 % |

Barely moved from the previous entry's numbers — a new `dc:publisher` and
`dc:description` are a few dozen bytes each, nothing next to what losing
DEFLATE already cost. `shelf-tool epub-metadata-patch` and
`Scripts/real-epub-proof.sh` both confirm `unwritten` is empty for all six:
every field asked for was actually written.

## Sprint 10, part 2 — changing content.opf in place, not rendering a new one · 21 September 2026

`EPUBOPFPatch` changes title, authors, language, publisher, the published
date, description and identifiers in an EPUB's own `content.opf` by parsing
it with `XMLTree` to find exactly the elements Shelf is allowed to touch,
then editing only their text in the *original bytes* — never rendering a
new OPF, which would silently drop everything a real book's OPF carries
that Shelf does not model (accessibility metadata, EPUB 3 rendition hints,
a publisher's own extensions). `EPUBOPFPatch.entries(patching:in:now:)`
ties it to the writer: every other entry is carried forward as
`.passthrough`, untouched; the OPF alone is written `.raw`, because there
is no compressor here to re-deflate it with. A DRM-protected archive is
refused before the OPF is even read — in `ShelfCore`, not a check a future
window adds.

**Never invents structure.** If a field has no existing element — an EPUB 2
with no `dcterms:modified`, a scheme Shelf has a value for but the file
never declared, a book that never had a `dc:description` — nothing is
added, only what already exists is changed. **Refuses rather than
guesses**: a different number of authors than the file has creators for, a
`dc:creator` whose role is not "author", or a local name spelled more than
one way in the same file are all named refusals, not something picked
between.

**The five traps, each with its own test, against both synthetic OPFs and
six real Gutenberg books**: the `unique-identifier` anchor survives a
change to other identifiers; EPUB 2's `opf:file-as`/`opf:role` and EPUB 3's
`id` + `refines` metas both survive a replaced author name; `dcterms:modified`
updates to now when something else changes and is never invented on an
EPUB 2; the cover meta (EPUB 2) and the manifest's `cover-image` property
(EPUB 3) are untouched because nothing here targets them; `xml:lang` and
mixed namespace prefixes (`<title>` under a default namespace beside
`<dc:creator>`) survive because only text between existing tags is ever
replaced, never the tags themselves. 751 core tests, up from 733.

**The sharper proof passthrough makes possible**: after a real metadata
change, `shelf-tool epub-metadata-patch` shows exactly **one** entry of the
archive differs from the original — the OPF — for all six real books, and
`Scripts/epub-crosscheck.py` (Python's own `zipfile` and `xml.etree`,
extended to accept the title's deliberately new value) agrees on all six.

**Measured — the OPF entry's size before and after, all six real books**
(title, authors and publisher patched, `"[Shelf] "` prefixed onto each so
the change is unmistakable in a diff):

| Book | OPF before → after | Absolute | Relative to the *whole file* |
|---|---|---|---|
| Die Verwandlung (EPUB2) | 845 → 2 057 bytes | +1 212 B | +1.2 % |
| Alice's Adventures in Wonderland (EPUB2) | 1 099 → 4 457 bytes | +3 358 B | +2.5 % |
| Grimms' Fairy Tales (EPUB2) | 1 740 → 14 159 bytes | +12 419 B | +2.3 % |
| Pride and Prejudice (EPUB3) | 3 719 → 27 339 bytes | +23 620 B | +0.10 % |
| Pride and Prejudice (EPUB2) | 3 666 → 28 330 bytes | +24 664 B | +0.10 % |
| Les Misérables (EPUB3) | 7 249 → 79 861 bytes | +72 612 B | +0.72 % |

**A footnote, not a warning — corrected from the first version of this
entry, which quoted only the absolute column and read as a bigger deal
than it is.** Put beside the *file* the OPF belongs to, both Pride and
Prejudice editions grow +0.10 %, Les Misérables (the one with by far the
largest OPF, 429 manifest entries' worth) grows +0.72 %, and the worst
case, Alice, is +2.5 %. The growth tracks the *original* OPF's own size
and compressibility, not a fixed cost: every one of these bytes is the
compression the OPF entry gave up by going from DEFLATEd to stored, not
new metadata text. Writing a DEFLATEd OPF back would need a compressor
this project does not build; not worth one for a fraction of a percent.

## The size that actually matters: a real 24 MB, 187-entry EPUB · 21 September 2026

The synthetic 60 MB entry that measures the writer's memory cost is not what
the window will actually hand this writer. A real illustrated EPUB mostly
*stores* its images rather than deflating them (Pride and Prejudice: 187
entries, 22 deflated) — the shape a book-sized round trip actually has.
Measured directly, `/usr/bin/time -l shelf-tool epub-roundtrip` against one
of the two 24 MB books alone, on Erik's Mac, three runs:

| | |
|---|---|
| wall time | 2.02–2.06 s |
| maximum resident set size | 135.4–135.5 MB |
| peak memory footprint | 129.5–129.7 MB |

For comparison, the file itself is 24.8 MB — peak memory is a little over
five times the file's own size, in the same range the 60 MB synthetic
entry showed (there, roughly seven times, at +420 MB over a much smaller
115 MB baseline). No code changed for this measurement; the folder it ran
against (`~/Library/Caches/Shelf/measure-24mb-10/`, a copy of one book) was
created and removed again by the session that measured it.

## Sprint 10, part 1 — the strict round trip against six real EPUBs · 21 September 2026

Every fixture `EPUBArchiveWriterTests` proves the writer against is built by
the writer itself, which only ever writes stored or hand-crafted-deflate
entries it was told to — nothing there was ever compressed by an actual EPUB
tool. `Scripts/real-epubs.sh` fetches six public-domain books from Project
Gutenberg into `~/Library/Caches/Shelf/real-epubs-10/` (never the
repository), deliberately different: EPUB 2 and EPUB 3, illustrated and not,
German and French for non-ASCII text, and one genuinely large book. A new
`shelf-tool epub-roundtrip <folder> <output>` runs the same strict round trip
against all six, and `Scripts/epub-crosscheck.py` checks the result with
Python's own `zipfile` and `xml.etree` — a second, unrelated implementation
of both formats.

**Measured — size before and after, all six, byte-identical, not merely
close:**

| Book | Entries | Deflated | Bytes |
|---|---|---|---|
| Alice's Adventures in Wonderland (EPUB2, no images) | 21 | 19 | 136 519 → 136 519 |
| Die Verwandlung (EPUB2, German) | 10 | 8 | 99 693 → 99 693 |
| Grimms' Fairy Tales (EPUB2, illustrated) | 71 | 69 | 531 353 → 531 353 |
| Les Misérables (EPUB3, French, large) | 429 | 387 | 10 123 259 → 10 123 259 |
| Pride and Prejudice (EPUB2, illustrated) | 187 | 22 | 24 846 132 → 24 846 132 |
| Pride and Prejudice (EPUB3, illustrated) | 182 | 17 | 24 835 578 → 24 835 578 |

**The cross-check agrees on all six**: `zipfile.ZipFile(...).testzip()`
returns `None` for every round-tripped file, the entry list matches the
original's exactly, and `xml.etree` reads the same `dc:title` out of
`content.opf` before and after — Python's own implementations of ZIP and
XML, which have never seen this codebase, finding nothing this project's
own readers would have missed either.

**One thing worth naming rather than assuming:** the round-tripped archives
are not just close in size to the originals, they are **byte-for-byte
identical, the whole file** — not only every entry's payload, but the local
headers, the central directory and the end record too. That was not
guaranteed by anything this fix promises: it holds because every one of
these six books' own tooling happens to write the same conventions this
writer independently chose — general-purpose bit 11 set (UTF-8 names) and
no others, version-needed `20`, no per-entry extra fields. A ZIP tool is
free to write any of those differently and still produce a perfectly valid
archive; this is six real books agreeing with this writer's choices, not a
guarantee that a seventh would. Nothing else about any of the six was a
surprise — no DRM, no unusual manifest, no entry this reader or the
cross-check stumbled on.

`epubcheck` is not installed on this Mac and was not installed to run this
— skipped, per instruction, rather than added.

## Sprint 10, part 1, the double-decompression removed — the number did not move · 21 September 2026

`entries(rewriting:)` decompressed a stored entry twice: once via
`archive.data(for:)` to check its CRC, once via `archive.compressedData(for:)`
for the bytes actually written — for a *stored* entry those are the same
bytes, so the first call was a copy for nothing. Fixed: a stored entry's CRC
is now computed directly from the compressed payload already fetched, reusing
it through `Data`'s copy-on-write storage rather than fetching it a second
time. A DEFLATEd entry still decompresses once, because that is the only way
to get bytes its CRC can be checked against at all.

**Measured — the ~60 MB entry, three more runs: 1.82–1.83 s, +420 MB.**
Unchanged from the previous entry, within measurement noise. The fix is real
— one genuine redundant copy is gone — and it simply does not move this
number, because it was never the dominant cost here. Checked directly: this
test's own verification code (`assertStrictRoundTrip`) calls `.data(at:)` on
*both* readers for the large entry to compare payloads, which decompresses
it twice more, on top of `ZipReader` holding each of the two archives whole
as `[UInt8]` and the writer building each archive as a fresh `Data`. The one
copy Part B removed was a small fraction of a total dominated by allocations
outside what this fix was scoped to touch — the test's own comparison code
included, which was left as it is rather than trimmed to make this number
look better. `docs/BACKLOG.md`.

## Sprint 10, part 1, corrected – entries pass through instead of being recompressed · 21 September 2026

The writer below stored every entry, always — which meant `entries(rewriting:)`
decompressed a source archive's DEFLATEd text and `ZipArchiveWriter` stored it
back uncompressed. For running text that is roughly **2.7 times** the entry's
own size; a 4 MB EPUB becomes something close to 10 MB. "Unchanged" was true
of the decompressed bytes and false of the file. Found before any command
used this, against a real EPUB, not by anything in this test suite — none of
the nine fixtures below was ever compressed to begin with, because all nine
are authored by the writer itself, which only ever stored.

**Fixed: entries pass through.** `ZipReader.compressedData(for:)` returns an
entry's bytes exactly as stored, never decompressed. `ZipArchiveWriter.Entry`
is now two cases — `.raw` (bytes Shelf itself produced: an edited OPF, a new
cover, always stored) and `.passthrough` (an entry carried forward from a
source archive: its compressed bytes, its own method, size and CRC, never
decompressed and never recompressed). `entries(rewriting:)` still decompresses
each entry once, but only to check its CRC against what the source archive's
own central directory claims — the check unpacking used to give for free —
and writes the *compressed* bytes it already had, not the decompressed ones
it checked. `EPUBArchiveWriter` now checks `mimetype` is stored explicitly,
because that stopped being automatic the moment an entry could carry a
source's own method forward.

**Measured — the nine fixtures, size before and after the round trip**, on
Erik's Mac: identical, byte for byte, every one of the nine — `1 619`,
`1 710`, `1 302`, `1 505`, `1 324`, `1 722`, `1 619`, `1 771` and `2 092`
bytes, unchanged. Proves the writer is not silently rewriting an unchanged
archive into a *different* unchanged archive; proves nothing about the
original bug, because none of these nine was ever compressed. A tenth,
hand-built fixture — three invented paragraphs (not from any real book),
DEFLATE-compressed the way a real EPUB tool compresses them
(`python3 -c "import zlib; …"`, `wbits = -15`, the same method
`InflateTests` already uses reference vectors from) — is what proves the
actual fix: **1 168 bytes before, 1 168 bytes after**, the entry still reads
as `.deflate`, against `1 823` bytes for the plain text alone. Neither writer
in this codebase can produce a DEFLATE stream on purpose, which is why this
one fixture is hand-built rather than written through either.

**Measured — the ~60 MB entry, again**, three runs: **1.82–1.90 s, +420 MB**
resident memory — **up** from the 1.79–1.89 s / +300 MB in the entry below,
not down. This is not a regression in the fix; it is what the fix actually
costs for an entry that was *already stored*, which this one is (it is
authored by `EPUBArchiveWriter` itself, `.raw`, for the same reason the nine
fixtures above never exercised the original bug). `entries(rewriting:)` now
decompresses an entry once for the CRC check and separately reads its
compressed bytes for the payload — two passes over the entry instead of one,
where before there was only ever one (decompress, and write what was
decompressed). For an already-stored 60 MB entry that is a real cost with no
matching benefit, because there was nothing compressed to protect. The entry
this fix actually helps — a genuinely DEFLATEd one — was never 60 MB in this
test suite and was not re-measured at that size. `docs/BACKLOG.md`.

## Sprint 10, part 1 – a ZIP archive writer for EPUBs, proven and not yet used · 21 September 2026

**The always-stored design below was corrected the same day** — see the entry
above. The +300 MB figure for the 60 MB entry no longer holds either way;
read the correction for the current number and why it moved the direction it
did.

`docs/adr/0021-…` allows Shelf to write into an EPUB, on request, once a
command exists for it. This is the part that comes before any command:
`ZipArchiveWriter` (a stored-only ZIP writer that refuses ZIP64 conditions
by name rather than truncating a real archive) and `EPUBArchiveWriter` (the
one EPUB-specific rule on top — `mimetype` first or refused). Nothing calls
either yet. No book file, real or synthetic-but-kept, was written by this
session; every archive below lives only in a test's memory.

**Proven — the strict round trip.** Every fixture is built with
`EPUBArchiveWriter` itself, read with `ZipReader`, handed straight back to
`EPUBArchiveWriter` unchanged, and read a second time: same entry names,
same decompressed bytes, not merely "opens again". 723 core tests, up from
701 — an EPUB 2 and an EPUB 3, no cover, a cover the OPF names but the
archive lacks, an OPF outside `OEBPS`, deep paths with an umlaut and a
Cyrillic name, a file the manifest never mentions, a `META-INF/
encryption.xml` DRM announcement, and a ~60 MB entry, plus the refusals:
`mimetype` missing, `mimetype` not first, `mimetype` twice, and a
ZIP-encrypted entry (which nothing in this writer can honour, so copying
one forward is refused rather than attempted).

**Measured — the ~60 MB entry**, on Erik's Mac, `swift test` (`-Onone`,
unoptimised — a release build would read faster):

| | |
|---|---|
| the round trip (read, rewrite, read again) | 1.79–1.89 s across three runs |
| resident memory during it | +300 MB |

`ZipReader` holds a whole archive as `[UInt8]`; this writer builds a whole
new `Data` the same way. For a 60 MB entry that is roughly five times its
own size in memory at the round trip's peak — every one of read once,
decompress, hold as `[Entry]`, write once, read again, touches the full 60
MB. Uncomfortable enough to name, not urgent enough to redesign before a
command exists that would actually feel it: `docs/BACKLOG.md`.

## 1.0.0

Sprints 1–9, summarised from the sections below rather than restated:

- **A library**: import EPUB, MOBI, AZW3, PDF, CBZ and CBR (Sprint 1, 4);
  metadata editing field by field, with undo (Sprint 2a–2c); shelves, search
  and acting on many books at once (Sprint 2c); renaming and merging authors,
  series, publishers and tags, and `Organize Library…` to bring the folders
  into step (Sprint 8).
- **A cover**: set, drop, take from the book file, or download it — four ways
  in, one path underneath, with the old picture going to the Trash rather than
  being overwritten, and ⌘Z to put it back (Sprint 9).
- **Calibre**: `File ▸ Import from Calibre…` reads a Calibre library through a
  copy of `metadata.db`, never in place; export writes Calibre's own OPF
  schema back out, with a mapping so shelves and read status survive the trip
  too (Sprint 3, 8).
- **Online metadata**: ⌘E asks Open Library and Google Books, shows old beside
  new with the source on each line, and ticks only what fills a gap
  (Sprint 6).
- **Devices**: send books to an e-reader, verified by hash on both sides
  before a transfer counts, with deletion only after a confirmation that
  names every file (Sprint 5).
- **English and German**, everywhere the app itself speaks, with tests that
  fail on a missing translation rather than falling back to English silently
  (Sprint 7).
- **Accessibility and contrast**: every control has a name, every colour
  passes WCAG AA, checked by `make accessibility` and `make contrast` rather
  than by eye (Sprint 7).
- **What it does not do, on purpose**: no reader, no format conversion, no
  writing into a book file ever, no touching DRM beyond detecting and badging
  it.

Not signed or notarised — see the README's "If you were handed a build
instead of building it" and `docs/RELEASE.md`. The tag `v1.0.0` is set by
Erik, not by this changelog.

## `make lint` now enforces the no-foreign-shelf guard · 21 September 2026

Sprint 9 pulled the guard against ending a Shelf a script did not start into
its own file (`Scripts/no-foreign-shelf.sh`) and sourced it into eighteen
scripts — sixteen of which never actually called it. Those sixteen were fixed
by hand; nothing stopped a nineteenth script from repeating the mistake, and
one had: `Scripts/runbook-proof.sh` opens a Shelf instance for its "refuses a
library from the future" demonstration and had its own ad-hoc `pgrep -x Shelf`
check instead of the shared guard.

`Scripts/check-shelf-guard.sh`, run by `make lint`, greps every script under
`Scripts/` for a line that starts a Shelf instance and fails, naming the file
and the line, if `require_no_foreign_shelf` is not called first. Demonstrated
both ways: green against the repository as it stands, red with the call
removed from one script (`Scripts/calibre-shot.sh`, restored after). Fixed
`runbook-proof.sh` to source the guard and use it — as a soft check, since
that one section of a much longer proof run should skip itself rather than
abort the whole script, which is what its ad-hoc check already did.

## The 5 000-book proof, after the schema change · 19 September 2026

Sprint 9 changed the database schema (`v3-cover-generation`) and the OPF
format (`shelf:cover_generation`) for the first time since the closing run.
Both are exactly what `make proof` and `make release-dry` exist to catch, and
neither had been run against this sprint's changes until now. Both are green.

### Measured — `make proof`, 4 996 synthetic books

Every section passed with **0 failures** — import, digest verification,
index rebuild, 200 metadata edits, search, 1 000 shelvings, an organise
killed and resumed, every format Shelf reads, four e-reader disk images, a
transfer killed and resumed, a card with no room, and the archive/books/
Calibre exports each re-imported and compared book by book.

| | |
|---|---|
| import, 4 996 books | 651 MB · 77.9 s |
| index rebuild from the folders | 4 996 books · 14 s |
| one metadata edit, 200 books | median 2.9 ms · 95th 8.0 ms · worst 16.7 ms · over the 50 ms target 0 of 200 |
| search 4 996 books for a tag five seconds old | median 0.7 ms |
| a library of every format (EPUB, MOBI, AZW3, PDF, CBZ, damaged files) | import 21.7 s · rebuild 2.9 s |
| the archive export re-imported into an empty library, compared | 4 996 of 4 996 agree on title, authors, rating, read status, series, shelves, tags |
| hard-link export | 5.3 MB actually copied · 9 896 hard links · 0 second copies |

**What Sprint 9 specifically was asked about:**

- **The `v3-cover-generation` migration's cost against an already-populated
  index.** Simulated rather than waited for — a copy of the finished 4 996-row
  index had the column dropped and the migration's own record removed, so
  reopening it made GRDB re-apply `v3-cover-generation` for real, against a
  populated table this time, instead of the empty one every fresh library's
  first open already migrates against. Three runs each: **≈180 ms with the
  migration to run, ≈120–200 ms without** — the same range, not a
  measurable difference. Expected: `ALTER TABLE … ADD COLUMN … DEFAULT 0`
  is metadata-only in SQLite for a constant default, so it does not scale
  with row count. Verified the migration actually ran each time (the
  recorded migrations and the column both confirmed after) rather than
  trusting that it should have.
- **Whether opening still has Sprint 8's times.** `SHELF_TIMING=1` against
  this run's own 4 996-book library: **index read 1 028 ms cold, 907 ms on a
  second launch**, against Sprint 8's 738 ms. Slower, by 23–39 %, and **I
  cannot honestly attribute that to Sprint 9's one extra integer column** —
  this Mac's disk was at 98–100 % capacity throughout both readings,
  immediately after `make proof` itself had written and deleted several
  gigabytes, which is exactly the condition APFS is known to slow down
  under. I did not re-measure on a quiet, non-full disk, which is what a
  clean comparison needs. Assumed, not verified: the extra column is one
  `INTEGER` among the dozen-plus `books` already carries per row and is not
  a plausible source of 170–290 ms across 4 996 rows on its own.

**What this session created and removed, under `~/Library/Caches/Shelf/`:**
`synthetic/` (the 5 000-book library and its exports, ADR-conventional path
`make proof` always uses) and `migration-v3-measure/` (the rollback copies
above), both removed with `make synthetic-clean` and `rm -rf` respectively
once their numbers were recorded — disk space ran to within 3 GiB free
during the export section's peak (a 4 996-book library copied three ways at
once) before recovering as the script's own cleanup ran. `release/`
(154 MB) is `release.sh`'s own standing output path, already holding a
build from before this session; this session's `make release-dry` rebuilt
it in place, as the tool always does, and it was left rather than removed.

### Measured — `make release-dry`

Green through everything a Developer ID does not gate: test and lint,
ad-hoc archive, **universal binary (x86_64 and arm64)**, valid signature,
**hardened runtime on**, entitlements written, zipped. Notarise and staple
skipped and said so, exactly as `docs/HANDOFF.md` describes.

| | |
|---|---|
| app bundle | 13 MB |
| zipped | 5.7 MB |
| code signature | `adhoc, runtime` — valid on disk, satisfies its Designated Requirement |

Not measured: notarisation and stapling themselves, which need the
Developer ID certificate only Erik can make (`docs/HANDOFF.md` §1).

## Sprint 9 – a cover can be changed · 19 September 2026

Not in the plan. It came out of using the program: everything about a book
could be corrected except its picture. `⌘E` could fetch a cover **once**, and
only into a folder that had none, so an import that took the picture out of the
wrong one of a book's four formats was permanent.

### What a person can do now

Four ways in, all of them on the cover in the inspector, all of them one path
underneath (`LibraryModel.applyCover`):

- **`Set Cover…`** — the open panel: PNG, JPEG, HEIC, TIFF, GIF, WebP.
- **A picture dropped on the cover** — from the Finder as a file, or dragged
  out of a web page as bytes.
- **`Take Cover from Book File`** — out of the book again. EPUB, MOBI and AZW3
  through the same reader the import uses; a PDF as page 1 rendered; a CBZ as
  its first image. A book with several formats is **asked which**, because an
  EPUB and a PDF of one book carry two different pictures.
- **`Download Cover…`** — now offered over an existing cover, which Sprint 6
  refused outright ([ADR 0020](docs/adr/0020-a-cover-may-be-replaced-and-what-guards-it-instead.md)).
  The button says **Replace Cover** rather than *Use This Cover*, above the
  preview of what it would write.

**What lands in the Trash:** every `cover.*` that was in the folder — all of
them, not the first one found. A disposal that cannot take one means nothing is
written and nothing is lost. Shelf does not overwrite a cover.

**What ⌘Z does:** puts the previous picture back, byte for byte, because the
bytes are captured before anything moves. Undoing the *first* cover on a book
takes the file away again, so the folder and the book cannot end up saying
different things. The Edit menu reads **Undo Cover**.

**What is never touched:** the book file. A cover is a file beside it.

### Measured, on this Mac

| | |
|---|---|
| tests | **701**, from 679 — 25 added, 3 deleted with `OnlineCover` |
| a 3 200 × 4 800 PNG set as a cover | → `cover.jpg`, **1 067 × 1 600, 46 KB** (from 271 KB) |
| a 900 × 600 JPEG, under the ceiling | written **byte for byte identical**, 23 KB |
| `Take Cover from Book File` → PDF | page 1 at **666 × 1 000**, 18 KB |
| `Download Cover…` over an existing one | Open Library's 1949 jacket, **330 × 500**, 79 KB |
| the ceiling | 1 600 px on the long edge, = 1.6 × the largest tier the pipeline decodes (ADR 0005) |

The grid cell **and** the inspector showed each new picture at once; it was
still there after quitting and relaunching, and after
`Library ▸ Rebuild Index from Folders`. The sidebar's `Missing Cover` went
2 → 1 when a coverless book was given one and back to 2 on ⌘Z. `Google Books
answered 429`, as it has to every request this project has ever made, so the
download was measured against Open Library alone.

### Five things that were already broken, and are fixed on the way

1. **`coverRefreshRequest` had no reader at all.** It has been incremented
   since Sprint 6 and nothing watched it, so a cover fetched from the net
   changed the folder while the inspector went on drawing what it held.
2. **The grid cell's task key was book-and-size.** A replaced cover never made
   the cell ask again — nothing about the cell had changed, as far as SwiftUI
   could see.
3. **Only the first `cover.*` was displaced.** A folder holding `cover.jpg`
   beside `cover.jpeg` — ordinary in a Calibre folder grown over years — kept
   the second, and because `jpeg` is searched before `png`, the survivor was
   then drawn *in preference to* the picture just written.

The last two were found by **looking at the screenshots**, not by any test:

4. **The grid cell kept the replaced picture after ⌘Z**, with the restored one
   in the inspector beside it. The generation is written before the picture, and
   writing it is what invalidates the view, so the cell woke while the old file
   was still on disk and was never woken again. It watches `coverRefreshRequest`
   now, like the inspector.
5. **Every field name in the Fetch Metadata sheet was English in a German
   window** — Title, Authors, Publisher, Published, Language, ISBN, Tags, down
   the whole sheet. `Text(proposal.label)` drew one of the core's own words
   verbatim while the accessibility label three lines above it put the same
   string through `Loc.core`. Since Sprint 6, and invisible in English.

### How it is built

The generation lives **in the book**, so in `metadata.opf`
(`shelf:cover_generation`, absent while it is 0), cached in the index by
migration `v3-cover-generation`. That is what survives a rebuild: a number the
index alone remembered would be thrown away with the cache it belongs to, and
the grid would go back to a thumbnail of the picture just replaced.

The **core has no image code and did not grow any**. `CoverImageRule` decides
whether bytes may be written as they are or re-encoded and to what size — a
pure function, tested on Linux — and `CoverImage` in the app measures the
picture with ImageIO and carries that out. The same split `EmptiedFolder` has
from `FolderDisposal`.

The number is written **before** the picture, and awaited. The two orders fail
differently: number-first leaves the cache *missing*, so it decodes the file
that is really there and shows it correctly, at the cost of one decode;
picture-first leaves the cache *hitting* a thumbnail of a picture that is gone,
which is the exact failure the generation exists to prevent.

### Not done, on purpose

A cover for a multiple selection, and a `Remove Cover` menu item. Both are in
`docs/BACKLOG.md` with the reasons.

### Photographed

Twelve pictures in each language, `docs/screenshots/sprint-9/` and `de/`, each
one judged in its README and each claim checked against the disk rather than
against the picture. `Scripts/cover-shot.sh` is the run.

### Fixed — ⇧⌘Z did nothing for a cover

Found by suspicion, not by a screenshot: set a cover, ⌘Z, and the Edit menu
read a disabled "Redo" instead of "Redo Cover" — a second ⌘Z replayed the
change forward again rather than doing nothing or a real redo. The cause was
`registerUndo` being called from inside `Task { await model.applyCover(...) }`,
which returns before that call ever runs, by which time AppKit's `isUndoing`
has already gone back to false; a `registerUndo` made after that point always
lands back on the undo stack, however it got there. `apply(_ change:)`, the
metadata path, already registers synchronously and fires its write in a
detached `Task` afterward — `applyCover` now does the same, split into an
awaited entry point and a synchronous one `registerUndo`'s closure calls
directly (`performCoverUndo`).

Verified by driving the real window before and after: the Edit menu now reads
**Redo Cover**, enabled, and a full round trip (⌘Z, ⇧⌘Z, ⌘Z again) alternates
**Undo Cover** / **Redo** correctly. `docs/screenshots/sprint-9/13-after-redo.jpg`
and `13-edit-menu.jpg` are that proof, added to the existing set.

### Fixed — a failed picture write left the generation bumped for nothing

The generation is written before the picture on purpose (see "How it is
built" above), but nothing put it back if the *picture* write then failed —
a disposal that cannot move the old cover, a full disk. `metadata.opf` would
go on claiming a replacement that never happened: harmless to the window (the
cache miss it forces just re-decodes the unchanged file) but a small,
permanent lie in the one file that is supposed to be the truth about the
book. Fixed by writing the generation back down when the picture write
throws — `CoverReplacement.commit`, pulled into the core specifically so the
three-step sequence (bump, try the picture, revert on failure) could be
tested rather than only asserted. Two tests.

### Fixed — a script could end a Shelf it did not start

`make smoke` quit a Shelf that was already running and was not its own —
CLAUDE.md rule 6, and the session that found it said so at the time. The
cause was not unique to `smoke.sh`: nine scripts tried to make an existing
instance go away (Escape, then repeated `quit`) on the assumption that the
only Shelf which could be running is a leftover from an earlier run of the
same script — which `pgrep` cannot tell apart from a window opened on
purpose. All eighteen scripts that launch the app now share one guard,
`Scripts/no-foreign-shelf.sh`, that refuses outright and names the pid
instead of trying anything. Verified directly: with a Shelf started by hand,
`make smoke` failed immediately and left it running, untouched.

### What is not tested

**The picture half.** `CoverImage` — measuring a file, scaling it, re-encoding
it, and therefore everything specific to HEIC and TIFF — needs ImageIO, and
`ShelfCoreTests` is the only test target this project has and it runs on Linux.
The *rule* it carries out has six tests; the carrying out has none, and its only
evidence is a run of `Scripts/cover-shot.sh` checking pixel sizes against the
disk. An app-side test target is the honest fix and does not exist yet.

## The closing run before v1.0 · 19 September 2026

Everything below was asked for *after* Sprint 8 was pushed, and every number in
it was measured on the commit it is quoted for.

### Measured — Linux, and CI, both for the first time in five sprints

**Sprint 8's tests on Linux.** Docker started for this run and stopped again at
the end of it. `swift:6.1`, against a `git archive` of the commit itself:

| | |
|---|---|
| build | **58.4 s** |
| `ShelfCore` tests | **679 green**, 3.8 s |
| red | none |

**CI runs again, and the app build ran for the first time ever.** Both
repositories are public now (`Erikemmer/Shelf`, `Erikemmer/SlateKit`), so the
two reasons the workflow was a no-op are gone: there are no Actions minutes to
pay for, and a public package resolves without credentials. Out went the
`SLATEKIT_TOKEN` gate, its four `if:` conditions and the `git config … insteadOf`
line.

| job | |
|---|---|
| App build (macOS) | **1 m 31 s** |
| ShelfCore tests (Linux) | 1 m 55 s |
| ShelfCore tests (macOS) | 1 m 20 s |
| the whole run | **1 m 59 s**, all three green |

**It found two real defects on its first day**, and both are the same kind:
code that compiles on the Mac it is written on and not on the one CI runs.
Xcode 27's SDK annotates `NSImage` as `Sendable`; Xcode 16.4's does not.

1. `DecodedCover` was a plain `Sendable` struct holding an `NSImage`. It is
   `@unchecked Sendable` now, with the promise it can actually keep written
   down: the image is made once from an immutable `CGImage` and nothing ever
   mutates it.
2. `CoverLoader` is an `actor` and returned `NSImage?`, so the result crossed an
   isolation boundary. It hands back the `DecodedCover` it already held
   internally — one `?.image` at four call sites, and no change to the cover
   pipeline (ADR 0005).

Nine sprints of building the window on one Mac hid both. That is the whole
argument for the job.

### Fixed — an emptied author folder goes to the Trash, not to `removeItem`

Asked whether `Organize Library…` really only removes folders it emptied itself
and whether they go to the Trash. Two of the three answers were yes by
construction; the third was plainly no.

**It was `removeItem`.** "Nothing is deleted outright" has to be a rule about
the mechanism and not only about the intent, so the act is behind
`FolderDisposal` — `FileManager.trashItem` on a Mac — and the runner has no
`removeItem` on that path at all. A test proves it by handing the runner a
disposal that moves nothing and then finding the folder still on the disk. A
disposal that *fails* leaves the folder where it is **and** keeps it out of the
report: a folder reported as gone that is still there is worse than one that
was never touched.

The seam also answers a question the core could not: `trashItem` is Darwin's
and is not in swift-corelibs-foundation, so a core calling it directly would not
build on Linux.

**And `contents.isEmpty` was too strict in a way that mattered.** The Finder
writes a `.DS_Store` the moment somebody opens a folder to look at it, so
"looked at once" meant "never tidied". `EmptiedFolder` is a pure rule, tested on
Linux, over an **allow-list** of names the file system writes for itself —
never "anything beginning with a dot", because a dot file is how a great many
programs keep something that matters. `.gitignore` beside `.DS_Store` keeps the
folder; `.DS_Store` alone does not.

**Verified against the real Trash**, and the check is worth recording because
the first one lied:

```
$ ls ~/.Trash | wc -l
0                     ← not "the Trash is empty". `ls` could not read it
                        at all (TCC), and `wc -l` swallowed the error.
$ osascript -e 'tell application "Finder" to return count of items of trash'
75                    ← including "Atwood, José", "Austen, Becky", … each with
                        a de-duplicating suffix from a repeated run
```

The same family as `grep -c` versus `grep -q` and `ps` in the user's locale: a
check that answers "0" when it means "I could not look". The Trash path works
from the sandboxed app, which is the case that mattered.

### Fixed — every count line in the window is German in a German window

The five Sprint 8 sheets photographed in German and looked at, one by one
(`docs/screenshots/sprint-8/de/README.md`). Two defects, and the first is eight
lines wide.

**The count lines were English.** "8 to move · 7 already right · 1 cannot be"
above a sheet whose every other word was German; the organise report's
headline; the export summary; and loudest of all, the import's
"FAILED: 3 files not verified". Eight lines in five sheets, each the most-read
line of its sheet, because the window drew the core's own `summary()` and
`headline` straight.

Those stay as they are — they go into the plain-text reports, which have to be
readable in ten years by whoever opens them rather than half-German.
`App/Shelf/Views/Summaries.swift` builds the *window's* line from translated
pieces, one `Loc.count` each, so the catalogue pluralises: "1 Buch", "2 Bücher",
no `== 1` anywhere. That is ADR 0016's rule. It reaches four sheets that were
not part of this task (Add Books, Send to Device) and they were done anyway,
rather than ship a release counting in two languages.

**And a mistake this project had already made once.** The merge sheet read
"Diese autoren durchsuchen" and "die derselbe autor ist", from `.lowercased()`
on a label: right in English, a spelling mistake in German, which capitalises
its nouns. `SidebarView` carries a comment about the identical slip from
Sprint 7, where "Alle Bücher" came out as "alle bücher zeigen".

**Nothing German is truncated or clipped anywhere.** German runs two or three
lines where English runs one or two, and every sheet grows to fit. Twelve
pictures and twelve accessibility trees, six per language.

### Measured — the closing run

`make proof` end to end, release build, against `~/Library/Caches/Shelf/synthetic`
— **every section green**, forty-six of them, including all of section 12:

| | |
|---|---|
| one author under three spellings, merged | 26 books rewritten, **40 under one spelling** |
| the index erased and rebuilt from the folders | 40, one spelling, nothing lost |
| two obstacles built on purpose | **both named** by the preview, neither moved |
| the organise killed mid-run, then resumed | 25 recognised as already moved · 173 moved · **0 failed** |
| EPUBs before / after · checksums | 4 996 / 4 996 · **every one identical** |
| orphaned folders · empty folders left | 0 · 0 |
| `Undo Organize` | **198 folders back**, checksums still identical |
| the archive imported into an empty library | **4 996 compared by UUID — the two agree on titles, authors, ratings, read status, series, shelves and tags** |
| a second export into the same folder | 14 892 unchanged, **0 written** |
| hard links: library / export / distinct inodes | 4 996 / 4 996 / **4 996** |

`make release-dry` at version 1.0.0: archived, signed ad hoc with the hardened
runtime on, verified, zipped to **Shelf-1.0.0.zip, 5 624 KB**. Steps 6 and 7 —
notarise and staple — are still skipped, and still for the one reason nothing in
this repository can fix: there is no Developer ID on this Mac.

### Not measured, and named

- **No real Calibre has read one of Shelf's exports**, unchanged from Sprint 8:
  running Calibre's importer over one would mean writing into Erik's own
  Calibre library.
- **The five sheets Sprint 7 left unphotographed in German** are still
  unphotographed — Send to Device, Delete from Device, the Calibre protocol,
  Fetch Metadata, orphaned folders. Their count lines are fixed with the rest;
  what no test can answer is their *layout*.
- **The app build is `Debug` and unsigned on CI.** It answers "does it compile
  and link", not "is it shippable"; `Scripts/release.sh` asks the second
  question and needs Apple's two credentials.
- **This session's own Trash.** Roughly forty empty author folders from the
  throw-away shot libraries are in it, left there on purpose as the evidence
  that the Trash path works.

## Sprint 8 – ordering the library, and the way out of it · 19 September 2026

Measured on Erik's Mac (M-series, macOS 15.6) against
`~/Library/Caches/Shelf/synthetic/` (the closing run, 5 000 books) and
`~/Library/Caches/Shelf/measure-library-8/` (the small libraries the window was
driven against, and the screenshots).

**Why there is a Sprint 8 at all.** Trying the program found a hole in the
concept rather than a defect in the code. Shelf could order a collection only
inside its own window: with one person in the library as "Sebastian Fitzek",
"Fitzek, Sebastian" and "S. Fitzek", those were three authors in the sidebar
and three folders on the disk — and every answer Shelf gave was correct,
because three different strings really are three different strings. A library
manager that can only ever agree with the mess is not managing anything. The
second half is the *Leitlinie*'s third principle, no lock-in: a library kept in
Shelf has to be able to walk out of Shelf without losing what was maintained
in it. [ADR 0018](docs/adr/0018-renaming-merging-and-organising-are-deliberate-operations.md)
and [ADR 0019](docs/adr/0019-export-the-opf-decides-what-an-export-is.md).

**675 core tests, up from 631.** `make proof` green end to end, all 46 sections.

### The three things Sprint 7's runbook left open

| | |
|---|---|
| a resumed transfer reports as failures the files it wrote itself | **fixed** |
| a German sentence on the way back to Calibre is broken | **already fixed in Sprint 7**, and checked again: all seven verb phrases that fill `Could not %1$@: %2$@` are proper German zu-infinitives |
| the read status and the shelves do not travel to Calibre | **fixed**, through the "For Calibre" export |

**The resumed transfer.** The manifest is written every twenty files, so an
untidy death — a crash, a power cut, a pulled cable — can leave up to nineteen
files on a card that no manifest names; the next run then reported each of them
as `FAILED … a file of that name is already on the device`. Nothing was ever
lost, but "Failed" is the wrong word for "I had already done that", and the
manifest stayed short for the life of the card. The planner now asks what is at
a destination path before it plans a copy there (`DeviceFileProbe`): **the size
first, and the digest only if the size already matched**, so a tidy card is
asked nothing at all. A file whose bytes are the book's is skipped as
`alreadyOnDevice` and carried in `TransferPlan.adopted`, which the runner
records into the manifest *before* it copies anything. A file of the same name
whose bytes differ is neither claimed nor written over — that is the second of
the two tests, and the more important one.

### Added — three spellings of one author can become one

A sidebar row's context menu has `Rename “…”…` and `Merge into…`, for authors,
series, publishers and tags. Publishers had neither a sidebar section nor a
facet and got both; `LibraryIndex.publisherFacets` is a `GROUP BY` over a
column rather than a join, because nothing hangs off a publisher — no sort key,
no second name, no membership.

**Shelf proposes nothing.** No similarity detection, no "we found 12 probable
duplicates". ADR 0018 writes down why: the cost of being right is a list
somebody reads anyway, and the cost of being wrong is 40 books filed under a
name that never existed — and because a merge writes 40 OPFs, undoing it is a
second bulk write rather than a non-event.

The sheet rather than marking rows in the sidebar, because the sidebar draws
**twelve** rows per section and a real library has hundreds of authors: three
spellings of one person are mostly not on screen. ⌘-click stays unclaimed for
the filter-combining the backlog still wants.

Two things it deliberately does not do: it does not move a folder (ADR 0007),
and it does not touch a book file. It *offers* the organise afterwards — "40
books changed — tidy the folders now?" — as a banner that opens the preview.

| | |
|---|---|
| 40 books given one of three spellings, then merged | 26 rewritten (14 already read that way) |
| the index then erased and rebuilt from the folders | **40 books, one spelling, 0 lost** |
| spellings of "Fitzek" left in the library afterwards | 1 |

That second row is the one that matters: the merge went into the OPFs, not only
into the index, so the index is still nothing but a cache (ADR 0001).

### Added — `Organize Library…`, the first thing here that moves a folder

Everything else in this program is a copy or a read. So it is written to the
import's rules rather than to a `moveItem` and a hope (ADR 0002): the preview
is the value the runner is handed, every folder is hashed before and after, a
manifest is written as the run goes on, an interrupted run resumes, and
`Undo Organize` is that manifest walked backwards — newest first, because
undoing `B → C` is what frees `B` for the undo of `A → B`.

**Folders move; the bytes inside them are not touched**, and the digests on
both sides are what say so rather than a sentence in a document.

**Capitals are measured, not assumed.** `VolumeCase.folds(at:)` writes one
empty file with a mixed-case name, asks for it by the other spelling, and takes
the answer away. APFS is case-insensitive by default and case-*sensitive* if it
was formatted that way, and a library can sit on either — guessing from the
platform gets an external disk wrong. On a folding volume `Fitzek` → `fitzek`
is not a move between two folders but one folder spelled differently, and a
direct `moveItem` is a write into itself; such a move goes through a third name
in `.shelf/moving/`, and **that one move is written into the manifest before it
is entered**, because it is the only operation in the whole feature with a
halfway state.

**One `removeItem`, with four guards**: an author folder this run has just
emptied, a direct child of the root, not `.shelf`, holding nothing at all — a
`.DS_Store` counts as something. Without it an organise tidies the books and
litters the library with an empty author folder per merge. Every one is named
in the report.

Measured against the closing run's library, **4 996 books**:

| | |
|---|---|
| the preview, over the whole library | 196 to move · 4 798 already right · **2 cannot be** |
| killed mid-run (`SHELF_EXIT_AFTER=25`, the untidy way) | 4 996 EPUBs on disk, **20** in the manifest |
| the same run again | 25 recognised as already moved · 173 moved · **0 failed** |
| EPUBs before and after | 4 996 / 4 996, **every checksum identical** |
| orphaned folders afterwards | **0** |
| empty folders left behind | **0** |
| a rebuild from the folders | 4 996 books, 0 unreadable, index and folders agree |
| `Undo Organize` | **198 folders back**, every checksum still identical |

The gap between 20 in the manifest and 25 moved is the point of the resume.
Those five were moves no manifest knew about, and before the fix `Undo
Organize` could not have put them back; the resumed run **adopts** them, digests
and all — the same word and the same argument as a resumed transfer adopting
the files it wrote itself.

### Added — a library can leave Shelf and come back whole

`File ▸ Export Library…`, three presets named for the question they answer:
**Archive**, **Just the books**, **For Calibre**. Formats, structure, name
pattern and a switch each for `cover.jpg` and `metadata.opf` stay visible
underneath.

**The `metadata.opf` is what makes an export an archive**, and that is the whole
of ADR 0019. The ratings, the read status, the tags and the shelves are not
inside any book file — a book file is never written — so an export without the
OPF is not a lesser export, it is a different kind of thing. "Just the books"
says so in the dialogue before anything is pressed, and again in the report
written into the folder.

**And an import now believes a `metadata.opf` beside a book**, which is the
other half: writing the OPF is useless if nothing reads it back.
`SidecarMetadata` also makes an import of somebody's Calibre *folder* carry its
ratings and series across. `shelf-tool import` walks sub-folders now, and both
import paths register the shelves in `library.json` and the index **before** the
books — the index skips a shelf path it has not been given, silently (ADR 0008).

**The way back to Calibre stops losing things.** "For Calibre" writes the same
files and additionally maps each shelf to `<dc:subject>Shelf/Fiction/Sci-Fi` and
a read book to `<dc:subject>Read`. A tag rather than a custom column, because a
custom column must be declared in Calibre's `metadata.db` first and Shelf never
writes there (ADR 0009). It is a mapping and says so: Shelf's own fields are
written beside the tags, so the same folder still re-imports into Shelf without
loss.

**The most important measurement of the sprint**, against 4 996 books:

| | |
|---|---|
| archive export | 14 892 files · 1.3 GB |
| imported into a **new, empty** library | 4 996 books · 16 shelves registered before them |
| the two libraries compared, book by book, by UUID | **4 996 compared · they agree on titles, authors, ratings, read status, series, shelves and tags** |

And the rest:

| | |
|---|---|
| "Just the books" | 4 996 EPUBs, **0 OPFs**, and its report says what stayed behind |
| "For Calibre" | **1 000** OPFs carry a shelf as a Calibre tag, 6 carry `Read` |
| a second run into the same folder | **14 892 unchanged · 0 written** |
| a third run | the same |
| hard links, same volume | 9 896 links · **5.3 MB copied** instead of 1.3 GB |
| EPUBs in the library / in the export / distinct inodes across both | 4 996 / 4 996 / **4 996** |

That last row is the whole claim: no second copy of a single book exists. Hard
links are safe here and nowhere else because a book file is never written, so
the two names cannot come to differ. **A hard-linked export is not a backup** —
one copy of the bytes with two names — and the report says how many links it
made so the difference is visible rather than assumed.

### Fixed — a defect since Sprint 1, found by asking a path whether it was legal

`BookFolderName.titleComponent` and `.fileName` both cut a name to the 255-byte
limit. **`.authorComponent` did not.** A `dc:creator` holding a sentence — real
EPUBs do this, and `AuthorSort` turns it into one long component — made a folder
the file system refuses, which failed the *import* of such a book and not only
its organise. It had been so since Sprint 1 and was found because Sprint 8 asks
every component of a built path whether it is legal.

### Fixed — two things only a round trip could find

Neither would have been found by a test of the export alone, because each half
was behaving reasonably. Both are in ADR 0019.

**Filling the OPF's gaps from the book file was wrong.** A book with **no
author** has an OPF that says so by saying nothing; treating that as "the OPF
did not mention it" let the file's own guess through — and the file's guess came
from its *name*, which the export had just written from the very metadata being
reconstructed. One book came back with its title as its author. An empty field
in a record is a statement, not a silence, so the sidecar wins outright now.

**An export that does not tidy its own output corrupts the next import.** A
retitled book has a new file name and the old file stayed beside it; that copy
sorts first, is read first, and wins. A round trip came back with titles the
library had corrected weeks earlier. Stale files are removed — only paths the
previous manifest names, only at the size it wrote them, every one named in the
report — and the folder a removal empties goes with it.

### Fixed — three things found by looking at the screenshots

`make organize-shots` drives the real window through four sheets and
photographs each. Looking at the pictures found three defects that no test had,
and `docs/screenshots/sprint-8/README.md` says which picture found which.

| | was | is |
|---|---|---|
| the merge sheet, with the target already correct | **"No book carries that name"** — with three books listed one line above, each saying "3 books" | "3 books already read that way — nothing to change" |
| the organise preview | the one book that **cannot** be moved was last in a scrolling list, below eight moves and below the fold | what cannot be done comes first, in the accent colour, with the book named |
| the export sheet's format row | eight checkboxes broke their own words to fit — **"EPU B"**, **"AZW 3"**, **"MOB I"** — and sat ticked *and* disabled while "All" was on | "All" stands alone with "every format of every book"; the boxes appear only when it is off, wrapped five to a row |

A fourth thing was found by the *script* rather than the pictures, and is worth
writing down because it wasted two runs: **a right-click below the window opens
nothing, and says nothing about having opened nothing.** The sidebar caps each
section at twelve rows, so in a 30-book library the tag list alone pushed the
Authors section off the bottom. A posted scroll-wheel event does not reach a
SwiftUI `ScrollView` at all — the same limit `docs/BACKLOG.md` already records
for the table — so there was nothing to scroll with. The shots library is
sixteen books now, and the script prints the point it is about to click.

### Not measured, and named

- **No real Calibre has read one of these exports.** The OPFs are quoted, the
  schema is the one Calibre writes and `CalibreReader` reads back, and the
  mapping is checked by a test — but running Calibre's importer over an export
  would mean writing into Erik's own Calibre library, which is not this
  project's to touch. Unchanged from Sprint 7's `docs/RUNBOOK.md` §6.
- **The German window has not been photographed** for any of the five new
  sheets. Their strings are in the catalogue and the tests cover them; what a
  picture would add is whether the layout survives longer German words.
- **No export has been run to another volume**, so the copy-across-volumes path
  and the hard-link fallback are exercised only by the unit test's seam.
- **CI has still not run since Sprint 4.** Checked again: same "recent account
  payments have failed" after seven seconds.

## Sprint 7 – polish and release · 18–19 September 2026

Measured on Erik's Mac (M-series, macOS 15.6) against
`~/Library/Caches/Shelf/measure-library-7/` (the German screenshots and the
release path), `~/Library/Caches/Shelf/measure-library-7b/` (accessibility,
contrast, the arrow keys) and `~/Library/Caches/Shelf/synthetic/` (the closing
run, 5 000 books).

**Sprint 7 is finished and v1.0 is ready to be released.** The version in
`project.yml` is `1.0.0`; the tag `v1.0.0` is not set and will not be without
Erik's word. What is still open is what only Erik can supply — a Developer ID,
a CI that runs, and a real e-reader — and `docs/HANDOFF.md` is the list.

### Fixed — the six things v1.0 was not going to carry

`docs/BACKLOG.md` named six that should not reach a 1.0. Five are fixed and one
is closed as not reproducible, with the measurement rather than an argument.

**`Missing Cover` counted every book in a freshly imported library.** It was
answered from the *decoded-cover cache* — one directory read, which is what made
it cheap, and empty until something had been drawn — so a new library reported
every book as missing a cover and then corrected itself as the grid filled in.
Wrong, and then quietly right, which is worse. It is a question about the
folders now (`CoverFile.booksWithACover`), asked in `reload` before the totals
and the filter that read it, off the main actor. Measured against the 26-book
library with its cover cache deleted:

| | before | after |
|---|---|---|
| four seconds after a cold start | 26 | **15** |
| sixteen seconds later | 15 | **15** |

The walk it costs, measured over the closing run's library: **37 ms for 4 996
book folders**, off the main actor, at the four moments the answer can change
for more than one book at once — opening, an import, a rebuild, a cleared cache.

**`Published` read blank across a selection** where `Publisher` beside it read
"Mixed", and a blank says neither "they differ" nor "none of them has one". The
field rule answers three things now — `SharedValue.same`, `.noneHasOne`,
`.mixed` — and the row says "None of them". `sharedText` stays beside it,
because an editable field wants exactly what it gives: a string for the box and
an empty one to leave the placeholder showing.

**Four table columns had no arrow.** Tags, Format, Read and Size have been drawn
since Sprint 2c and could not be sorted by, because `BookSort` had no case for
them — and a column that sorted the loaded rows itself would have put the table
in one order and left the grid and the sort menu in another. `BookSort` has ten
cases now and the order still comes out of the index. Tags and Format sort by
the very string their column draws; untagged books go last either way round, as
books with no series already did.

**`ZipWriter`, `MinimalPNG` and the five `Synthetic…` builders left the shipped
core.** The backlog said 385 lines; it was **1 343**, in seven files, and every
one of them was `ShelfCore` public surface that production never called and the
Linux job compiled into what the app links. `ShelfFixtures` is a target of its
own that `ShelfCoreTests` and `shelf-tool` depend on and `App/Shelf` does not,
so a `ZipWriter` in the window would not compile; two tests say the same by
name, so a copy pasted in fails too. The API decision the entry warned about
came to four symbols — `OPFDocument.escaped`, `.escapedAttribute` and
`EPUBMetadata.containerPath` / `.encryptionPath` — published because a fixture
has to write exactly what the reader reads.

**The click on a cover and the search field: closed as not reproducible.**
`Scripts/keyboard-proof.sh` drives the real window — search, click a cover,
press R, read the status back out of the index — and reads **5 of 5** for the
click and 5 of 5 for Escape, now on a third library and on a build whose keys
all go through `EditingKeyMonitor`. Sprint 2c measured 5 of 5 before and after
its own change as well. Three measurements that cannot make it fail are enough.

**The bare "Undo" is not a fetch's defect at all**, and that is the sixth. It
was written down as one, with "an edit made in the inspector still names
itself" beside it. Measured with the menu opened before it was read — macOS
updates an item's title when its menu is shown, so a cold read gives the last
title drawn:

| what was done | did it edit? | the Edit menu offered |
|---|---|---|
| a fetch applied | yes, `<dc:date>` appeared | `Undo` |
| R pressed on a selected book | yes, read books 1 → 0 in the index | `Undo` |

So SwiftUI's own Undo item never carries the name, whatever made the change.
The likely fix is `CommandGroup(replacing: .undoRedo)`, and it was **not**
attempted before v1.0 on purpose: replacing the standard Undo puts ⌘Z inside a
text field on the line for a cosmetic gain. It stays in the backlog, now with
what it actually is.

Two more found on the way. `MetadataChange.actionName` was handed to
`setActionName` **untranslated**, so a German window would have offered
"Widerrufen Title"; and the name for a change of several fields at once was a
bare literal no test could see, which is now `MetadataChange.severalFields` and
walks into the catalogue with every other core sentence. 631 core tests, up
from 613.

### Fixed — the script that pins the language did not pin the language

`Scripts/app-language.sh` wrote `AppleLanguages` into Shelf's own defaults
domain and removed it again in a trap. That is the documented way and it does
not reliably work for a sandboxed app. Measured on 19 September 2026:

```
$ defaults write de.erikemmer.shelf AppleLanguages -array en
$ defaults read de.erikemmer.shelf AppleLanguages
( en )
$ plutil -extract AppleLanguages xml1 -o - ~/Library/Containers/…/de.erikemmer.shelf.plist
Could not extract value … No value at that key path
→ the window comes up in German: "Ablage", "Bearbeiten", "Bibliothek"
```

`cfprefsd` hands the value back to the next `defaults read` and never writes it
where the app looks. It worked often enough to be believed — a script that
spends a second finding the app bundle between the write and the launch usually
won the race — and failed silently when it did not, which is the worst way for a
guard to behave. It cost two runs here before the plist was looked at.

**The language goes on the command line now**: `open -a Shelf <library> --args
-AppleLanguages '(en)'`. The argument domain outranks every other, is read by
the process itself at launch, and touches no preference at all — so there is
nothing to put back and nothing to lose. Thirteen scripts changed; each passes
`${SHELF_LANGUAGE_ARGS:-}` at its own `open`.

### Added — `docs/RUNBOOK.md`, with every path run once and its output quoted

Twelve of them: what is truth and what is cache, back up, restore, rebuild the
index, move to another drive, the way back to Calibre, a crash in the middle of
an import, folders no book points at, a crash in the middle of a transfer, where
the reports and the logs are, the three refusals to open a library, and the one
thing Shelf never does.

`make runbook` (`Scripts/runbook-proof.sh`) **runs all of it** — against a
generated library of 20 books, a 400-book import it kills after six seconds, a
disk image for the other drive, a Kobo image for the transfer — and prints what
happened, so the quotes in the document can be checked rather than believed. It
works inside its own folder and detaches its own images.

Running it found three things a document written from the source would have got
wrong:

- **A resumed transfer reports as failures the files it wrote itself.** A
  transfer of 20 books killed after one second left 9 on the card and **0 of
  them in the manifest**; run again it said `Verified · 11 books · Skipped: 0 ·
  Failed: 9`, one line each for "a file of that name is already on the device".
  Nothing is lost — all 20 end up on the card, the `.part` is swept up, and
  `Device ▸ Show What Is on the Device…` finds the nine by name — but "Failed"
  is the wrong word for "I had already done that". In `docs/BACKLOG.md` under
  Sprint 5, with the fix named: the planner should recognise a file it would
  have written and skip it, rather than letting the copy fail.
- **The read status and the shelves do not travel to Calibre.** They are written
  as `shelf:read` and `shelf:shelves`, and Calibre ignores a meta it does not
  know. Everything else does travel, because Shelf writes Calibre's own schema.
  The runbook says which is which in a table rather than claiming a clean round
  trip.
- **A German sentence that had never been read aloud.** "Konnte from-the-future
  zu öffnen: …" — the frame `Could not %1$@: %2$@` was translated word for word,
  and German does not take a zu-infinitive that way. It is "Es war nicht
  möglich, „from-the-future“ zu öffnen: …" now. It is the app's *error* path, so
  no screenshot run had ever shown it; the runbook provokes one by opening a
  library whose `schemaVersion` is 99, which is also how §10 demonstrates where
  the log is.

### Measured — the closing run, against 5 000 books

`make proof` end to end on 19 September 2026, release build, against
`~/Library/Caches/Shelf/synthetic` — **every section green**, thirty-eight of
them, from generating the books to deleting from a device behind a confirmation
that names every file.

| | |
|---|---|
| generate 5 000 EPUBs | 20 s · 643.6 MB |
| **import 4 996 books**, hashed on both sides | **28.8 s** · library 1.3 GB |
| SHA-256 against `/usr/bin/shasum` | 3 of 3 agree |
| files in the source modified by the import | **0** of 4 999 |
| **erase the index and rebuild it from the folders** | **12.8 s** · folders with no readable book 0 |
| one metadata edit, 200 books | median **2.3 ms** · 95th 4.2 ms · worst 14.0 ms · over the 50 ms target 0 of 200 |
| search 4 996 books for a tag five seconds old | first (cold page cache) 1.2 ms · median **0.6 ms** · worst 0.7 ms |
| one shelf assignment, 1 000 of them | median 2.4 ms · worst 13.1 ms · over the 20 ms target **0 of 1 000** |
| 50 books tagged at once, then undone | 132.2 ms / 126.9 ms · 50 of 50 OPFs byte-identical again · 50 of 50 EPUBs untouched |
| the index thrown away, 1 000 shelvings asked of the folders | **1 000 of 1 000** back, 20 of 20 shelves, the empty one out of `library.json` |
| an import killed and resumed | one folder per book, nothing doubled, nothing orphaned |
| every format in one library (EPUB, MOBI, AZW3, PDF, CBZ, damaged files and all) | import 9.4 s · rebuild 2.9 s · one digest per format agrees with `shasum` |
| 250 books to a Kobo, read back off the card | 2 s · Verified 250 · Failed 0 · a second run sends nothing |
| the same to a Kindle, which reads neither EPUB nor CBZ | 212 sent, **38 refused for want of a format**, not one EPUB on the card |
| the library after all of the device work | byte for byte what it was |

**At the window**, same library, `SHELF_TIMING=1`:

| | cold (cover cache deleted) | warm (4 901 covers cached) |
|---|---|---|
| index read, 4 996 books | 738 ms | 738 ms |
| **every visible cover on screen** | **1 068 ms** after the open, 1 463 ms after launch | **1 106 ms** / 1 485 ms |
| peak memory, 30 s in | 316 MB | 212 MB |

CONCEPT §11 asks for under 2 s with a warm cache: it is 1.5 s from launch, and
the cold run is no slower — the first twenty covers are decoded out of the EPUBs
either way, and the cache is what spares the *other* 4 976. Peak memory against
the 1.5 GB the concept allows: **316 MB** while the warmer is working through
5 000 covers.

**An hour open, idle, on the 5 000-book library**, sixty readings a minute
apart. It does not grow; it shrinks:

| | |
|---|---|
| at the start, the warmer still working through 5 000 covers | **316 MB** |
| one minute in, the warmer finished | 185 MB |
| every reading from minute 3 to minute 47 | 185 MB, unchanged |
| minute 48 onwards | **147 MB** |
| after sixty minutes | **147 MB** |

The one step down at minute 48 is memory being given back, not taken: the
in-memory cover cache lets go of what nothing is looking at. There is no upward
trend anywhere in the hour — the highest reading after the warmer finished is
the same 185 MB as the first one.

Measured on the release build of 09:40; the two edits committed after it are a
comment and a `switch` that changes no behaviour. `make proof` was not running
at the time, so nothing else was competing for memory.

`make release-dry` at version 1.0.0: archived, signed ad hoc with the hardened
runtime on, verified, zipped to **Shelf-1.0.0.zip, 5 172 KB**. The entitlements
read back **out of the signed build**: app-sandbox, bookmarks.app-scope,
removable-volumes.read-write, user-selected.read-write, network.client. Five,
and no server entitlement — Shelf listens for nothing (CONCEPT §12). Steps 6 and
7 have still never run: there is no Developer ID on this Mac, and that is Erik's
to make.

**CI: still not running.** Checked again on 19 September on four pushes
(35426960588, 35427877179, 35429435673, 35432815462); every job ends after seven
seconds with "The job was not started because recent account payments have
failed or your spending limit needs to be increased". Five sprints now.

The substitute is the Swift container on this Mac, run against a `git archive`
of the commit itself: on `4e53102`, **build 36.0 s, 631 tests green on Linux** —
which is what the Linux job exists to check, and it covers the new
`ShortcutKey`, the four new sort orders and the whole `ShelfFixtures` split.

### Added — the window can be used without a mouse and read without perfect eyes

Accessibility was the largest thing Sprint 7 owed and nothing of it had been
touched. What follows was found by dumping the **accessibility tree of a
running window** and judging it, not by reading the source: `make accessibility`
(`Scripts/ax-proof.sh`) drives the app through ten views, writes each tree into
`docs/accessibility/`, and `Scripts/ax-judge.py` fails on a control with no
name, on a name that is an SF Symbol's identifier, and on a view that has
stopped holding a button it is supposed to hold.

**Against the build this sprint started from, that run had 21 findings in the
library window alone. It now has none, across ten views.**

| | before | after |
|---|---|---|
| controls with no name at all | 5 | 0 |
| elements announcing an SF Symbol's name | 16 | 0 |
| sidebar rows a keyboard can activate | 0 of 33 | 33 of 33 |
| views whose tree is committed as evidence | 0 | 10 |

The ten: the grid with its sidebar and inspector, the table, and the seven
sheets — shortcuts, orphaned folders, Fetch Metadata, Add Books, the Calibre
protocol, Send to Device, and what is on the device. The eleventh, the
confirmation that names every file before a deletion, is **not** here and
`docs/accessibility/README.md` says why: it exists only when there is something
on the card to delete, and this run sends nothing.

Most of the fixing happened in **SlateKit 0.4.0 and 0.4.1**, because most of it
was in components both apps draw — the sidebar row, the grid cell, the editable
row, the star rating, and the focus ring that `.buttonStyle(.plain)` takes away.
The pin moved 0.3.1 → 0.4.1. **Nothing there is an appearance change**: at rest
every control looks exactly as it did, and `SlateGridCell` gained one parameter
with a default that keeps what it always said.

What Shelf itself had to say:

- **A cover is one sentence, not four stops.** A cell arrived as its picture,
  its caption and one static text per badge, read in *layout* order — so
  "book.closed" and the read badge came before the title. It is one element now,
  and `BookCell.spokenLabel` puts the badges into the sentence: "Dune, Frank
  Herbert, Dune #1, EPUB · AZW3, 4 of 5, read, DRM, on the device".
- **The search field, the cover-size slider and three inspector fields had no
  name.** The slider announced "0.3043478260869565"; it says "160 points".
- **The three columns are named** — Library sidebar, Covers, Inspector — so a
  reader landing on one of three unnamed scroll areas knows which.
- **A file in the inspector's Formats block is one element**, not four texts
  each carrying the same help string and none of them saying which file the one
  before it belonged to.

### Fixed — two colours under WCAG AA, found by a script rather than by eye

`make contrast` (`Scripts/check-contrast.py`) checks the pairs **Shelf** decides
— the opacities it applies on top of SlateKit's palette, which SlateKit's own
check cannot see. It reads the palette out of the SlateKit checkout the app
actually builds against and looks for each expression in the file said to hold
it, so a colour changed in a view and not in the script fails the script rather
than going stale.

| pair | was | is | needs |
|---|---|---|---|
| the author's name under a missing cover | **3.09:1** | 6.36:1 | 4.5:1 |
| the DRM badge's word on its plate | **3.96:1** | 9.44:1 | 4.5:1 |

Both were secondary text dimmed a second time — `.opacity(0.6)` on a caption,
and secondary text on a 14 % plate. The whole table, as the script prints it
after the fix:

| pair | ratio | needs | |
|---|---|---|---|
| the author under a missing cover (grid placeholder caption) | 6.36:1 | 4.5:1 | PASS |
| the DRM badge's word on its plate, over a panel | 9.44:1 | 4.5:1 | PASS |
| a badge over the worst cover there is (white), on its 55 % black plate | 4.76:1 | 4.5:1 | PASS |
| a badge over the darkest cover there is (black), on its 55 % black plate | 21.00:1 | 4.5:1 | PASS |
| the table's stars when a book is rated | 11.61:1 | 4.5:1 | PASS |
| the table's secondary columns (tags, format, size, added) | 6.36:1 | 4.5:1 | PASS |
| the sidebar's footer and its empty-section notes | 4.96:1 | 4.5:1 | PASS |
| a network note in the sidebar's footer | 9.06:1 | 4.5:1 | PASS |
| · the book symbol behind a missing cover (decorative) | 1.85:1 | — | reported |
| · the symbol over "This library is empty." (decorative) | 2.52:1 | — | reported |

The last two are **reported and not gated**: WCAG 1.4.11 covers a graphic you
need in order to understand or operate something, and a book symbol behind a
caption that already says the title and the author is neither — it is hidden
from the accessibility tree for the same reason.

SlateKit's own palette has its own check (`make contrast` in that package,
33 pairs, all passing), and this one deliberately does not repeat it: it reads
the palette out of the checkout the app builds against, and covers only what
Shelf decides on top of it.

### Fixed — the arrow keys leave the menu bar, four sprints after the measurement said so

[ADR 0006](docs/adr/0006-editing-keys-are-not-menu-shortcuts.md) measured what a
held key costs **with the arrow key** — 83 % of ten seconds inside
`-[NSMenu performKeyEquivalent:]`, of which 31 % was `usleep` inside
`NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` — and then moved the
*editing* keys, leaving the arrows where they were.
[ADR 0017](docs/adr/0017-the-arrow-keys-leave-the-menu-bar.md) finishes it.
Measured again by `Scripts/arrow-key-proof.sh`, same ten seconds, same
generated repeat:

| where the main thread was | ADR 0006 | now |
|---|---|---|
| `-[NSMenu performKeyEquivalent:]` | 83 % | **0.0 %** |
| `NSMENU_IS_THROTTLING_…` → `usleep` | 31 % | **0.0 %** |
| `_NSHighlightMenu` → layout | 27 % | **0.0 %** |
| the monitor, and the move under it | 0.3 % | 0.7 % |

7 373 samples on the main thread; `NSApplicationMain` reads 7 359 of them, which
is the script's own proof that it can see a deep frame at all — the first
version anchored its number at the start of the line, where `sample` never puts
it, so every row read 0.0 % and the run looked like a triumph.

The six menu items stay, without key equivalents: a menu is a keyboard route of
its own, and an action that exists only as a bare key is an action nobody finds.

**A second hole closed with it, and the menu bar had had it too:** while a sheet
was open, 3 rated the book behind it and ↓ moved the selection underneath.
`EditingKeyMonitor` asks `NSApp.keyWindow?.isSheet` now.

### Fixed — one shortcut table, and the menu bar reads it

`ShortcutReference` fed the ⌘? sheet and the welcome line; the menu bar declared
its keys by hand. Both of the things that can go wrong had gone wrong:

- **⌘A and ⇧⌘W were in the menus and in no reference a user could read.**
  Select All Books and Close Library worked and were written down nowhere.
- **⌥⌘I was declared twice**, on `File ▸ Import from Calibre…` and on
  `View ▸ Inspector`. AppKit gives the first matching item the key, so the
  inspector's shortcut had never worked at all. CONCEPT §3.3 says ⌘I is the
  inspector and ⌥⌘I the Calibre import; the table now says that, and **Add
  Books, which had taken ⌘I, moves to ⇧⌘I.**

A menu item asks the table for both its words and its key (`View.shortcut(_:)`),
and a row with no `menuKey` is a key the window answers itself — so "this must
not be a menu shortcut" is data rather than somebody remembering. Six tests,
including one that reads `App/Shelf` and refuses any `.keyboardShortcut(`
written by hand outside the one bridge.

Two more the menu bar was drawing in English on a German Mac: `View ▸ Show As`
and `View ▸ Sort By` handed SwiftUI a `String` from the core, which it draws
verbatim. 613 core tests, up from 606.

### Fixed — declaring German made Shelf follow the Mac, which broke eleven scripts

Naming `de` in `CFBundleLocalizations` is what makes a German Mac give Shelf
German — the point of the whole change — and it means the menu bar reads
"Ablage" and "Bibliothek". Every script here that drives the window by clicking
`menu bar item "File"` then fails with a System Events error that blames System
Events:

```
"menu bar item \"Library\" of menu bar 1 … kann nicht gelesen werden. (-1728)"
```

Nothing is wrong with the app, and the same script still works on an English
Mac. It cost two runs of `Scripts/online-shot.sh` before the reason was found.

`Scripts/app-language.sh`: a script that drives menus says which language it is
written for, in Shelf's **own** defaults domain, and a trap puts it back — on a
failure and on a ⌃C as well as on a clean finish. Eleven scripts pin English;
`german-shots.sh` pins German.

### Measured — the comparison sheet, photographed with its sources

`docs/screenshots/sprint-7/online-comparison.jpg`: seven rows, each naming Open
Library, and an author list with no German word in it.

**The two-row case is still not in any picture.** Google Books answered HTTP 429
again — the same shared anonymous quota as in Sprint 6 — so no lookup in this
repository has ever had both services answering at once. The rule has five tests
against constructed candidates; the picture is owed.

### Added — `make release`: archive, sign, notarise, staple, assess

Seven steps, each of which says what it did, in `Scripts/release.sh`
([docs/RELEASE.md](docs/RELEASE.md)). **It never creates anything that costs
money and never touches a certificate**: it reads a `Developer ID Application`
identity out of the keychain, and a `notarytool` **keychain profile** for the
Apple ID — so no password is ever on a command line, in an environment variable
or in a file in this repository.

`make release-dry` signs **ad hoc**, skips the two steps that need Apple and
does everything else for real. Measured on 18 September 2026, version 0.1.0:

```
release: code directory flags: 0x10002(adhoc,runtime)
release: hardened runtime: on
release: Shelf-0.1.0.zip (5209 KB)
```

The entitlements read back **out of the signed build** rather than out of
`project.yml`: app-sandbox, bookmarks.app-scope, removable-volumes.read-write,
user-selected.read-write, network.client. Five, and no server entitlement —
Shelf listens for nothing (CONCEPT §12).

With no certificate in the keychain a real run stops at step 2 and says what to
make and where, which is also proved above.

**Nothing has ever been notarised.** Steps 6 and 7 have never run; there is no
Developer ID on this Mac, and that is Erik's to make.

### Added — German, and a test for each of the three ways of losing it

Every word Shelf draws is now in `App/Shelf/Resources/Localizable.xcstrings`:
**429 entries, English and German, eight of them with plural variations.** The
key is the English sentence itself, so the source still reads as what a person
sees ([ADR 0016](docs/adr/0016-the-core-answers-in-english-the-window-translates.md)).

**Everything drawn goes through `Loc`, including the plain literals.** Leaving
`Text("Add Books…")` to SwiftUI was the first plan and it does not survive two
things Shelf's own code does: `Text("one " + "two")` is a `String` rather than a
key and is drawn **verbatim and never translated** — a dozen help texts are
written across two lines with a `+` — and an interpolated key is built by the
compiler out of the interpolation's *types*, so no test can read it off the
source.

**ShelfCore did not gain a bundle.** It answers in English and the window looks
that English up. Where a core sentence has a value in it — "“2,5x” is not a
number" — the core now answers *which* refusal it is and the window says it in
words: `BookFieldRejection` and `ShelfEdit.Rejection` were already enumerations,
and `SeriesPosition` gained a `Place` beside its `text`.

**Numbers, dates and sizes come from `FormatStyle`.** "18.09.2026" and
"134,5 kB" on a German Mac. `ByteCount.format` keeps the C locale, because it
writes the reports and `Scripts/proof-run.sh` greps them — reports stay English
on purpose, and so do the readers' own warnings.

Five tests, because none of the three failures shows: a missing entry, a missing
German and a literal that never reached `Loc` all draw perfectly good English.
Four of them check the catalogue and what asks for it; the fifth is blunt and
says **no sentence anywhere in `App/Shelf` may be drawn without going through
`Loc`**. That one exists because the first German run came out with an **English
sidebar** — `SlateSidebarRow` takes its title as the first argument, which was
on no list of call shapes, so seven smart collections and six section headings
stayed English while every other word in the window turned over. It found six
more places at the same time. 606 core tests, up from 600.

`Scripts/german-shots.sh` starts Shelf in German **through its own defaults
domain, never the Mac's**, and removes the override however the run ends.
Pictures and what looking at them found — a label that wrapped in the ⌘? sheet,
"Book 9.5" that was still English — in
[`docs/screenshots/sprint-7/README.md`](docs/screenshots/sprint-7/README.md).

### Fixed — the welcome screen's Calibre button had said "Arrives in Sprint 3" for three sprints

The import has worked since Sprint 3; what it needs is a library to import
*into*, and there is none on that screen. The button stays disabled and its help
now says what to do instead, which is the one thing a disabled button owes the
person looking at it.

### Fixed — a German word in an English window, and a sheet that would not say who said what

Both came out of one look at `docs/screenshots/sprint-6/online-comparison.jpg`.

**"Unbekannt" in the author list was fixture data, not a fallback.**
`Scripts/online-library.sh` typed it as the author of its German test title, and
the sidebar's author list is simply the names the library holds — so a
placeholder typed into a fixture was drawn as an author. The fixture now gives
that book **no author at all**, which is the more interesting case anyway.

Every fallback in the code was read for the same fault; there was no other
German string in any window. What there *was* is the fallback itself:
`Book.authorLine` answered `"Unknown"` for a book with no author, so the grid
caption and the table column said a word the library did not contain. **A book
with no author now shows nothing.** Where a name is *required* — a folder on
disk, a file name on a device, a duplicate key — `Book.unknownAuthor` still
supplies "Unknown", because a path cannot be blank; it is Calibre's own word and
keeps a folder tree compatible in both directions.

**Every line of the comparison now names the service it came from**, and where
the two services disagree there are **two lines, one each, with a box each**
(`FieldProposal.sources`, `MetadataMerge.proposals(for:from:)` taking several
records). With two services, "what the service says" had stopped being a
sentence: a person was being asked to accept a publisher without being told
whose publisher it was.

Three rules came with it, all in the core and all tested:

- **A contested field arrives unticked**, even where both answers would fill a
  gap. Two catalogues disagreeing is the clearest possible sign that this one is
  a person's decision.
- **Rival lines are exclusive** (`MetadataMerge.ticking`): a field holds one
  value, so ticking Google Books' publisher unticks Open Library's. Applying
  both would have let whichever `apply` reached last win, quietly. **Tags are
  exempt** — they are added, so both catalogues' subjects can be taken.
- **Which two records may share one sheet is decided by ISBN and nothing else**
  (`EditionMatch`). Pairing the two services' best answers to a *title* search
  by how alike they look cannot be done safely: `MetadataScore` puts "Dune"
  against "Dune Messiah" at **87** and "Clean Code" against its own subtitled
  form at **83**, so the sequel scores *higher* than the subtitle and no
  threshold separates them. A title search therefore shows one service's
  answers, each named, and says so rather than guessing.

12 new core tests, **600 in total**, up from 588.

## Sprint 6 – online metadata · 18 September 2026

Measured on Erik's Mac (M-series, macOS 15.6) against
`~/Library/Caches/Shelf/measure-library-6/`.

### Added — Fetch Metadata (⌘E): Open Library and Google Books, field by field

Both services are asked about one book, without an API key, **by ISBN where the
book has a valid one and by title and author otherwise**. What comes back is a
candidate list with a match score out of 100; the chosen candidate is then set
against the book field by field, old above new, a box per field — and Apply goes
through the same undo-then-write path an inspector edit goes through, so a
fetched title is undone with ⌘Z like a typed one
([ADR 0015](docs/adr/0015-online-metadata-two-sources-field-by-field.md)).

**Nothing is ticked that would replace an answer the book already has.** Only
empty fields arrive ticked — and not even all of those; see the two findings
below. Tags are *added*, never replaced, and no tag is ever taken off a book
because a service has not heard of it.

The rules are in `ShelfCore` and the socket is in the app. `MetadataTransport`
is the seam: which URL, how often, what a 503 means, whether this was asked
before, what the two JSON shapes mean, which candidate is the book, and what a
candidate would do to it are all tested **without a network**, against answers
the services really gave. 57 new core tests, 588 in total, up from 531.

Manners, as a rule with a test (`NetworkPolicy`): a User-Agent naming the
project and nothing about the person; one request per second **per service**; a
retry only for a 5xx or for no answer at all, waiting 1 s, 2 s, 4 s; a 15-second
limit; and every answer kept for a month in `~/Library/Caches/Shelf/online/`, so
the same ISBN is never asked twice. `Shelf ▸ Clear Downloaded Metadata` names
its size. The only thing that leaves this Mac is the ISBN or the title.

### Measured — the real run against both services, ten ISBNs

`Scripts/online-proof.sh`, 18 September 2026, from this Mac. It is also what
writes the fixtures the tests read.

| | answered | of ten | total time |
|---|---|---|---|
| Open Library | HTTP 200 ten times | **9 books** | 69.7 s |
| Google Books | **HTTP 429 ten times** | 0 books | 5.0 s |

- **Google Books' shared anonymous quota was exhausted.** `Quota exceeded for
  quota metric 'Queries' … for consumer project_number:624717413613` — the same
  1 306-byte body ten times, and the same from `books.googleapis.com` and with
  `country=DE` and `country=US`. Not Shelf's quota: the one everybody's unkeyed
  requests share. A key would fix it and would be a secret in a shipped app.
- **Open Library knew nine of the ten**; the tenth (a German Heyne paperback)
  it answered `{"docs": []}` for, which is an answer.
- Its speed varies by an order of magnitude: 1.9 s for *The Fellowship of the
  Ring*, 24 s for *Nineteen Eighty-Four* (which needed the second attempt). The
  first version of the proof script had no retry and reported three of the ten
  as timeouts; all three answered in under three seconds when asked again, so
  the script now retries exactly as `NetworkPolicy` does. A measurement that
  does not behave like the app measures something the app does not do.
- What the two disagree about, where both answered: nothing, because one of them
  never did. That column of the proof run is empty and says so.

### Changed — Open Library is asked through `/search.json`, not `/api/books`

CONCEPT §9 names `/api/books?bibkeys=ISBN:…` for an ISBN lookup. It answered
**HTTP 404 with an empty body** to every ISBN tried — four of them, including
ISBNs whose books Open Library's own search finds, and with `jscmd=details` as
well as `jscmd=data`. `/search.json?q=isbn:…` answers the same book in the same
`docs` shape the title question gets, so Sprint 6 ships **one endpoint and one
reader** where two were planned. The concept is amended in ADR 0015 with the
measurement beside it.

### Found by looking at the screenshots — two defaults that were wrong

**Open Library answers a *work*, and hands out one of its editions' fields.**
The picture of *Fantastic Mr Fox* (`docs/screenshots/sprint-6/online-cover.jpg`)
showed, for a Puffin paperback: authors `Roald Dahl & Roal'd Dal'`, publisher
`Caedmon Audio Cassette`, language `ja`, published **1917**. Three of those were
`would replace` and so unticked. The year was `not set` — and arrived **ticked**,
because the rule was "tick what fills a gap". A record that describes a work now
never pre-ticks a publisher, a language or a date. The lines are still drawn:
what a service says is worth seeing even when it is wrong.

**"Tags — would replace" was written over a line that replaces nothing.** Tags
are merged, never overwritten. They now read `would add`, and they are not
ticked for anybody either: a catalogue's subjects are catalogue vocabulary and a
person's tags are their own.

### Fixed — the Linux build had been broken since Sprint 5, and nothing said so

`swift build` on Linux — which is the guard rail that keeps AppKit and friends
out of the core — has been failing since the device work: `Sources/shelf-tool`
gained an unconditional `import Darwin` for `statfs`, and `shelf-tool` is a
target of the same package, so a plain `swift build` builds it too. **`ShelfCore`
itself was and is fine**; what was broken was the build the CI job runs.

It was not noticed because **GitHub Actions has not started a job on this
repository since Sprint 4**: every run of the last twelve commits ends in 7
seconds with *"The job was not started because recent account payments have
failed or your spending limit needs to be increased."* That is an account
matter, not a code one, and it means the last four sprints have had no CI at
all. Erik has to look at the billing page; nothing in this repository can fix it.

Found instead by running the Linux job here, in a `swift:6.1` container. Both
the import and `fileSystemName(of:)` are now `#if canImport(Darwin)`, and on
Linux the file system reads as unknown — which every caller already handles, and
which is honest: a device proof run happens on the Mac the reader is plugged
into. A second implementation over `/proc/mounts` that nothing would exercise
would be code that is wrong and unnoticed.

**Measured on Linux** (`swift:6.1`, `libsqlite3-dev`, the committed tree):
`swift build` complete in 36.9 s, **588 tests passed in 3.7 s**. That includes
everything Sprint 6 added — the stored fixtures come out of `Bundle.module` on
Linux exactly as on macOS, and one Linux-only trap was removed on the way:
`URLError` lives in `FoundationNetworking` there, so the fake transport in the
tests throws a three-line error of its own instead.

### Fixed — a field taken over from the net could not be undone at all

`Scripts/online-apply-proof.sh` drives the real window against the live
services, ticks a box, presses Apply and then reads the files off the disk. It
found this, and nothing in the window said anything was wrong:

**A sheet has no undo manager.** `@Environment(\.undoManager)` inside a
`.sheet` is `nil` — a sheet is its own presentation and SwiftUI gives it none —
so Apply wrote `metadata.opf`, registered nothing, and ⌘Z did nothing. Silent
and complete. The window's manager is now handed into the sheet by
`ContentView`, and the proof run reads the date out of the OPF after Apply and
reads it gone again after ⌘Z.

Measured, end to end at the window: the EPUB's SHA-256 **unchanged**
(`83ab7b05…` before and after), `metadata.opf` gained
`<dc:date>2008-01-01T00:00:00+00:00</dc:date>`, and ⌘Z removed it again.

One thing about it is unexplained and cosmetic: the Edit menu reads a bare
**"Undo"** rather than "Undo Published", although `setActionName` is called on
the same manager `registerUndo` was called on and the undo itself works. It is
in `docs/BACKLOG.md`.

### Added — a cover from the net, when the file has none

Only on the explicit **Use This Cover**, only when the book's folder has no
cover file, and the bytes' magic number is checked before anything is written —
a service that answers an error page with a 200 would otherwise leave a
`cover.jpg` holding the words "Not Found". It is written through a `.part` and a
rename, beside the book. **The book file is not opened at all** (CONCEPT §4).
The cached thumbnail for that one book is thrown away, so the grid draws the new
cover rather than the placeholder it was holding.

### Added — network failures are quiet, and that is photographed

`Scripts/online-shot.sh` takes the last two pictures with
`SHELF_ONLINE_HOST=metadata.invalid` — the name RFC 2606 reserves as
never-resolvable — so both services really fail. Nothing on the Mac is switched
off for it. There is no dialogue and no spinner left behind: the sheet says
"Nothing came back. The book keeps everything it has." and the sidebar's footer
carries one line.

That line is short because the first one was not: both services' own sentences
came to 130 characters and the footer showed "…hostname could not be foun…".
One failure is now said in full, two are named — "Open Library and Google Books
did not answer." — and the whole text stays in the sheet and in the tooltip.

### Fixed — "Duplicates" said 396 of 413 books, and meant nothing by it

The Sprint 5 screenshot showed a sidebar claiming **396 duplicates in a library
of 413 books**. The collection asked all three of the importer's rules and put
every answer in one heap, so the one rule that fires constantly — same title and
same first author — drowned the two that state a fact.

The rules are now told apart by what they *claim*, which is a property of the
rule and lives on it (`DuplicateReason.isCertain`):

| Rule | Claim | Collection |
|---|---|---|
| Same file, byte for byte | a fact | **Duplicates** |
| Same ISBN | a fact | **Duplicates** |
| Same title and first author | a suspicion | **Possible Duplicates** |

`DuplicateGroups` sorts the books into the two, and the two sets are
**disjoint — certainty wins**: a book matched by its bytes *and* by its title is
counted once, under the better reason. The two numbers therefore add up to the
number of books any rule flagged, and neither collection is a subset of the
other. The sidebar has a second row; the inspector's heading reads `Duplicate`
or `Possible Duplicate` and now lists *every* rule that matched rather than only
the strongest; `shelf-tool duplicates` prints the two groups apart.

**Measured on `measure-library-6/library`**, the same generator and the same
count as the library in the Sprint 5 screenshot:

| | books | Duplicates | Possible Duplicates |
|---|---|---|---|
| before, as shipped in Sprint 5 | 413 | 396 (one heap) | — |
| after | 413 | **0** | **396** |
| after, with two book folders copied in the Finder and the index rebuilt | 415 | **4** | **394** |

The first row of the "after" is the finding, and it is worse than a bad number:
in a library of 413 books there was **not one actual duplicate**, and the
sidebar said 396. The third row is the check that the strong rules still fire —
two book folders duplicated the way a person duplicates them, each given a fresh
UUID, and all four books (the two copies and the two originals) land under
`Duplicates` and *not* also under `Possible Duplicates`, although their titles
match as well.

A book with several formats is not a duplicate of itself under any of the three
rules — an EPUB and an AZW3 of one book share a `book_id`, and the SQL counts
distinct books. There is now a test that says so in as many words, because it is
the commonest shape in any library and the one a rewrite would break silently.

### Fixed — three bare "Mixed" where the title, the author and the series stand

With several books selected, the inspector drew its title block as usual: three
values in three type sizes, one under the other. For one book the type size *is*
the label — headline is the title, callout the author, caption the series. For
twelve books all three read `Mixed`, in three sizes, with nothing at all to say
which was which. The accessibility tree named them; the window did not
(`docs/BACKLOG.md`, carried since Sprint 3).

The title block is now drawn **only for one book**. A selection of several gets
the count line it already had — "413 books selected" — and Title, Authors and
Series move down into *Details*, where every row has its name beside it and
`Mixed` is unambiguous. Nothing is lost and nothing became editable: the three
are read-only across a selection for the same reason as before.

Two neighbours in that block were wrong in a quieter way and are fixed with it:

- **Added** showed the anchor book's date, which is a fact about one book
  dressed up as a fact about all of them. It now reads `Mixed` unless every
  selected book was added on the same day.
- **Size** showed the anchor book's bytes. It is now the sum over the selection,
  which is the question a selection is actually holding — how much this is going
  to cost on a card.

## Sprint 5 – devices · 18 September 2026

Measured on Erik's Mac (M-series, macOS 15.6) against
`~/Library/Caches/Shelf/measure-library-5/` and **four e-readers made out of
`hdiutil` disk images** — no real device was plugged in, and what that leaves
unproven is listed in `docs/BACKLOG.md` under "To check on real hardware". 531
core tests, up from 478.

### Added — recognising a reader

A volume is a device when **all** of a profile's markers are there, or when its
name is one the profile claims. The profiles are **data, not code**: four JSON
files in `ShelfCore/Devices/Profiles/`, read at runtime, so a new model is a
file rather than a release
([ADR 0013](docs/adr/0013-device-profiles-are-data-not-code.md)). A profile that
will not decode is left out and named; it costs its own device and nothing else.

Two things about markers were found by running the thing rather than by
thinking about it, and both would have shipped.

**The boot disk was a PocketBook.** APFS is case-insensitive, so `/System` and
`/Applications` answer a profile asking for `system` and `applications`, and the
first run of `shelf-tool devices` printed `Macintosh HD → PocketBook (pocketbook)`.
A marker is a *name*; a file system that answers to the wrong case is not
evidence that the name is there. Markers are now checked against the directory's
own listing, and a volume that cannot be unplugged is never a device.

**And that fix broke every Kindle.** The two forms of `contentsOfDirectory`
disagree on FAT — which is what every reader that takes a USB cable is formatted
with. On a FAT32 card holding a folder called `system`:

| API | answer |
|---|---|
| `contentsOfDirectory(atPath:)` | `System` |
| `contentsOfDirectory(at:)` | `system` |
| `readdir(3)`, `ls`, `find` | `system` |

The path form is the odd one out. Built on it, the case-exact check made every
Kindle and every PocketBook stop being recognised the moment the proof run put
them on a real FAT32 volume — and the unit test did not catch it, because a
temporary folder is on APFS. `Scripts/proof-run.sh` section 11 is what catches
it, and `DeviceTests` now says so where somebody tidying the function will read
it.

### Added — sending books

`TransferPlanner` chooses the format by the **device's** preference order, not
Shelf's: a Kindle gets AZW3 before MOBI before PDF and never an EPUB, where
Shelf's own ranking puts EPUB first because everything reads it. A book the
device can open none of is `cannot be sent: no compatible format` — an answer,
not a step towards one, because Shelf converts nothing in v1.0.

`TransferRunner` is `ImportRunner`'s pattern on a card
([ADR 0002](docs/adr/0002-copy-verify-then-trust.md)): write to a `.part`, hash
the source while reading it, **read the file back off the device** and hash
that, and only then rename it into place and write the manifest. A file already
on the card under that name is never overwritten — it is something Shelf did not
put there. A cancelled run takes away its own leftovers and nothing else.

The manifest on the card (`<volume>/.shelf/device-manifest.json`) is what makes
a second run a resume rather than a repeat, and its digests are the ones read
back *off the device*, so it is a statement about the card and not about the
library.

**Names on a device** are `{author} - {title}.{ext}` — the other way round from
the library's own, because a reader sorts its file list by name. Cleaned for
FAT: forbidden characters, no trailing dot or space, Windows's reserved names,
and **both** length budgets, because FAT counts UTF-16 code units and APFS counts
bytes and neither can be derived from the other. A file of 4 GiB or more is
refused on FAT32 before the copy starts.

### Added — what is on the device, and a Kobo's own state

The files on a card are matched to the library's books by the manifest first and
by name second, and the row says which — "sent by Shelf" and "matched by name"
are different claims. **No hashing**: hashing a 32 GB card to draw a badge would
make plugging a reader in a two-minute operation.

A Kobo also says how far its owner has read, what its shelves are called and
what is on them. It is read **through a copy with its WAL**, exactly as Calibre's
database is ([ADR 0009](docs/adr/0009-calibre-is-read-through-a-copy-of-metadata-db.md)),
and **never written back**. A test hashes the device's database before and after
to say so, and so does the proof run.

### Added — deleting, behind a list of names

Deleting on a device is the one destructive thing Shelf does, and it has its own
ADR ([0014](docs/adr/0014-deleting-on-a-device-needs-a-named-confirmation.md)).
It is reachable from one place only — the sheet where the files are chosen — and
then only through a confirmation that names **every** file, not a count and not
the first ten. The second line says what will *not* happen, because the fear
this dialog answers is "does this take them out of my library too". Never as a
side effect of a sync; there is no sync.

### Measured

Release build, against disk images on an internal SSD — so the *times* are
faster than a real USB card would be and the *counts* are not.

| | |
|---|---|
| Four layouts recognised, boot disk not | ✓ |
| 250 books to a Kobo | 25.9 MB, **2 s**, every file read back and hashed |
| A second run over the same selection | nothing sent — the manifest is the resume |
| 250 books to a Kindle | 212 sent (AZW3 206, MOBI 3, PDF 3), **38 named as "cannot be sent"**, no EPUB written |
| Longest name written to FAT32 | 255 bytes and 255 UTF-16 units, no forbidden character |
| Transfer killed at 40 of 120 | resumed by copying the missing 80; a planted half-written file swept up; 0 left behind |
| A card with 4.4 MB free, 26.7 MB plan | refused before the first byte, 0 files written |
| A Kobo read back | 250 reading positions, shelves and read status; database digest **identical** before and after |
| Files on the card matched to books | 212 of 212 |
| Deleting 3 of 20 named files | 17 left; nothing without the confirmation |
| The library afterwards | 1841 files before and after; **0 books or OPFs modified**; 5 sample digests unchanged |

### Two things that are not about devices, found on the way

**Accents survive FAT32 and change shape.** macOS writes `Lefèvre` to a card
**decomposed** and the library's OPF holds it composed. Matching survives that
because Swift compares Strings by canonical equivalence — but nothing said so,
and anyone swapping it for a UTF-8 byte comparison would lose the badge on every
book with an accent in its author's name and see nothing fail. There is a test
now.

**`screencapture -l <window id>` photographs a stale window.** For a SwiftUI
`ScrollView` the backing store is not redrawn when the view scrolls, so the
sidebar screenshot showed the top of the list three runs in a row while the
screen showed the bottom. `Scripts/device-shot.sh` captures the window's
rectangle instead. The accessibility API is no help either: it clamps the frame
of a row scrolled out of view to the scroll area's own, so a check built on a
row's position passes while the picture shows something else.

### The sandbox, and what it costs

`com.apple.security.files.removable-volumes.read-write` is in the entitlements,
and it does **not** cover a mounted disk image: with it in place the app could
read an image's name and free space and could not list its directory, so a card
with five books on it showed "0 books". So `Device ▸ Treat Volume as Device ▸
Kindle…` now opens a panel — choosing the volume there is what the sandbox takes
as permission. It was already the way in for a reader Shelf does not recognise;
it is now also the way in when the sandbox will not let Shelf look.

**This means every screenshot in `docs/screenshots/sprint-5/` shows a device
chosen by hand, and none shows one found by its marker alone.** Whether
auto-detection works against real removable media is the first line of the
hardware list, and it is not a formality: if it does not, auto-detection is
decorative.

## Sprint 4a – three things the screenshot showed · 18 September 2026

Found by looking at `docs/screenshots/sprint-4/formats-inspector-many.jpg`
rather than at a test: the grid held two books where one belonged, the
*Duplicates* collection said 0 over them, a publisher stood in the author list,
and the inspector read "Book 3 of 1". 478 core tests, up from 457.

### Fixed — one book arriving as two

**A comic's title carried its issue number twice.** The file was
`A Desolation #164 164 (2024).cbz`: a name whose own title already ends with the
issue and whose scanner appended it again. `ComicFileName` parsed it correctly —
series "A Desolation #164", issue 164 — and then composed the title by writing
the number after the series, which put it in twice.
`ComicFileName.title(series:number:)` is now one rule used by both routes into a
comic (the file name and `ComicInfo.xml`), and it adds the number only when the
series does not already end with it. `Battle 2000 15` keeps both of its numbers,
because 2000 and 15 are two numbers.

**Files lying side by side are one book.** `ImportPlanner` could join two files
only through a UUID, an ISBN or a matching title and author — so a folder
holding `Emma - Jane Austen.epub` and `Emma - Jane Austen.pdf` became two books
whenever the PDF carried no metadata, which is the ordinary case. The planner
now reads the neighbourhood first: **files sharing a stem in one source folder
are one book**, and UUID, ISBN and title+author decide the rest as before. The
folder is part of the key, so two downloads of one title kept in two places are
still two candidates for the three duplicate rules. It sits after the UUID
(an identity outranks a file name) and before the ISBN (two files somebody put
side by side under one name are a statement; a matching title is a guess).

Measured on the Sprint 4 fixture, regenerated with the sibling files sharing a
stem the way a real download folder does: the EPUB, AZW3, MOBI and PDF of one
book arrive as **one book with four formats**, and a broken pair
(`… wrong bytes.cbz` / `… wrong bytes.mobi`) arrives as one book as well.

### Fixed — Duplicates said 0 with the pairs on screen

Two things kept the pairs apart, and both were in the third rule. The title
`A Desolation #164 164` folds to "a desolation 164 164", which no comparison
can join to "a desolation 164"; and the comic twin has **no author**, where the
key spelt the absence as "Unknown" and compared it like a name.

`DuplicateKey.foldedTitle` now collapses a trailing number the name carries
twice, and `LibraryIndex.suspectsByTitleAndAuthor()` treats a missing author as
matching any author — absence of evidence, not evidence of a different person.
Two *named* authors under one title are still two books, because Ulysses by
Joyce and Ulysses by Tennyson are two books.

**The importer's key is deliberately not widened.** `allTitleKeys()` decides
whether to write a file into somebody else's folder, and a wrong answer there
costs data; this collection only ever raises a suspicion, and the inspector
says which rule found it.

Measured against the very library in the screenshot, copied and otherwise
untouched: **16 duplicates where the sidebar said 0** — all eight pairs,
including the five the doubled number had hidden.

### Fixed — a publisher in the author list, and "Book 3 of 1"

**The publisher.** The three books under "A Publisher" in the screenshot were
the *fixture's* doing: `synthesise-mixed` gave its DRM books the author
"A Publisher". They are now written the way a book is written — author
"Ada Mercer", publisher "Head of Zeus" — so the picture shows the app rather
than the generator.

The question the screenshot raised was still worth answering, and one of the
four reader paths did have the defect. EPUB 2 puts a creator's role in an
attribute (`opf:role="pbl"`), which `OPFDocument` already honoured; **EPUB 3
puts it in a `<meta refines="#id" property="role">` beside the element**, which
it did not read — so a `<dc:creator>` naming the publisher went straight onto
the spine. That spelling is what every EPUB 3 built since 2011 uses. MOBI
(EXTH 101), PDF and `ComicInfo.xml` were already right, and
`PublisherIsNotAnAuthorTests` now says so for all four: **a missing author stays
missing.** An empty author field files a book under "Unknown", which a person
can see and fix; a publisher in that field files a thousand books under Penguin,
which looks like metadata and is not.

**"Book 3 of 1".** The count was right — the library really did hold one book of
"Wayfarers" — and the sentence was not: "of 1" reads as a claim about the series
that its own neighbour contradicts. The wording is now `SeriesPosition` in the
core, where it is tested: a library holding fewer books of the series than the
index claims says **"Book 3"** and leaves the total out. A half-collected series
is the ordinary case, not an error.

### Added

`shelf-tool duplicates <library>` prints what the *Duplicates* collection holds
and which of the three rules found each book. Reads only. It is how the number
above was measured, and the screenshot had no way of showing it.

## Sprint 4 – the other formats · 18 September 2026

Measured on Erik's Mac (M-series, macOS 15.6) against
`~/Library/Caches/Shelf/measure-library-4/`. 456 core tests, up from 376 at the
end of Sprint 3.

### Added — MOBI, AZW3, PDF, CBZ and CBR

`BookFileFormat.hasReadableMetadata` is true for everything but KFX now. That
was always the one line Sprint 4 would change; behind it are four readers and a
table saying which half of the program runs each one.

**MOBI and AZW3** get their own parser in `ShelfCore/Formats/Mobi`, written from
the public format descriptions
([ADR 0011](docs/adr/0011-mobi-with-an-own-parser-kfx-as-a-file-only.md)):
PalmDB container → record 0 → PalmDOC and MOBI headers → EXTH. Read: 100 author,
101 publisher, 103 description, 104 ISBN, 105 subject, 106 date, 113 ASIN,
201 cover, 503 title, 524 language. Three things in it are worth knowing. The
container is **big-endian** where the ZIP reader in the next folder is
little-endian. A **comma is not an author separator** — these files write
"Le Guin, Ursula K." and splitting on commas makes two half-people — so
`AuthorField` splits on `&` and `;` only and is shared with the PDF and comic
readers. And **Windows-1252 is a table in the code**, because
`String.Encoding` has no single-byte code pages in swift-corelibs-foundation and
the core builds on Linux.

**KFX is carried and never opened.** Its container is undocumented, so a parser
written against guesses would give plausible wrong answers that nobody could
see. Name, size, digest, and a sentence in the inspector saying so.

**Comics**: `ComicInfo.xml` first, then the file name. `Serie 012 (2019)` →
series, issue, year. Two of its rules were found by tests rather than by
thinking:

* Bracketed groups come off the end **one at a time**, so
  `Saga 012 (2019) (Digital)` keeps its year. Taking the year first and the
  noise second lost it.
* A dot becomes a space **only when the name has no spaces of its own**. Scene
  releases write `The.Sandman.v01`; `Monstress 12.5` means twelve and a half,
  and came out as issue 12 of a series called "Monstress 12" when dots were
  replaced unconditionally.

Pages sort in natural order, so page 2 comes before page 10 and the cover is not
page ten.

**PDF and CBR live in the app layer**, because PDFKit and libarchive's RAR
reader are Apple's and the core has to build on Linux — their *rules* stay in
the core. The PDF reader ignores an Author field holding "Microsoft Word" and a
Title that is only the file name again, both of which look like metadata and are
not. libarchive is reached through `dlopen` rather than a link: macOS ships the
dylib and **no header for it**, and loading by name can fail in a way the
program can explain, which is what CONCEPT §13 asks for. Measured here:
libarchive 3.7.4, both the `rar` and `rar5` readers present. The inspector says
so on every CBR row.

### Added — several files on one book, Quick Look, and the badges

The inspector's **Formats** section now has a row per *file*: its size, its name,
a DRM badge when it has one, and Show in Finder / Open on the right-click. Per
file because a book can be an EPUB with Adobe's protection and an AZW3 with
Amazon's, and one badge on the book said nothing about which. **`Add Format…`**
goes through the same `ImportPlanner` a dragged file does, so the two cannot
disagree about what happens.

**Quick Look on the space bar.** A PDF is handed to the system as it is;
everything else shows the cover already extracted next to the book. CBZ was on
the first version of that list, on the theory that macOS would show it as an
archive — the screenshot run caught it drawing a brown book icon and the file
size, which is exactly the outcome the rule exists to avoid. The list is
`[.pdf]`.

### Fixed — three defects the proof run found, none of which failed a test

**The app died on the first CBR it was ever shown.** SIGSEGV in
`rar5_cleanup`: `LibArchive` registered the RAR5 reader twice, once through
`archive_read_support_format_all` and once by name "in case `all` leaves it
out". It does not, and libarchive's error path for a second registration of an
already-registered format dereferences a null context. Reproduced in isolation
both ways before and after the fix.

**A rebuild lost every DRM badge.** The importer detected protection and stored
it — nine files in the measuring library — and `Rebuild Index from Folders` set
them all back to nothing, with nothing failing and nothing logged. The index is
a cache (ADR 0001), so everything in it has to be re-derivable from the folder,
and this was not. `DRMProbe` now asks the file on every rebuild, narrowly: an
EPUB for one entry in its central directory, a MOBI for record 0, a PDF for the
tail where its trailer is. The badge is therefore a fact about the bytes, and a
file whose protection is gone stops being badged — both directions tested.

**A book with four files on disk showed three.** Adding a format to a book the
library *already* had gave the runner nothing to add to, so it built a fresh
entry holding only the new file, and the index took that as the whole book. The
folder number went the same way, reset to 0. Nothing was ever lost on disk and a
rebuild put it right, which is why it went unseen — the same shape as the
orphaned folders below, and found the same way, by looking at what a real run
produced. `ImportRunner.run` now takes an `existingEntry` lookup.

### The proof run — every format in one library

`shelf-tool synthesise-mixed` writes 500 each of EPUB, MOBI, AZW3, PDF and CBZ,
plus three DRM-announcing files per format that can carry the announcement,
fifteen deliberately broken ones and three KFX. **2 527 files, 192.4 MB.**
Section 10 of `Scripts/proof-run.sh`.

| | |
|---|---|
| import, copied and verified | **2 527 files in 9.0 s**, 250 MB peak |
| became | **1 015 books · 1 512 formats added to existing books** |
| books holding more than one file | **514** |
| files carrying DRM | **9** (3 Adobe, 6 Kindle) |
| skipped, failed | **0, 0** |
| library on disk | 274 MB (192.4 MB of books, the rest covers) |
| source modified during the run | **0 files** (`find -newer`) |
| digests vs `/usr/bin/shasum` | one per format, all five agree, all five in the index |
| index erased and rebuilt | **2.7 s** → 1 015 books, 2 527 files, **9 badges** |

The fifteen damaged files — truncated EPUBs, the right name over the wrong
bytes, a nearly empty PDF — all import as books named after their files, each
with a line in the report. Not one stopped the run, which is what CONCEPT §13
asks for.

**Three flaws in the fixture, each found by a number that looked wrong.** They
are worth listing because a fixture that collides with itself measures the
duplicate check instead of the thing under test: comic issue numbers were
`index % 300`, so 308 comics were duplicates of each other; the three "wrong
bytes" files per format were byte-identical, so two of every three were skipped;
and comic *contents* were seeded on `index % 200`, so 300 of 500 CBZ were the
same file. All three now carry their index in their bytes.

### Not measured, and named

* **No genuine CBR.** A RAR is a proprietary compressed format and this Mac has
  no tool that can write one. The route in is proven — libarchive opens the
  archive, the pages sort, the cover comes out — against a ZIP under a `.cbr`
  name. A real RAR5 comic has not been read.
* **No genuinely protected file.** The fixtures announce protection without
  being encrypted, which is what Shelf's claim actually needs
  ([ADR 0012](docs/adr/0012-drm-is-recognised-and-nothing-else.md)). Whether a
  real ADEPT EPUB or a Kindle purchase is detected is unmeasured.
* **No MOBI or AZW3 that anybody bought.** The fixtures are written from the
  same description the parser was written from. The byte offsets in the fixture
  are spelled out longhand rather than borrowed from the parser's constants, and
  several tests assert against hand-written bytes, but that is mitigation and
  not proof.
* **The app layer has no unit tests.** `PDFFileReader`, `LibArchive` and
  `QuickLookPreview` are covered by the proof run and the screenshots only —
  the test target is `ShelfCore` alone.

Pictures and what each is evidence of: `docs/screenshots/sprint-4/README.md`.

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
