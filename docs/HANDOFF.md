# Handoff – start prompt for a fresh session

Copy the block below into a new Claude Code session in `~/Documents/Shelf`.

---

## Prompt

Du arbeitest mit mir (Erik Emmer) an **Shelf**, einem Mac-only eBook-Manager im
Look & Feel von Selector. Repo: https://github.com/Erikemmer/Shelf (lokal
`~/Documents/Shelf`). Shelf ist ein modern aussehendes Calibre: Bibliothek,
Metadaten, Calibre-Import, Geräte – kein Reader, keine Konvertierung in v1.0.

**Lies zuerst, in dieser Reihenfolge:** `Programmier-Leitlinie.md` (bindend),
`CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/BACKLOG.md`, `CHANGELOG.md` (oben
steht der letzte Stand), diese Datei (Abschnitt „Nächster Schritt"). Das Fachliche
steht vollständig in `docs/CONCEPT.md`, das Datenmodell in `docs/DATA-MODEL.md`,
die Entscheidungen in `docs/adr/`.

**Rollen und Arbeitsweise**

- Du schreibst den Code, prüfst, committest und pushst selbst. Ich lese Berichte
  und entscheide bei echten Entscheidungen; eine zweite Claude-Sitzung reviewt
  deine Berichte und schreibt mir den nächsten Auftrag. Frag mich nur, wenn eine
  Entscheidung wirklich offen ist oder etwas Irreversibles anstünde; sonst
  entscheide selbst und schreib die Entscheidung in den Bericht.
- Vor jeder Änderung: Ziel in einem Satz, betroffene Dateien, Risiken. Kleine
  lauffähige Schritte. Zu jeder Änderung Tests und Doku (`CHANGELOG.md`,
  `docs/ARCHITECTURE.md`, `docs/DATA-MODEL.md`, ADR bei Entscheidungen). Am Ende
  jedes Berichts: Zusammenfassung in einfacher Sprache und ausdrücklich, was du
  nicht selbst prüfen konntest.
- **Prüfkette vor jedem Commit: `make test && make app && make lint &&
  make smoke`.** Nur wenn alle vier grün sind, wird committet; ein roter Schritt
  wird behoben, nie übersprungen. Ein Commit pro Anliegen, Conventional Commits,
  `git push` nach jedem abgeschlossenen Schritt, `git status --short` vor
  `git add -A`. WIP-Commit vor jeder Fehlersuche per Bisektion. Nie einen Prozess
  beenden, den du nicht gestartet hast.
- **SlateKit-Änderungen laufen über Commit + Tag + Abhängigkeits-Update.** Das
  Paket liegt in einem eigenen Repo (`~/Documents/SlateKit`,
  https://github.com/Erikemmer/SlateKit). Shelf bindet es über einen **Tag** ein
  (`project.yml`, derzeit `0.1.0`), nie über einen Pfad – sonst ändert ein
  Nachmittag Arbeit an SlateKit still, was diese App baut und wogegen ihre Tests
  gelaufen sind. Der Weg: dort ändern, `make test && make lint`, committen, Tag
  setzen und pushen, dann hier `exactVersion` hochziehen, `make project &&
  make app` und die vier Prüfungen. Was in SlateKit gehört, steht in
  `docs/adr/0004-slatekit-shared-with-selector.md`.
- Nichts Irreversibles. Buchdateien werden in v1.0 nie geschrieben, gelöscht
  oder überschrieben. Der Calibre-Ordner wird nur gelesen. Auf Geräten wird nur
  nach Bestätigung mit Namensliste gelöscht. DRM wird nie angefasst. Keine
  Secrets ins Repo. Testdaten nach `~/Library/Caches/Shelf/`, nie unter
  `~/Documents` (iCloud).
- UI-Texte Englisch (Deutsch in Sprint 7), Bezeichner Englisch, Kommentare
  erklären das *Warum*. Der Name „Lithothek" kommt in diesem Projekt nirgends vor.

---

## Nächster Schritt: Sprint 2 – Pflegen

Sprint 1 ist fertig und gemessen (Zahlen in `CHANGELOG.md`). Sprint 2 macht den
Inspector editierbar. Das Layout steht schon; es ist ein Wechsel der Steuer-
elemente, nicht des Aufbaus. Die Liste steht in `docs/BACKLOG.md` unter
„Sprint 2"; die Reihenfolge, die ich vorschlage:

1. **Undo zuerst, nicht zuletzt.** Der Weg, den Selector geht: Änderung →
   Model → Registrierung beim `UndoManager` des Fensters mit dem *vorherigen*
   Wert → Schreiben. Wer Undo nachrüstet, baut es zweimal.
2. **Ein Feld ganz durch**, bevor es vierzehn werden: Bewertung (1–5, 0) vom
   Inspector *und* von der Tastatur, mit Undo, mit atomarem OPF-Schreiben und
   Index-Nachzug. Daran hängt die ganze Kette.
3. Dann die übrigen Felder, Gelesen-Status (R) und Tags (T).
4. **Regale.** Sie sind das Einzige, was der Index weiß und eine Buchdatei
   nicht, also werden sie in jede OPF *und* in `library.json` gespiegelt
   (`docs/adr/0001-folder-is-the-truth.md`, Entscheidung 3). `ShelfTree` und das
   Schema sind fertig; es fehlen Anlegen, Umbenennen, Drag und die Sidebar-Zeilen.
5. **Tabelle (⌘2) und Mehrfachauswahl**, danach die beiden Smart Collections,
   die Sprint 1 bewusst deaktiviert gelassen hat: *Duplicates* braucht eine
   Abfrage über `isbn_normalised` und den gefalteten Titel-Schlüssel, *Not on
   any Shelf* braucht die Regale.
6. **⌘-Klick zum Kombinieren** der Sidebar-Filter, wie in Selector.

### Was dabei zu beachten ist

- `LibraryFilter.matches` nimmt `shelvedBooks` und `booksOnShelf` schon an;
  `LibraryModel.applyFilter` übergibt derzeit leere Mengen. Das ist die Stelle,
  an der die Regale ankommen.
- `SmartCollection.availableInSprintOne` ist die Liste, die beim Freischalten
  wächst. Sie steuert, welche Sidebar-Zeilen klickbar sind.
- `OPFDocument.render` ist stabil (gleiches Buch → gleiche Bytes). Bitte so
  lassen: nur dann bedeutet ein Diff in einem Bibliotheksordner eine echte
  Änderung.
- Unbekannte Metas werden gelesen **und zurückgeschrieben**
  (`Parsed.unmappedMetas`). Beim Schreiben eines editierten Buchs müssen sie
  wieder mitgehen, sonst verliert ein Calibre-Import seine eigenen Spalten.

## Offene Punkte, die keiner Sitzung gehören

- **Handprüfungen aus Sprint 1** stehen in `docs/BACKLOG.md` unter „Measurements
  still to take by hand": Zeit bis alle sichtbaren Cover stehen (kalt/warm),
  gehaltene Pfeiltaste 10 s mit `sample`, Speicher gegen die 1,5-GB-Grenze, und
  `make smoke` mit Bibliothek (braucht die Automation-Erlaubnis für System
  Events im Terminal).
- **App-Icon.** `App/Shelf/Resources/Assets.xcassets/AppIcon.appiconset` ist
  leer bis auf die `Contents.json`. Bis dort PNGs liegen, zeigt die App das
  Standardsymbol. Selector hat ein Skript dafür (`docs/icon/make_icons.py`).
- **SlateKit-Version.** Shelf hängt an `0.1.0`. Ein Pin, der nie erhöht wird,
  wird schal – beim ersten gemeinsamen UI-Bedarf mitziehen.
- **`Package.resolved` ist nicht im Repo** (`.gitignore`), wie in Selector. Wer
  reproduzierbare Abhängigkeiten will, nimmt die Zeile heraus; das ist eine
  Entscheidung, keine Nachlässigkeit.
