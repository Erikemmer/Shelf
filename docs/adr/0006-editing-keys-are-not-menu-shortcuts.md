# ADR 0006 – The editing keys are handled in the grid, not by the menu bar

Date: 2026-09-17 · Status: accepted

## Context

Sprint 1 gave the grid its keyboard navigation the obvious SwiftUI way: a menu
item per action with a `keyboardShortcut`, so `Library ▸ Next Book` carries →
and the menu doubles as the documentation. Sprint 2a had to add six more keys —
1, 2, 3, 4, 5 for the rating, 0 to clear it, R for read — and the question was
whether to keep going the same way.

Two measurements decided it.

**The first is what a held key costs.** `sample` was run for ten seconds while
the right arrow was pressed 626 times (macOS's own `key down` produces no
auto-repeat, so the repeat had to be generated). The main thread was busy for
89 % of the run, and almost none of it was Shelf's:

| where the main thread was | share of the run |
|---|---|
| `-[NSMenu performKeyEquivalent:]`, all of it | 83 % |
| of which `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` → `usleep` | **31 %** |
| of which `_NSHighlightMenu` → unhighlight → CA commit → full window layout | **27 %** |
| `LibraryModel.move(by:)`, the actual work | 0.3 % |

AppKit throttles repeated menu-item invocations by *sleeping on the main
thread*, and it flashes the menu title in the menu bar on every one, which drags
a whole SwiftUI layout pass behind it. Neither has anything to do with what the
key is supposed to do. (There was no image decoding and no file I/O on the main
thread, which is what the sample was taken to check.)

**The second is what a digit key equivalent would break.** A menu key equivalent
is offered the event before the responder chain, so a plain `1` never reaches a
focused text field. "1984" could not be typed into the search box.

## Decision

Keys that edit — 1–5, 0 and R — are handled by `.onKeyPress` on the cover grid,
which is focusable and takes focus when it appears and whenever a cell is
clicked. They are listed in `ShortcutReference` and so appear in the ⌘?
sheet and on the welcome screen, which is where the documentation lives anyway.

The arrow keys stay menu items for now. Moving them is a separate change with
its own risk to keyboard navigation, and it is in `docs/BACKLOG.md`.

Checked afterwards, in the running app: "1984" types into the search field, and
1–5, 0 and R reach the selected book.

## Consequences

- Editing keys cost nothing but the edit. The write itself is 5–8 ms from key
  press to written `metadata.opf`.
- The keys only work while the grid has focus. That is why `BookCell` hands
  focus back on a click: without it, clicking a book after typing in the search
  field would leave the keys going nowhere.
- Two mechanisms now answer keys — the menu for navigation, `onKeyPress` for
  editing. That is the cost of not doing the arrow-key move in this sprint, and
  it is written down rather than left to be discovered.
- `onKeyPress` needs macOS 14, which is the deployment target, so nothing had to
  move for it.
