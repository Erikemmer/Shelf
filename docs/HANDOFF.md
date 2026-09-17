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
  (`project.yml`, derzeit `0.3.0`), nie über einen Pfad – sonst ändert ein
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

## Nächster Schritt: Sprint 3 – Calibre-Import

**Sprint 2c ist fertig.** Regale (hierarchisch, per Drag, mit Bestätigung beim
Löschen), die Tabelle (⌘2, Spalten wählbar, Kopfzeile sortiert), sechs
Sortierungen in beide Richtungen, Mehrfachauswahl mit einem Undo-Schritt, und
die beiden letzten Smart Collections (*Duplicates*, *Not on any Shelf*). Die
Zahlen stehen im `CHANGELOG.md`, die Belege in `docs/screenshots/sprint-2c/`
und in `Scripts/shelf-proof.sh`.

Was als Nächstes ansteht, in dieser Reihenfolge:

1. **`CalibreReader`.** `metadata.db` **nur über eine Kopie** in
   `~/Library/Caches/Shelf/` lesen – nie die Originaldatei öffnen, auch nicht
   lesend (CLAUDE.md). Schema-Version prüfen; eine unbekannte ist eine Warnung,
   kein Abbruch.
2. **Das Zählprotokoll vor dem Import**: Bücher, Formate je Typ, Tags, Serien,
   Autoren, Custom Columns mit ihren Typen, Dateien in der DB die auf der Platte
   fehlen und umgekehrt, Gesamtgröße, freier Platz × 1,05. `ImportSheet` macht
   das für einen Ordner schon; ein Calibre-Ordner ist derselbe Ablauf mit einer
   besseren Quelle.
3. **Der Import selbst**, mit Wiederaufnahme über UUID + Hash. `ImportRunner`
   und `ImportReport` sind fertig; was fehlt, ist die Quelle.
4. **Custom Columns read-only.** `custom_columns` / `custom_values` stehen seit
   Migration 1 im Schema, und `OPFDocument` hebt unbekannte Metas ohnehin auf –
   ein Import verliert sie also heute schon nicht.
5. **Der Beweislauf gegen deine echte Calibre-Bibliothek**: Zahlen vorher und
   nachher, Stichproben-Hashes, und `find -newer` als Beleg, dass der
   Calibre-Ordner unangetastet geblieben ist.

### Was dabei zu beachten ist

- **Die Feldregeln liegen im Kern, nicht in der Ansicht.** `BookField`,
  `IdentifierEdit`, `TagEdit`, `ISBN`, `ShelfEdit` und `AcrossBooks` entscheiden,
  was ein leeres Feld bedeutet, wie Autoren getrennt werden, ob „2,5" eine Zahl
  ist, was ein Regalname sein darf, und was zwölf Bücher gemeinsam haben. Ein
  neues Feld ist dort ein Fall und im Inspector drei Zeilen.
- **Ein Regal steht im Buch, seine Form in `library.json`**
  ([ADR 0008](adr/0008-shelves-membership-in-the-book-hierarchy-in-library-json.md)).
  Beim Wiederaufbau **zuerst den Baum speichern, dann die Bücher** – der Index
  löst die Pfade eines Buches gegen die Regale auf, die er kennt, und überspringt
  stillschweigend, was er nicht findet. Die andere Reihenfolge verliert jede
  Zuordnung, ohne zu klagen.
- **Ein Regalpfad ist ein Name, kein Zeiger.** Ein Umbenennen schreibt jedes Buch
  auf dem Regal neu. Das ist der Preis für lesbare Pfade in der OPF und steht so
  in ADR 0008.
- **Die Tabelle sortiert über das Modell**, nicht im Speicher. `BookSort` besitzt
  die SQL-Reihenfolge; vier Spalten (Tags, Format, Gelesen, Größe) haben deshalb
  keinen Pfeil.
- **Der Ordner wird bei einer Metadatenänderung nicht umbenannt**
  ([ADR 0007](adr/0007-a-metadata-change-does-not-rename-the-folder.md)).
- **Attribut und Elementtext werden unterschiedlich escaped**, und `"\r\n"` ist
  in Swift *ein* `Character` – beide Escaping-Funktionen laufen über
  Unicode-Skalare.
- **FTS5 kennt kein `ALTER TABLE ADD COLUMN`.** Eine neue Suchspalte heißt:
  Tabelle neu bauen *und aus den Quelltabellen nachfüllen*.
- **`SHELF_TIMING=1`** schaltet die Zeitmessungen im Fenster ein.
- **SlateKit steht auf `0.3.0`.** Der Weg zu einer Änderung: dort ändern,
  `make test && make lint && make contrast`, committen, taggen, pushen, dann hier
  `exactVersion` hochziehen. Das Paket hat seit 2c ein `CHANGELOG.md`; 0.3.0
  ändert das Aussehen von **Selector** mit, sobald Selector seinen Pin hochzieht
  (graue Chips statt goldener, Platzhalter in Label-Farbe, kein „3/5" neben den
  Sternen, keine deutsche Lokalisierung mehr).

### Ein Fallstrick, der eine Stunde gekostet hat

**Ein gesperrter Bildschirm macht jedes fenstergetriebene Skript still kaputt.**
Nicht rot – still. `screencapture -l <window id>` liefert weiter das *zuletzt
gezeichnete Bild* des Fensters, also kommen mehrere Aufnahmen byte-gleich heraus;
System Events sieht keine Fenster; und der Accessibility-Baum schrumpft auf ein
Application-Element, das nur sich selbst enthält, sodass jede Suche „nichts"
antwortet statt zu scheitern. `Scripts/window-count.swift` liest dann `5 0 0`.

Bestätigt mit `ioreg -n Root -d1 -r | grep CGSSessionScreenIsLocked` mitten im
Screenshot-Lauf. Das ist mit hoher Wahrscheinlichkeit auch das, was Sprint 2b als
„eine App ohne Fenster, nicht reproduzierbar, kein Absturzbericht" notiert hat.
`Scripts/shots-2c.sh` prüft das jetzt beim Start und startet sich selbst unter
`caffeinate -di` neu; die anderen Skripte sollten denselben Schutz bekommen.

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
- **SlateKit-Version.** Shelf hängt an `0.3.0`, Selector an `0.1.6`. Wenn
  Selector nachzieht, ändert sich sein Aussehen an drei Stellen (Chips, Sterne,
  Platzhalter) und die deutschen Strings des Pakets verschwinden – das ist so
  gewollt und steht in SlateKits `CHANGELOG.md`.
- **`Package.resolved` ist nicht im Repo** (`.gitignore`), wie in Selector. Wer
  reproduzierbare Abhängigkeiten will, nimmt die Zeile heraus; das ist eine
  Entscheidung, keine Nachlässigkeit.
