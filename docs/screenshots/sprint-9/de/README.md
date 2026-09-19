# Sprint 9 in German

The same twelve pictures as one level up, same script, same libraries, same
day, `SHELF_SHOT_LANGUAGE=de`. Read the English `README.md` for what each one
shows and what was measured; this file is only about the **language**.

**This run found a defect, and it is exactly the kind only a German run can
find.** It is fixed in `c4fd660` and these pictures are from after the fix.
`13-after-redo.jpg` and `13-edit-menu.jpg` were added later, once ⇧⌘Z itself
was fixed, and are from a second run at the head of this branch.

---

## What was wrong: every field name in the Fetch Metadata sheet

`10-replace-cover.jpg` in the first German run read **Title, Authors,
Publisher, Published, Language, ISBN, Tags** straight down the sheet, in a
window where everything around them was German.

`Text(proposal.label)` drew one of the core's own English words verbatim. The
accessibility label three lines above it in the same file put the same string
through `Loc.core` — so VoiceOver said "Autoren" while the window said
"Authors". Since Sprint 6, and completely invisible in English, which is why
`make german-shots` exists and why this sheet had not been through it.

It is right in these pictures: **Titel, Autoren, Verlag, Erschienen, Sprache,
ISBN, Schlagwörter**.

## What is right

- **The cover menu** (`1-cover-before.jpg`): *Cover festlegen…*, *Cover aus der
  Buchdatei holen*, *Cover herunterladen…*. Nouns capitalised, which is the
  mistake `SidebarView` carries a comment about from Sprint 7 and which Sprint
  8's German run made twice.
- **The button on the menu itself** stays **Cover** — the same word in both
  languages, so nothing to translate.
- **The refusal** (`7-not-an-image.jpg`): *„Das ist kein Bild, das Shelf
  erkennt – es wurde nichts geschrieben."* An en dash, not a hyphen.
- **The download button** (`10-replace-cover.jpg`): **Cover ersetzen**, against
  *Replace Cover*. The warning survives the translation, which was the thing
  worth checking: a button that said *Cover verwenden* over an existing cover
  would be the silent overwrite this sprint is built to avoid.
- **The sidebar count** (`9-first-cover.jpg`): *Ohne Cover* goes 2 → 1 and back
  to 2 on ⌘Z. The count line is German, which it was not before Sprint 8's
  closing run.
- **The Edit menu after ⇧⌘Z** (`13-edit-menu.jpg`): *Cover widerrufen*
  (enabled), *Wiederholen* (disabled) — "Cover" is not repeated in the German
  word for Redo, because German capitalises the *label* for Undo
  (`MetadataChange.Field.cover.label`, "Cover") but "Wiederholen" alone is the
  system's own word for the disabled Redo item and carries no field name at
  all. That is macOS's own menu text, not Shelf's, and it is the same in
  English: a disabled "Redo" names nothing either.

## What is still English, and is not this sprint's

- **"Google Books answered 429."**, in the sheet and in the status bar. The
  core builds that sentence with a number in it, so it is not a catalogue key
  the way the other core sentences are. Sprint 6's, still open, now written
  down.
- **"Open Library"** and **"Google Books"** are names of services and stay as
  they are.
- Nothing, in `4-file-panel.jpg`. That is macOS's own open panel and it is
  German throughout — *Heute*, *Größe*, *Art*, *Hinzugefügt am*, *Neuer
  Ordner*, *Abbrechen*, *Öffnen*. None of it is Shelf's to translate, and the
  one thing in it that *is* Shelf's decision — `not-a.txt` greyed out, from
  `CoverImage.accepted` — needs no words.
