# Sprint 2c – what the window showed

Taken against `~/Library/Caches/Shelf/measure-library-3-shots`, a synthetic
library of **120 books** arranged by `Scripts/shots-2c.sh`, at 1440 × 877.
All four are from one run, with the screen awake.

## `shelves.jpg` – the sidebar

Four shelves, two of them inside others, each with its own count, and the
inspector for one book.

* **Nested shelves with live counts.** `Fiction 23` is not a stored number: it
  is `Science Fiction 14` plus `Crime 9`, counted over the books in memory, so a
  shelf counts what is inside it as well as what is on it. `Non-Fiction 7` holds
  only `History 7`.
* **`Not on any Shelf 79`** against `All Books 120` – 41 books are shelved,
  which is 14 + 9 + 7 + 11 with no double counting.
* **`Duplicates 0`**: the synthetic library has no two books with the same
  bytes, ISBN or title-and-author.
* **The placeholders in a label's colour**, not a value's: `Add series…`,
  `Add date…`, `Add ISBN…` are visibly dimmer than `Orbit`, `en` and
  `Ancillary #41`, which are values.
* **`Unrated` beside five empty stars, and no `0/5`.** Shelf asks SlateKit 0.3.1
  for `label: .unratedOnly`; the package's own default writes the number, which
  is what Selector still gets.

## `table.jpg` – the table, sorted by a column

⌘2, with the *Author* header clicked once. The arrow sits on `Author`, and the
sort control above the grid reads `Author ↑`: the header and the menu are the
same `BookOrder` and cannot disagree. Nine columns; `Title` truncates with an
ellipsis rather than wrapping; `Unknown` in the author column is the every
hundredth synthetic book, which deliberately has none.

`ax-table.txt` is the same thing as the accessibility tree has it, including
the nine `AXSortButton`s.

## `selection.jpg` – several books, and `Mixed`

Eight books selected with ⇧-click. **Eight borders**, which is the point: this
shot is the retaken one. The first version of it showed one, because the cell
asked for the *anchor* rather than the selection — the feature worked and the
picture of it did not, and no test could have seen that.

The inspector heads with `8 books selected` and the line that says what a change
will do: *"Rating, read status, tags and shelves apply to all of them."* Title,
series and description read `Mixed`; `Publisher` and `Language` read `Mixed` on
the right, where a shared value would be.

`ax-selection.txt` is the inspector as VoiceOver walks it.

### Two things worth fixing, seen in this shot and written down rather than fixed

* The three `Mixed` values at the top carry no visible label. On a single book
  those positions are the title, the series and the description and are obvious;
  three bare `Mixed` in three sizes is not. The accessibility tree *does* name
  them (`desc="Description"`), so this is a visual gap, not an accessibility one.
* `Published` shows nothing at all where the others say `Mixed`. Blank says
  neither "they differ" nor "none of them has one".

Both are in `docs/BACKLOG.md`.

## `menu.jpg` – the context menu

*Add to Shelf ▸*, *Remove from Shelf ▸*, *Mark 8 Read*, *Show in Finder*. The
count is in the item, so the menu says what it will do to how many. The whole
screen is photographed rather than the window, because a menu is its own window
and is drawn outside the app's.

## `table-scroll-sample.txt` – the table at 4 996 rows

What Sprint 2c owed and could not take. `Scripts/table-scroll.sh` opens
`measure-library-3` (4 996 books), switches to the table and scrolls it for
twelve seconds while `/usr/bin/sample` reads the process.

    peak memory while scrolling:                  282 MB
    main-thread frames mentioning a cover decode:   0
    main-thread frames mentioning file I/O:         0
    main-thread frames mentioning SQLite:           0

The main thread spent those twelve seconds in SwiftUI and AppKit: 3 610 frames
there, 13 in `mach_msg`. That last pair of numbers is the reason the run is
worth anything — the *first* version of this script reported the same three
noughts with the main thread 8 213 samples out of 8 440 asleep in `mach_msg`,
because nothing had scrolled. The script now photographs the window before and
after and refuses to report a measurement of an idle app.

**Driven by Page Down.** `Scripts/scroll-at.swift` posts scroll-wheel events and
reports success, and the SwiftUI `Table` does not move for them — measured: byte
for byte identical after twenty clicks inside the window, changed at once by one
Page Down. So this is keyboard-driven scrolling. It exercises the same row
recycling; it is not an answer to "is trackpad scrolling smooth", which stays
open in the backlog and needs a person's hand.

The 282 MB replaces Sprint 2c's 295 MB, which was read while the screen was
locked and a window that is not being composited may do less work than one that
is.
