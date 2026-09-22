# Sprint 12, Teil A screenshots — "Remove Cover"

Taken by `Scripts/remove-cover-shot.sh` against the library
`Scripts/cover-library.sh` builds — the same fixture `cover-shot.sh` uses.
22 September 2026, window at 1440 × 877. **English here and German in
`de/`** — the same script run twice, with `SHELF_SHOT_LANGUAGE=de`, the way
every screenshot script since Sprint 7 does.

Every claim under a picture was checked against the disk (`cover.*` beside
the book) and against the sidebar's own "Missing Cover" count, not against
the picture.

- **`1-menu.jpg`** — the inspector's own Cover menu, open on "The Ministry
  Called Peace #1", which has a cover. "Remove Cover" sits at the bottom,
  enabled, below "Download Cover…". Verdict: correct.
- **`2-after.jpg`** — the same book after "Remove Cover" was clicked: the
  cell and the inspector both draw the placeholder, and the sidebar reads
  "Missing Cover, 3" where it read "Missing Cover, 2" beforehand. Checked
  against the folder too: no `cover.*` remains. Verdict: correct — this is
  the hole Sprint 9 left open (`docs/BACKLOG.md`, "`Remove Cover` as a menu
  item"), now closed.
- **`3-disabled-no-cover.jpg`** — the inspector's Cover menu on "The Long
  Way Gods #1", which the fixture starts with no cover. "Remove Cover" is
  visibly dimmed against the three enabled items above it. Clicking it
  anyway (not photographed) changed nothing on disk. Verdict: correct.
- **`4-grid-context-menu.jpg`** — the grid's own context menu on "The
  Handmaid's of Darkness #2", right-clicked while it alone is selected.
  "Remove Cover" sits at the bottom, enabled, below "Write into the Book
  File…". Clicking it removed the cover and moved the sidebar from
  "Missing Cover, 3" to "Missing Cover, 4" — checked against the folder,
  not only the sidebar. Verdict: correct.
- **`5-disabled-multiple-selection.jpg`** — "Use of Season #3" and "The
  Ministry Justice #5" ⌘-selected together (the inspector's own header
  reads "2 books selected"), context menu open on the second. "Remove
  Cover" is dimmed here too, for the same reason the inspector's own text
  fields lock across a selection (`lockedBlock`): a cover typed once onto
  twelve books is a mistake with twelve copies, not an edit
  (`docs/BACKLOG.md`, "A cover for a multiple selection"). Clicking it
  anyway left both books' covers untouched. Verdict: correct.

**What this does not cover:** undo. `applyCover(nil, …)` is the same
function, the same `registerCoverUndo`/`performCoverUndo` pair and the
same `CoverReplacement.commit` every other cover action already goes
through — Sprint 9's own `cover-shot.sh` (`9-first-cover`, `13-edit-menu`)
already photographs ⌘Z and ⇧⌘Z working correctly down that exact path, and
`CoverChangeCommitTests.removingThroughCommit` (added this sprint) proves
`commit(nil, …)` bumps and reverts the generation the same way a
replacement does. Re-photographing undo for this one caller would not be
new evidence.

**Found taking these, not before:**

- **A disabled menu item does not dismiss its `NSMenu` the way an enabled
  one does.** Clicking "Remove Cover" while it was disabled (Stage 2, on
  "The Long Way Gods #1") left the Cover pull-down menu open on screen;
  the next stage's clicks then landed on the menu instead of the grid
  underneath it, and every lookup after it failed with "no cell for …" —
  looking exactly like a missing accessibility label rather than a menu
  still sitting open. Fixed in the script with an explicit Escape after
  the disabled-item click, not in the app: a disabled item doing nothing
  when clicked is correct AppKit behaviour, and the window itself was
  never asked to do anything else.
- **`grep`-ing an OPF for a title with an apostrophe needs the same
  escaping the OPF was written with.** `folder_of()`'s first version
  searched for `<dc:title>The Handmaid's of Darkness #2<` against a file
  that holds `&apos;s` (`OPFDocument.escaped`), found nothing, and
  `dirname` of an empty match is `.` — so the check that was supposed to
  confirm "this book has a cover to begin with" silently asked the
  script's own working directory instead of the book's folder, and read
  back "no cover" for a folder it never actually looked at. Fixed with a
  small `xml_escaped_title()` used everywhere `folder_of` is, and
  `folder_of` itself now returns nothing (failing the check loudly) rather
  than `.` (passing it by accident) when nothing matches.
