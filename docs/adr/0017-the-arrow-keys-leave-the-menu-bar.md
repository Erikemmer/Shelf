# ADR 0017 – The arrow keys leave the menu bar too

Date: 2026-09-19 · Status: accepted · Extends [ADR 0006](0006-editing-keys-are-not-menu-shortcuts.md)

## Context

[ADR 0006](0006-editing-keys-are-not-menu-shortcuts.md) measured what a menu key
equivalent costs when the key is *held*, and moved the editing keys off the menu
bar because of it. It left the arrows where they were, in one sentence:

> The arrow keys stay menu items for now. Moving them is a separate change with
> its own risk to keyboard navigation, and it is in `docs/BACKLOG.md`.

The measurement it was based on was taken **with the arrow key**. Ten seconds,
→ pressed 626 times, `sample` running:

| where the main thread was | share of the run |
|---|---|
| `-[NSMenu performKeyEquivalent:]`, all of it | 83 % |
| of which `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` → `usleep` | **31 %** |
| of which `_NSHighlightMenu` → unhighlight → CA commit → full window layout | **27 %** |
| `LibraryModel.move(by:)`, the actual work | 0.3 % |

So the one key the finding was *about* was the one key that kept the behaviour.
Four sprints went by. This is the sprint that owns accessibility, and holding an
arrow key to walk a library is not a nicety in that context — it is how somebody
who cannot use a pointer moves through 5 000 books.

## Decision

←, →, ↑, ↓, Home and End are answered by `EditingKeyMonitor`, the same local
`NSEvent` monitor that has answered 1–5, 0, R, T and the space bar since
Sprint 2a. `WindowKey` names them, matched against AppKit's own function-key
constants rather than against key codes, because a key code is a position on a
keyboard and these are the same key wherever they sit.

**The six menu items stay**, without key equivalents. Three reasons:

1. A menu is itself a keyboard route (⌃F2), so the actions stay reachable
   without a pointer — which is the whole point of this sprint.
2. An action that exists only as a bare key is an action nobody finds.
3. The keys are in `ShortcutReference`, which is what the ⌘? sheet and the
   welcome line read, so they are still written down where a person looks.

That a menu item must **not** carry a key equivalent is now data rather than a
habit: its row in `ShortcutReference` has no `menuKey`, and `View.shortcut(_:)`
hands `.keyboardShortcut` an optional. A test refuses any `.keyboardShortcut(`
written by hand anywhere in `App/Shelf` except the one bridge that reads the
table (`ShortcutTests.theWindowDeclaresNoKeysOfItsOwn`).

Two guards came with the move, and the second was a defect the menu bar had too:

- **Text being typed into is left alone** — the window's first responder being a
  field editor, as before. Arrows have to move the caret.
- **A sheet in front takes its own keys.** `NSApp.keyWindow?.isSheet`. While the
  Calibre protocol was up, 3 rated the book behind it and ↓ moved the selection
  underneath; a menu item is enabled whenever a library is open and a sheet does
  not change that, so the menu bar behaved the same way. Nobody had noticed
  because nobody had pressed 3 in a sheet.

## Consequences

- Holding an arrow key costs the move and nothing else. Measured again after the
  change: see `CHANGELOG.md`, Sprint 7.
- Two mechanisms no longer answer keys. Everything without ⌘ goes through the
  monitor; everything with ⌘ goes through the menu bar; the table says which is
  which and a test enforces it. ADR 0006's "that is the cost of not doing the
  arrow-key move in this sprint" is paid off.
- The menu bar no longer shows ← beside `Previous Book`. That is a real loss of
  discoverability at the menu, and the ⌘? sheet is where it is made up for.
- A key with no ⌘ can never again be declared as a menu shortcut by accident,
  because there is nowhere to write one.
