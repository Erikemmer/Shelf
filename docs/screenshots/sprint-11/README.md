# Sprint 11, Schritt 3 screenshots — the cover joins "Write into the Book File"

Taken by `Scripts/write-into-book-cover-shot.sh` against the three-book
library `shelf-tool epub-cover-write-fixture` builds. 22 September 2026,
window at 1440 × 877. **English here and German in `de/`** — the same
script run twice, with `SHELF_SHOT_LANGUAGE=de`, the way Sprint 9's and
Sprint 10's own screenshots do.

**The three cover images are real, decodable JPEGs**, not synthetic
byte-strings the way `EPUBCoverPatchTests`' fixtures are — made from
Shelf's own app icon (`App/Shelf/Resources/Assets.xcassets/AppIcon
.appiconset`) at three different sizes with `sips`, never a borrowed image
(CLAUDE.md). That matters here specifically: the sheet's cover row
describes a picture in words (`CoverImage.describe`, reading the file's own
pixel size with `CGImageSource`), and a description worth checking has to
come from bytes that actually decode to something, not a magic number
followed by padding.

**Every claim under a picture was checked against the disk, not against
the picture** — the same rule Sprint 10's own README states. `4-after.jpg`
is checked by extracting the book's own `.jpg` entry from the rewritten
EPUB with `unzip` and comparing it byte for byte (`cmp`) against
`new.jpg`, not merely by grepping for a size in the sheet.

**What the fixture is**: `shelf-tool epub-cover-write-fixture` (`Sources/
shelf-tool/main.swift`) builds three ordinary synthetic EPUBs — "The Glass
Almanac" with a cover, "Cinders and Salt" with none at all, "The Quiet
Harbour" with a cover — imports them, then edits Shelf's own copy of each
book's cover file (`cover.<ext>`, `CoverFile`) to set up the three states
the sheet has to describe: a cover that has since changed (Almanac's is
swapped for a different image, exactly what `Replace Cover…` from ADR 0020
would leave behind — never written into the book itself until this sheet
runs), a cover Shelf can offer where the book has none (Cinders and Salt),
and a cover left exactly as import extracted it, so it is already the same
(The Quiet Harbour). Synthetic library, real cover bytes, built fresh on
every run.

**Found taking these, not before:**

- **A stale build can silently outrank a fresh one.** The "find the newest
  built `Shelf.app`" snippet these screenshot scripts share compares the
  app *bundle directory's* own modification time — but an incremental
  Xcode build that only rewrites files nested inside an existing bundle
  (a recompiled string catalog, a relinked binary) does not necessarily
  bump that directory's own mtime on APFS. A `Shelf.app` built five days
  earlier was picked over one built a minute ago, and the symptom looked
  exactly like a localisation bug: the surrounding German sentence
  translated correctly, but one value inside it — "No cover in the
  book" — stayed English, because the catalogue entry for exactly that
  key had been added *after* the stale build's own string catalog was
  compiled. `SHOT_APP=<path>` (already a supported override) sidesteps it
  by naming the binary directly; the discovery snippet itself is
  unchanged here, since it is shared with `write-into-book-shot.sh` and
  fixing it is not this sprint's to do quietly — noted in
  `docs/BACKLOG.md` instead.
- **The sheet's own "planning" state can outlast a fixed sleep.** With a
  real cover's tens of KB to read, hash-compare and re-archive off the
  main actor, `EPUBWrite.plan` sometimes takes longer than the 1.5 s the
  Sprint 10 script waits after a sheet first appears. `open_write_sheet`
  here waits for the planning caption itself to be gone rather than
  guessing a duration.

---

## `1-cover-changed.jpg` — a cover Shelf would replace, beside a field that also changes

"The Glass Almanac": a publisher edit (`Not set → Erik & Erik Press`) and a
cover row in the very same list — `Cover  JPG, 300 × 450 → JPG, 400 × 600`
— one sheet, one confirmation, exactly as `docs/adr/0021-…` asks for. No
second command, no second sheet: the cover is one more row, in the same
"label, then old → new" shape every text field already has, described in
words because the core never decodes a pixel and this sheet does not
either.

*Judgement:* right. The row sits last, after every text field — the order
`bookSection` already lists fields in, with the cover appended once.

## `2-no-cover-in-book.jpg` — no cover in the book at all, Shelf has one to offer

"Cinders and Salt": every text field already matches ("schon gleich" /
"already the same" down the list), and the cover row reads `Cover  No
cover in the book → JPG, 350 × 525`. Nothing else about this book would
change — the cover alone is why "1 book will have its EPUB file replaced"
is offered at all, and the checkbox and write button are enabled on that
one row's own account.

*Judgement:* right. "No cover in the book" only ever appears on the left
side of the arrow — a book Shelf itself has no cover to offer for gets no
row at all (`EPUBWrite.CoverPlan.afterBytes == nil`), so the sentence
never has to say "no cover" on both sides at once.

## `3-cover-already-same.jpg` — a cover that is already the same

"The Quiet Harbour": untouched since import, so its `cover.jpg` is exactly
what import extracted from its own file. **Nothing to write** / *"This
EPUB file would not change."*, the button disabled — and the cover row
still shows, single-valued (`JPG, 300 × 450`), tagged **"already the
same"** off to the side, the identical treatment a text field gets in this
state (Sprint 10, Schritt E2). The row does not disappear just because
nothing would change; it says so, the same lesson that sprint already
learned for text fields.

*Judgement:* right. This is also the real-world proof of
`EPUBCoverPatch.Result.changed` (Sprint 11, Schritt 2) reaching all the way
into the window: the core's own bit-for-bit equality check is what decides
this row never reaches `run` at all.

## `4-after.jpg` — after: the book's own file now carries the new cover

**Measured:** the rewritten `The Glass Almanac - Rosa Feldmann.epub`'s own
`.jpg` entry, extracted with `unzip` and compared with `cmp`, is `new.jpg`'s
exact bytes — not "some image close enough to look right," the literal
file the fixture wrote to disk before the sheet ever opened. The sheet's
own report: *"1 book was written into. No ⌘Z for this. Each original is in
the Trash and can be dragged back from there."* The inspector's own size
figure (25.9 KB, up from 18.6 KB) agrees with a real cover having actually
landed in the file, not the 530-byte synthetic one Sprint 11, Schritt 1's
own numbers were measured against.

*Judgement:* right.

---

## What these pictures do **not** show

- **No case b (adding a cover where none exists) landing in a real,
  illustrated Gutenberg book.** That is `Scripts/real-epub-proof.sh`
  section 10's own proof, against six real, cover-stripped books — a
  script's report, not a screenshot; a picture of a sheet cannot show a
  manifest's own new `<item>` element.
- **No cover size or format conversion.** The bytes Shelf offers are
  `cover.<ext>` exactly as it sits on disk — this sheet, like the core
  underneath it, never decodes, scales or re-encodes a pixel. The three
  different sizes photographed here come from three different source
  files, not from Shelf resizing anything.
- **No multiple-book selection with a cover row in it.** Sprint 10's own
  `4-drm-refused.jpg` and `6-several-unchanged.jpg` already prove a mixed
  selection's shape; adding a cover state to either would be testing the
  selection logic a second time rather than the cover row itself.
