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
- **SlateKit-Änderungen laufen über einen eigenen Arbeitsbaum, Commit, Tag und
  Abhängigkeits-Update.** Das Paket liegt in einem eigenen Repo
  (https://github.com/Erikemmer/SlateKit) und wird über einen **Tag** eingebunden
  (`project.yml`, derzeit `0.3.1`), nie über einen Pfad. **Nie in
  `~/Documents/SlateKit` arbeiten** – dort arbeitet die Selector-Sitzung, und ein
  `git add -A` hat dort schon fremde Änderungen mitgenommen. Der ganze Weg,
  samt der Regel über Defaults und Zweisprachigkeit, steht in `CLAUDE.md` unter
  „Working on SlateKit“; was überhaupt in SlateKit gehört, in
  `docs/adr/0004-slatekit-shared-with-selector.md`.
- Nichts Irreversibles. Buchdateien werden in v1.0 nie geschrieben, gelöscht
  oder überschrieben. Der Calibre-Ordner wird nur gelesen. Auf Geräten wird nur
  nach Bestätigung mit Namensliste gelöscht. DRM wird nie angefasst. Keine
  Secrets ins Repo. Testdaten nach `~/Library/Caches/Shelf/`, nie unter
  `~/Documents` (iCloud).
- UI-Texte Englisch (Deutsch in Sprint 7), Bezeichner Englisch, Kommentare
  erklären das *Warum*. Der frühere Firmenname kommt in diesem Projekt nirgends vor.

---

## Nächster Schritt: Sprint 4 – weitere Formate

**Sprint 3 ist fertig, mit einer Ausnahme.** `CalibreReader` liest `metadata.db`
über eine Kopie samt WAL, das Zählprotokoll steht im Sheet und in
`shelf-tool calibre-dry`, der Import läuft über den vorhandenen `ImportRunner`
mit Wiederaufnahme, und Calibres eigene Spalten kommen nur lesend mit. Die
Zahlen stehen im `CHANGELOG.md`, die Belege in `docs/screenshots/sprint-3/`,
die Entscheidungen in ADR 0009 und 0010.

**Die Ausnahme: es hat noch keine echte Calibre-Bibliothek gesehen.** Alles
oben ist gegen eine synthetische gemessen, deren Tabellenformen diese Sitzung
von Hand geschrieben hat — mit Absicht so, damit die Fixture dem Leser nicht
per Konstruktion recht gibt, aber eine handgeschriebene Form ist trotzdem eine
Behauptung. `~/Downloads/Calibre Library Erik` enthält nur `metadata.db` ohne
Buchordner; das prüft das Schema und nicht den Import. **Erik muss den Pfad
nennen.**

Was als Nächstes ansteht (CONCEPT §11, Sprint 4):

1. **MOBI/AZW3** — PalmDB-Header und EXTH-Records (100 Autor, 503 Titel,
   104 ISBN, 106 Datum, 201 Cover-Offset) in `ShelfCore/Formats/Mobi`.
2. **PDF** — `documentAttributes` und Seite 1 gerendert, in der App-Schicht:
   PDFKit ist nicht Linux-fähig und der Kern muss es bleiben.
3. **CBZ** — Dateiname per Regex, optional `ComicInfo.xml`, erstes Bild als
   Cover. **CBR** — libarchive in der App-Schicht, RAR5 zur Laufzeit geprüft
   ([ADR 0003](adr/0003-zip-in-the-core.md)).
4. **DRM-Erkennung** — Adobe ADEPT über `META-INF/encryption.xml`, Kindle über
   EXTH 209. Erkennen, badgen, in Ruhe lassen (CONCEPT §12).
5. **`BookFileFormat.hasReadableMetadata`** wird für diese wahr — das ist die
   eine Stelle, die sich ändert.
6. **Quick Look** (␛).

### Was dabei zu beachten ist

- **Die Feldregeln liegen im Kern, nicht in der Ansicht.** `BookField`,
  `IdentifierEdit`, `TagEdit`, `ISBN`, `ShelfEdit` und `AcrossBooks` entscheiden,
  was ein leeres Feld bedeutet, wie Autoren getrennt werden, ob „2,5“ eine Zahl
  ist. Ein neues Feld ist dort ein Fall und im Inspector drei Zeilen.
- **Ein Regal steht im Buch, seine Form in `library.json`** (ADR 0008), und
  **eine eigene Spalte genauso**: der Wert im Buch, die Definition in
  `library.json` (ADR 0010). Beim Wiederaufbau **zuerst den Baum und die
  Spalten, dann die Bücher** — die andere Reihenfolge verliert die Zuordnung
  bzw. die Namen, ohne zu klagen. Beides ist passiert und beides ist jetzt
  getestet.
- **Der Kern schreibt den Index während des Laufs**, nicht erst am Ende
  (`ImportRunner.saveBatch`). Ein abgebrochener Import hat sonst Dateien auf der
  Platte, von denen der Index nichts weiß, und der nächste Lauf kopiert alles
  noch einmal. Wer den Runner anfasst, lässt das so.
- **`books.number` ist eindeutig, und der Index stirbt nicht mehr daran.** Zwei
  Ordner können dieselbe Nummer tragen; der Index gibt dem zweiten eine freie
  und benennt den Ordner nicht um (ADR 0007).
- **`Metas.known` in `OPFDocument` ist eine Liste von acht Namen, kein Präfix.**
  Wer eine Meta zum Leser hinzufügt, trägt sie dort ein — sonst wird sie beim
  nächsten Schreiben stillschweigend fallen gelassen, was mit Calibres
  `user_metadata` genau so passiert ist.
- **`SHELF_TIMING=1`** schaltet die Zeitmessungen im Fenster ein.
- **SlateKit steht auf `0.3.1`**, und der Weg zu einer Änderung steht jetzt in
  `CLAUDE.md`: eigener Arbeitsbaum, Dateien namentlich stagen, bestehende
  Komponenten behalten ihren Default, das Paket bleibt zweisprachig.

### Fallstricke, die diese Sitzung bezahlt hat

- **`grep -q` hinter einer Pipe macht unter `pipefail` aus einem Treffer den
  Status 141.** Das Kommando auf der anderen Seite bekommt SIGPIPE. Es hat einen
  ganzen Screenshot-Lauf gekostet („⌘2 hat die Tabelle nicht gezeigt“ — sie war
  da). `tree_has` nutzt `grep -c`. Und: eine erste Prüfung davon lief in **zsh**
  und kam mit 0 zurück. Die Skripte sind bash.
- **Ein gesperrter Bildschirm** macht jedes fenstergetriebene Skript still
  kaputt, und `caffeinate -di` reicht auf diesem Mac nicht: der Bildschirmschoner
  schaut auf Benutzeraktivität, also `-dimsu`. Die Wache fragt jetzt auch
  *während* des Laufs, nicht nur beim Start.
- **`sample` auf dem PATH ist hier ein Python-Skript**, nicht `/usr/bin/sample`.
  Es antwortet mit `ModuleNotFoundError` und Exit 1.
- **Ein voller Accessibility-Abzug einer 5 000-Bücher-Ansicht ist nichts für
  eine Schleife.** Drei Ebenen reichen für das Ansichts-Segment.
- **System Events liefert ⌘⌥I nicht an diese App.** Die Blende kam einfach nicht,
  ohne Fehler irgendwo. `Scripts/calibre-shot.sh` klickt den Menüpunkt.
- **`UInt8(n)` trapt über 255.** Die Calibre-Fixture schrieb 255 Ordner, stürzte
  mit SIGTRAP ab und ließ eine `metadata.db` von null Bytes zurück, die das
  Zählprotokoll dann korrekt und nutzlos als „Bibliothek ohne Tabellen“ las.

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

- **Bildschirmfotos: erledigt, mit einer Einschränkung.** Die Freigabe
  „Bildschirmaufnahme" ist erteilt, `Scripts/screenshots.sh` läuft, und die
  Bilder liegen in `docs/screenshots/sprint-1/` (Shelf und Selector, gleiche
  Größe), `docs/screenshots/sprint-2b/` und `docs/screenshots/sprint-2c/`.
  Drei der vier Vergleichspixel sind byte-gleich mit Selector.
  **Was die Skripte brauchen:** dass *keine* Shelf-Instanz läuft – sie brechen
  sonst mit einer Erklärung ab, statt eine fremde zu fotografieren; für Selector
  ein offenes Fenster; und **einen entsperrten Bildschirm** (siehe den Fallstrick
  oben). Aus 2c fehlen drei Aufnahmen, weil der Bildschirm mitten im Lauf
  gesperrt hat; `docs/screenshots/sprint-2c/README.md` sagt, welche und wofür
  es stattdessen Belege gibt.
- **Die übrigen Handprüfungen aus Sprint 1 sind erledigt** und stehen mit Zahlen
  im `CHANGELOG.md`: Fensterzahl (eines, nicht sechs), Zeit bis alle sichtbaren
  Cover stehen (852 ms kalt, 768 ms warm), gehaltene Pfeiltaste mit `sample`,
  Spitzenspeicher im Vordergrund (301 MB).
- **App-Icon.** `App/Shelf/Resources/Assets.xcassets/AppIcon.appiconset` ist
  leer bis auf die `Contents.json`. Bis dort PNGs liegen, zeigt die App das
  Standardsymbol. Selector hat ein Skript dafür (`docs/icon/make_icons.py`).
- **SlateKit-Version.** Shelf hängt an `0.3.1`, Selector weiter an `0.1.6`.
  **Selector kann jetzt gefahrlos nachziehen**: 0.3.1 macht die drei
  Aussehensänderungen aus 0.3.0 zu Optionen mit dem alten Default und holt die
  deutsche Lokalisierung zurück, die Selector ausliefert. Shelf setzt die
  Optionen und sieht aus wie vorher. Geprüft ist das durch sieben Tests über die
  Defaults, **nicht** durch einen Selector-Build – den anzufassen war nicht
  meine Sache.
- **`Package.resolved` ist nicht im Repo** (`.gitignore`), wie in Selector. Wer
  reproduzierbare Abhängigkeiten will, nimmt die Zeile heraus; das ist eine
  Entscheidung, keine Nachlässigkeit.
