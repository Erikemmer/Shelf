# Sprint 2c – what the window showed

## `shelves.jpg`

The grid with four shelves in the sidebar, two of them inside others, each with
its own count — and the inspector for one book.

What it is evidence of:

* **Nested shelves with live counts.** `Fiction 23` is not a stored number: it
  is `Science Fiction 14` plus `Crime 9`, counted over the books in memory, so a
  shelf counts what is inside it as well as what is on it. `Non-Fiction 7` holds
  only `History 7`. The disclosure triangles are open; clicking one folds the
  children away.
* **`Not on any Shelf 79`** against `All Books 120` — 41 books are shelved,
  which is 14 + 9 + 7 + 11 with no double counting. The collection is no longer
  greyed out.
* **`Duplicates 0`**, likewise no longer greyed: the synthetic library has no
  two books with the same bytes, ISBN or title-and-author.
* **The placeholders in a label's colour**, not a value's: `Add series…`,
  `Add date…`, `Add ISBN…` are visibly dimmer than `Orbit`, `en` and
  `Ancillary #41`, which are values. Sprint 2b drew all six in the same ink.
* **`Unrated` beside five empty stars, and no `0/5`.** With a rating the word
  disappears and the stars are the statement.

## What is missing, and why

Three more shots were meant to be here — the table with a sort arrow, the
inspector with several books selected showing `Mixed`, and the context menu's
*Add to Shelf ▸*. They are not, because **the Mac's screen locked in the middle
of the run** (`CGSSessionScreenIsLocked = Yes`, at 14:36:08, confirmed through
`ioreg`).

A locked screen breaks a window-driven script without failing it:

* `screencapture -l <window id>` keeps working and returns the window's *last
  drawn frame*, so several shots come out byte-identical — which is what
  happened, three times, before the script was taught to refuse a picture it had
  already taken.
* System Events reports no windows, and the accessibility tree degenerates to an
  application element containing only itself, so every lookup answers "nothing"
  rather than failing.

`Scripts/shots-2c.sh` now refuses to start on a locked screen and re-runs itself
under `caffeinate -di`, so it cannot happen again in the middle of a run. The
three remaining shots need one run with the screen awake.

The claims they were to illustrate are not unevidenced in the meantime:

* the table, its columns and its header sorting — measured through the
  accessibility tree (`Title ↑` → click *Author* → `Author ↑` → click again →
  `Author ↓`, with the sort menu above the grid in step throughout);
* the shelves, the drag, the counts and the confirmation — `Scripts/shelf-proof.sh`,
  seven steps, all passing;
* editing across a selection — `shelf-tool bulk-tag-undo`, 50 books tagged and
  undone with every `metadata.opf` byte for byte as before.
