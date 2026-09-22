# The ⌘Z menu title — remeasured, not rebuilt · 22 September 2026

`docs/BACKLOG.md`'s Sprint 6/7/12 entry said SwiftUI's own Edit ▸ Undo item
never carries the action's name. Sprint 12, Teil B's own attempt to fix it
with `CommandGroup(replacing: .undoRedo)` was built, measured and reverted
the same day (`CHANGELOG.md`, "⌘Z naming itself, attempted and abandoned").

This is a second look, done exactly as instructed — measure step (a) again,
before changing anything. It found that step (a) itself no longer (or
never actually did) reproduce the bug the entry describes, **once the menu
is opened with a real click**. Every measurement below used a genuine
`CGEvent` mouse click on the actual "Edit" menu bar item (`Scripts/click-at.swift`
at a position read from the accessibility tree), the same way
`Scripts/keyboard-proof.sh` and every other script in this project drives
the window — never System Events' own `click menu bar item …` verb, which
turned out to open the menu through a different path that does not run
AppKit's live validation cycle. Reading menu item names *that* way, or via
`get name of menu items of menu 1 of …` without a real click first, reads
whatever title AppKit last computed — which, for an item nobody has looked
at since launch, is the unnamed default. That is almost certainly the
measurement artefact behind every "bare Undo" finding since Sprint 6.

No source file changed. `App/Shelf/ShelfApp.swift` is exactly what it was
after Sprint 12, Teil B's revert (`git checkout -- ` to `fa8e7e2`). The
default, unreplaced `CommandGroup(.undoRedo)` SwiftUI ships automatically
is AppKit's own standard Edit ▸ Undo/Redo pair — action `undo:`/`redo:`,
target `nil` — and AppKit has always updated *that specific* item's title
and enabled state on its own, from whichever `UndoManager` answers the
responder chain, needing no application code at all. Replacing the group
(as Sprint 12, Teil B tried) throws this away, which is why that attempt's
title never moved.

- **`1-undo-typing.jpg`** — three letters typed into the inspector's title
  field, uncommitted, Edit menu opened with a real click: **"Undo Typing"**,
  exactly Sprint 12, Teil B's own step (a) baseline. Verdict: correct,
  unchanged.
- **`2-undo-publisher.jpg`** — a committed Publisher edit (⏎), Edit menu
  opened with a real click: **"Undo Publisher"** — the case every prior
  session read as bare "Undo". Verdict: correct. This is the finding that
  overturns the backlog entry.
- **`de/2-verlag-widerrufen.jpg`** — the same Publisher edit, German:
  **"Verlag widerrufen"**, grammatically correct (object before verb, the
  normal German order) — not the broken "Widerrufen Title" phrasing a
  German window showed once before, during the Sprint 12, Teil B
  `CommandGroup(replacing:)` experiment. This title is AppKit's own
  German localisation of the standard Undo item, not anything this
  project's own catalogue supplies — nothing was added to
  `Localizable.xcstrings` for this.
- **`de/3-verlag-wiederholen.jpg`** — after ⌘Z: **"Widerrufen"** bare and
  disabled (nothing left to undo) and **"Verlag wiederholen"** enabled —
  the redo side named correctly too. The Publisher field's own displayed
  text in this shot is not trustworthy as a revert check: this library had
  already been edited by two earlier, unrelated test runs, so its content
  reads `TestverlagTestverlagGollancz` rather than one clean value. The
  *menu* naming is what this round of testing is about, and it is legible.

**Not independently measured this round, and not claimed as measured:** a
cover change (`Set Cover…` / `Remove Cover`). `LibraryModel.applyCover`
calls `undoManager?.setActionName(Loc.core(MetadataChange.Field.cover.label))`
on the same window `UndoManager` every other field above already went
through (`App/Shelf/Services/LibraryModel.swift`, `registerCoverUndo`) —
the same mechanism, not a different one — so there is no code reason it
would behave differently. Asserting it from the source rather than a
fourth screenshot, and saying so rather than skipping the question.

**Conclusion:** `docs/BACKLOG.md`'s Sprint 6 entry is closed, not fixed —
there was nothing in the shipped app to fix. It is marked accordingly, with
this finding, rather than left open for a third attempt.
