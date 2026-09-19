# Sprint 8 screenshots, in German

The same five sheets as the folder above, taken by the same script with
`SHELF_SHOT_LANGUAGE=de`, on 19 September 2026. Every menu name the script
types is in one table in `Scripts/organize-shot.sh`, so the run says which
language it is written for — the lesson from Sprint 7, where a script asking
for `menu bar item "File"` on a German Mac failed with a message that blamed
System Events.

**What a German run can show that a test cannot** is whether the layout
survives longer words. It does, everywhere, and nothing here is truncated or
clipped: German runs two or three lines where English runs one or two, and each
sheet simply grows. **But looking at these found two defects, both fixed.**

---

## `merge-dialog.jpg` — Autor umbenennen

> **Found here, and fixed — twice over, because this project had already
> learned it once.** The search field read **"Diese autoren durchsuchen"** and
> the explanation **"die derselbe autor ist"**. Both came from
> `.lowercased()` on a label, which is right in English ("Search these
> authors") and is a *spelling mistake* in German, where nouns are capitalised.
> `SidebarView` carries the same lesson in a comment from Sprint 7, where
> "Alle Bücher" had come out as "alle bücher zeigen".
>
> The placeholder is capitalised now ("Diese Autoren durchsuchen"). The
> explanation does not name the kind at all any more — "die dasselbe meint" —
> because the sheet's own title one line above already says "Autor
> umbenennen", so interpolating it bought nothing and cost a bug.

Otherwise it reads as it should: the three Fitzek spellings with "3 Bücher"
each, "Alle werden zu", and the line that told two nothings apart in English
telling them apart in German too — **"3 Bücher lesen sich schon so – nichts zu
ändern"**. The plural comes from the catalogue, so "1 Buch" and "3 Bücher" are
both right without a `== 1` anywhere in the code.

## `organize-preview.jpg` — Bibliothek aufräumen…

> **Found here, and fixed.** The count line was **English**: "8 to move · 7
> already right · 1 cannot be", above a sheet whose every other word was
> German. So were the report headline, the export summary and — loudest of all
> — the import's "FAILED: 3 files not verified". Eight lines in five sheets,
> every one of them the most-read line of its sheet.
>
> They came out of the core's own `summary()` and `headline`, which the window
> was drawing straight. Those stay exactly as they are: they are written into
> the plain-text reports, and a report has to be readable in ten years by
> whoever opens it. `App/Shelf/Views/Summaries.swift` builds the *window's*
> line from translated pieces instead — ADR 0016's rule, which is that the core
> answers in English and the window translates.

It now reads "8 zu bewegen · 7 schon richtig · 1 geht nicht", and the obstacle
still leads the list in the accent colour: "dort liegt schon etwas, und es ist
nicht leer". The explanation wraps to two lines where English wraps to two;
nothing is cut.

## `organize-report.jpg` — the report

"Bewegt · 8 Ordner · Schon richtig: 7 · Nicht möglich: 1 · Fehlgeschlagen: 0"
fits on one line at 620 points, which is the longest of these lines and the one
most at risk. Below it, the sentence that was worth changing this sprint: **"8
Autorenordner blieben durch die Züge leer und wanderten in den Papierkorb"** —
the Trash, named, so the picture says what the code now does.

"Aufräumen widerrufen" and "Fertig" both fit their buttons.

## `export-archive.jpg`, `export-books-only.jpg`, `export-for-calibre.jpg`

The three presets. "Archiv · Nur die Bücher · Für Calibre" fit across the sheet
with room to spare, and the lit one is the accent colour in both languages.

The explanations are where German is longest — "Für Calibre" runs to three
lines against English's two — and the sheet grows rather than clipping. The
token help under the name pattern wraps to two lines in both.

`export-books-only.jpg` is the one worth having: the honest sentence, in the
accent colour, in German. **"Nur die Buchdateien. Bewertung, Gelesen-Status,
Tags und Regale gehen nicht mit – sie stehen in der metadata.opf, und die wird
nicht geschrieben."** Underneath it, `cover.jpg` and `metadata.opf` have
unticked themselves, so the words and the switches agree.

---

## What is not here

The export *running*, and its report — it would mean writing a second copy of a
library to photograph a progress bar. Its numbers are in `CHANGELOG.md` from
`make proof` section 12.
