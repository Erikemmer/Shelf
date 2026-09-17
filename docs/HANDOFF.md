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
  erklären das *Warum*. Der frühere Firmenname kommt in diesem Projekt nirgends vor.

---

## Nächster Schritt: Sprint 2b – Tags, Regale, Serien, Suche, Tabelle

**Sprint 2a ist fertig**: ein Feld ganz durch, mit Undo zuerst, wie es hier
vorgeschlagen war. `MetadataChange` und `MetadataEditor` liegen im Kern und
machen aus „altes Buch, neues Buch" ein OPF-Delta plus Index-Nachzug; die
App-Schicht hängt nur die Registrierung beim `UndoManager` des Fensters und den
Dateischreibvorgang an. Bewertung (Inspector, 1–5, 0) und Gelesen-Status
(Inspector, R) sind editierbar, ⌘Z/⇧⌘Z funktionieren, die Zahlen stehen im
`CHANGELOG.md`.

Was als Nächstes ansteht, in dieser Reihenfolge:

1. **Die übrigen Felder im Inspector** – Titel, Autoren, Serie, Verlag, Datum,
   Sprache, Beschreibung. Die Kette steht; das sind Textfelder gegen dieselbe
   `MetadataChange`. **Hier wird Entprellen nötig**: bei 5–8 ms je Schreibvorgang
   war es für Bewertung und Gelesen-Status keines wert, aber ein Textfeld
   schreibt sonst pro Tastendruck eine Datei.
2. **Tags (T)**, mit `SlateSuggestionChip` für die vorhandenen Tags.
3. **Regale.** Das Einzige, was der Index weiß und eine Buchdatei nicht, also in
   jede OPF *und* in `library.json` gespiegelt (ADR 0001, Entscheidung 3).
   `ShelfTree`, das Schema und `shelf:shelves` sind fertig; es fehlen Anlegen,
   Umbenennen, Drag und die Sidebar-Zeilen. Danach wird
   `LibraryModel.applyFilter` die leeren Mengen los, die es heute übergibt, und
   *Not on any Shelf* wird freigeschaltet.
4. **Serienansicht**, **Tabelle (⌘2)**, **Mehrfachauswahl**, dann *Duplicates*
   (Abfrage über `isbn_normalised` und den gefalteten Titel-Schlüssel).
5. **⌘-Klick zum Kombinieren** der Sidebar-Filter.

### Was dabei zu beachten ist

- **Der Index liefert Identifier jetzt mit.** Bis Sprint 2a war
  `entries.identifiers` immer leer: der Inspector hat die ISBN-Zeile nie
  gezeichnet, und ein erneutes `save` einer aus dem Index gelesenen Zeile hätte
  die Identifier-Zeilen gelöscht und keine zurückgeschrieben – also die ISBN
  jedes bearbeiteten Buchs und damit die Duplikatsprüfung. Beides ist behoben
  und getestet.
- **`MetadataEditor` legt das Delta über die Datei, nicht über den Index.**
  Calibres eigene Spalten stehen nur in der OPF; ein Schreiben aus der
  Index-Sicht würde sie stillschweigend wegwerfen. Neue Felder gehören deshalb
  in `MetadataChange.Field` – dort stehen „was hat sich geändert" und „kopiere
  das Geänderte" nebeneinander.
- **Tastenkürzel zum Bearbeiten gehören nicht in die Menüleiste**
  (ADR 0006, mit Messung). Die Pfeiltasten sind noch dort; das steht im Backlog.
- `OPFDocument.render` ist stabil (gleiches Buch → gleiche Bytes). Bitte so
  lassen: nur dann bedeutet ein Diff in einem Bibliotheksordner eine echte
  Änderung. `dcterms:modified` wird seit 2a mitgeschrieben.
- **`SHELF_TIMING=1`** schaltet die Zeitmessungen im Fenster ein (Öffnen,
  sichtbare Cover fertig, Tastendruck → OPF). Ohne die Variable ist es still.
  Lesen mit `open --env SHELF_TIMING=1 --stdout <datei> -a <Shelf.app> <Bibliothek>`.

## Eine Entscheidung, die dir gehört: SlateKit und CI

`Erikemmer/SlateKit` ist **privat**. Der Kern braucht es nicht – seine Tests
laufen auf Linux und auf macOS und sichern jeden Push ab. Die *App* braucht es,
und GitHub Actions kommt ohne Zugangsdaten nicht an ein privates Repo. Der
Job überspringt den App-Build deshalb mit einer sichtbaren Warnung, statt jeden
Lauf rot zu machen. Zwei Wege, einer davon ist zu wählen:

1. **Ein Secret `SLATEKIT_TOKEN`** im Shelf-Repo anlegen (fine-grained token mit
   Leserecht auf `Erikemmer/SlateKit`). Der Job nimmt es automatisch und baut
   die App dann mit. Nichts wird öffentlich.
2. **SlateKit öffentlich machen.** Dann entfällt das Secret. Das Paket enthält
   nur Aussehen und Layout, keinen Fachcode – aber es öffentlich zu machen ist
   eine Veröffentlichung, und die trifft diese Sitzung nicht von sich aus.

Bis dahin heißt „CI grün": der Kern ist auf beiden Plattformen grün und die App
wurde nicht gebaut. Lokal baut sie `make app`, und `make smoke` startet sie.

## Offene Punkte, die keiner Sitzung gehören

- **Bildschirmfotos brauchen eine Freigabe, die nur Erik geben kann.**
  `screencapture` verlangt „Bildschirmaufnahme" für das Terminal, das es
  startet; ohne sie verweigert es mit „could not create image from display" und
  schreibt gar nichts. **Weg:** Systemeinstellungen ▸ Datenschutz & Sicherheit ▸
  Bildschirmaufnahme, Terminal hinzufügen, Terminal beenden und neu öffnen, dann
  `Scripts/screenshots.sh`. Das Skript fotografiert Shelf *und* Selector in
  derselben Größe und liest mit `Scripts/pixel-probe.swift` dieselben vier Pixel
  aus beiden – Sidebar-Hintergrund, Hauptfläche, Inspector-Hintergrund,
  Sidebar-Zeile. „Sieht aus wie Selector" wird dadurch eine Zahl.
  Die Bedienungshilfen-Freigabe ist vorhanden, deshalb liegt der
  Barrierefreiheits-Baum in `docs/screenshots/` – er hat zwei Fehler gefunden,
  die auf einem Bildschirmfoto niemandem aufgefallen wären.
- **Die übrigen Handprüfungen aus Sprint 1 sind erledigt** und stehen mit Zahlen
  im `CHANGELOG.md`: Fensterzahl (eines, nicht sechs), Zeit bis alle sichtbaren
  Cover stehen (852 ms kalt, 768 ms warm), gehaltene Pfeiltaste mit `sample`,
  Spitzenspeicher im Vordergrund (301 MB).
- **App-Icon.** `App/Shelf/Resources/Assets.xcassets/AppIcon.appiconset` ist
  leer bis auf die `Contents.json`. Bis dort PNGs liegen, zeigt die App das
  Standardsymbol. Selector hat ein Skript dafür (`docs/icon/make_icons.py`).
- **SlateKit-Version.** Shelf hängt an `0.1.0`. Ein Pin, der nie erhöht wird,
  wird schal – beim ersten gemeinsamen UI-Bedarf mitziehen.
- **`Package.resolved` ist nicht im Repo** (`.gitignore`), wie in Selector. Wer
  reproduzierbare Abhängigkeiten will, nimmt die Zeile heraus; das ist eine
  Entscheidung, keine Nachlässigkeit.
