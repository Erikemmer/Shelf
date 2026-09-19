# What the accessibility tree says

One file per view, written by `make accessibility`
(`Scripts/ax-proof.sh`): the tree VoiceOver walks, dumped out of a **running**
window by `Scripts/ax-dump.swift` and then judged by `Scripts/ax-judge.py`.

They are committed because a claim about accessibility that nobody can check is
not a claim. A diff against these files is what shows that a change to a view
took a name away.

## What the judge fails on

1. **A control with no name** — a button, checkbox, text field, slider or menu
   button with no title, description or value. VoiceOver announces such a
   control as nothing at all.
2. **A name that is an SF Symbol's identifier** — `book.closed`,
   `arrow.down.doc`, `questionmark.folder`. SwiftUI falls back to the symbol's
   name when an `Image` is neither hidden nor labelled, so the window reads out
   a line of code.
3. **A view that does not hold what it was told to hold** — each view names the
   buttons and labels it must contain, so a row that quietly stops being a
   button fails rather than going unnoticed.

## What was in these files before Sprint 7

The same run against the build at `b7d1296` had **21 findings** in the library
window alone: every cover placeholder announced "book.closed", the search field
and three inspector fields had no name, and **every row of the sidebar was two
pieces of static text with no role and no action** — a sidebar a keyboard could
not use at all. That last one was in `docs/BACKLOG.md` for two sprints.

## What these files cannot answer

Three things, and they need a person:

- **whether the order things are read in makes sense.** The tree says what
  order they are in; whether that order is the useful one is a judgement.
- **whether a label says the useful thing** rather than merely a thing. "Show
  only Ada Mercer" passes every check here and would pass them if it said
  "Button".
- **whether the focus ring is where the keyboard actually is.** The pictures in
  `docs/screenshots/sprint-7/focus-ring-*.jpg` are what there is to look at.

## The one view that is not here

`sheet-delete-from-device`. The confirmation that names every file
([ADR 0014](../adr/0014-deleting-on-a-device-needs-a-named-confirmation.md))
exists only when there is something on the card to delete, and this run sends
nothing to the card it mounts. It is photographed in
`docs/screenshots/sprint-5/` against a card with books on it.
