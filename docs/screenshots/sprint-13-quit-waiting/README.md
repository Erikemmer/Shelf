# The quit-waiting sheet, both languages · 23 September 2026

`en.png` and `de.png` are `ImportSheet`'s new state (Sprint 13, Teil E):
shown while `AppDelegate.performTermination()` is waiting for a cancelled
import's short last batch to flush, in place of the ordinary running
progress.

**Method, per `docs/RUNBOOK.md`'s own rule that a claim about what a
window shows is measured the way a person would see it:** a real,
synthetic hardware-level ⌘Q — `CGEventCreateKeyboardEvent` for the Q key
with `.maskCommand`, keydown then keyup, posted via `.cghidEventTap` —
sent to the real, running, `-c release` `Shelf.app` while it was mid-copy
of the 8 000-book synthetic source from Sprint 13, Teil C
(`~/Library/Caches/Shelf/interrupted-import-2026-09-22/gui-source`), not a
menu command driven through System Events. `Shelf` was brought frontmost
first with `osascript -e 'tell application "Shelf" to activate'` — that
line only raises the window, it sends no command of its own; the keystroke
that actually asks Shelf to quit is the one posted afterwards. The
screenshot itself is `screencapture -l <window id>`, the window id read
from `Scripts/window-id.swift`, the same technique every other window
screenshot in this project uses.

Language was pinned on the command line, the documented way
(`Scripts/app-language.sh`): `open … --args -AppleLanguages (en)` /
`(de)`, not a preference written and restored.

**Both captures needed several attempts.** The wait this Teil made fast
(Sprint 13, Teil E — the `removePartials` fix cut real time out of it) is
now often faster than a screenshot script can reliably catch: in most
tries the sheet had already moved on to its finished state, or the
process had already quit, by the time `screencapture` ran. The two
pictures kept here are the tries that actually landed on the waiting
state — not the first attempt, and not staged by slowing the app down for
the camera.

**The German wording in `de.png` reflects a real correction.** A first
draft's German sentence embedded "Verwaiste Ordner suchen…" (localised
"Find Orphaned Folders…") as the verb of a relative clause — grammatically
a noun phrase standing where German wants a verb, confusing to read. Both
languages now give the command its own sentence, matching the pattern the
finished-import view already used elsewhere in this sheet
("Nothing was removed. Library ▸ Find Orphaned Folders… shows them.").
`CHANGELOG.md`, Sprint 13, Teil E, has the before-and-after wording.

**What these pictures do not show, and could not:** the escape hatch,
"Quit Now Anyway", clicked. Every real quit this session tried resolved
the wait before a click (or a script) could have reached the button —
which is the point of the fix, not a gap in it, but it means that one
button is proven by reading the code, not by a screenshot of it being
pressed.
