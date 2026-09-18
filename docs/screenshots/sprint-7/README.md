# Sprint 7 screenshots — Shelf in German

Taken by `Scripts/german-shots.sh` on 18 September 2026 against
`~/Library/Caches/Shelf/measure-library-7/online-library` (twelve generated
EPUBs carrying twelve real books' titles, authors and ISBNs — the files are
synthetic throughout).

**The Mac's language was not changed.** The script writes `AppleLanguages` in
**Shelf's own defaults domain**, which macOS reads for that one app, and removes
it again however the run ends — including when the run fails. A global
`defaults write -g` would have changed the language for every application and
for the login session.

Every picture below was looked at. What looking found is at the bottom.

| File | What it shows |
|---|---|
| `welcome-de.jpg` | The welcome screen: the three ways in, the drop zone, the shortcut line and the recent libraries |
| `grid-de.jpg` | The library: sidebar, cover grid, inspector |
| `inspector-de.jpg` | The same window with the first book clicked — it was already selected, so this is the grid shot again, kept because the inspector is what it is evidence for |
| `table-de.jpg` | The table (⌘2) with its column headings |
| `shortcuts-de.jpg` | The ⌘? sheet, built from the same `ShortcutReference` table the menu bar reads |
| `sidebar-de.jpg` | The window after the sheet closed, for the sidebar and the status line |

## What is in German

Everything the window draws. Named, because "it looks German" is not a claim:

- **Sidebar:** BIBLIOTHEK, Alle Bücher, Ungelesen, Zuletzt hinzugefügt, In
  keinem Regal, Ohne Cover, Duplikate, Mögliche Duplikate, REGALE,
  SCHLAGWÖRTER, AUTOREN, SERIEN, "Noch keine Regale — mit + eines anlegen".
- **Toolbar and bar:** Bücher hinzufügen, Informationen, Titel ↑, Alle Bücher,
  Suchen.
- **Inspector:** BEWERTUNG, Ohne Bewertung, Gelesen, DETAILS, Verlag, Erschienen,
  "Datum eintragen…", Sprache, Hinzugefügt, Größe, KENNUNGEN, "ISBN eintragen…",
  and "Band 9.5" where the English says "Book 9.5".
- **Table:** Titel, Autor, Serie, Bewertung, Schlagwörter, Format.
- **Status line:** "12 Bücher · 9 Autoren · 3 Serien".
- **⌘? sheet:** Tastaturkurzbefehle, and the five groups BIBLIOTHEK, BEWEGEN,
  BEARBEITEN, ANSICHT, GERÄTE with every action in German.
- **Welcome:** the subtitle, all three buttons, the drop zone, the shortcut line
  and "Zuletzt benutzte Bibliotheken".

**Numbers and dates are the reader's, not the program's.** "18.09.2026" rather
than "18 Sep 2026", and the plurals are real ones: "12 Bücher" against "1 Buch"
in the recent list, which is a catalogue plural variation rather than a trailing
"s".

## What is deliberately not German

- **The library's own words.** The tags read "award winner", "book club",
  "science fiction"; the authors and titles are as the books are called. Shelf
  translates its own vocabulary and never the library's
  ([ADR 0016](../../adr/0016-the-core-answers-in-english-the-window-translates.md)).
- **Format names.** EPUB is EPUB.
- **`Import-Report.txt` and the other reports.** They are evidence that scripts
  read; ADR 0016 §4.

## What looking at the pictures found

1. **The first German run had an English sidebar.** Every smart collection and
   four of the six section headings were still English, because
   `SlateSidebarRow` takes its title as the first argument and no list of call
   shapes had it. The fix was the blunt test in `LocalisationTests` — no
   sentence anywhere in `App/Shelf` may be drawn without going through `Loc` —
   which found six more places at the same time.
2. **The ⌘? sheet wrapped.** "Informationen ein-/ausblenden" took two lines in
   a column sized for one. Shortened to "Informationen umschalten", which says
   the same thing and fits.
3. **"Band 9.5" was "Book 9.5".** A sentence built in `ShelfCore` with a value
   in it, which no catalogue can hold a key for. `SeriesPosition` now answers
   *which* of the two sentences is true and the window says it.
4. **The first shortcut-sheet shot was of the grid.** The sheet is declared as
   ⌘/ and drawn as ⌘?, and a posted "?" with command held does not match it.
   The script uses the Help menu item now. The guard that should have caught it
   looked for "Bewegen" and the tree says "BEWEGEN" — it looks for the sheet's
   own title instead.

## What has not been photographed in German

The sheets that need a device, an import or a network answer: Send to Device,
Delete from Device, the Calibre import protocol, Fetch Metadata, and the
orphaned-folders sheet. Their strings are in the catalogue and covered by the
tests; **no picture has been taken of them in German**, so nothing here claims
their layout holds. `Scripts/online-shot.sh` and `Scripts/device-shot.sh` would
take them with the same defaults-domain trick.
