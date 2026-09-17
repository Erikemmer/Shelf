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
  (`project.yml`, derzeit `0.2.1`), nie über einen Pfad – sonst ändert ein
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

## Nächster Schritt: Sprint 2c – Regale, Tabelle, Sortierung, Mehrfachauswahl

**Sprint 2b ist fertig.** Alle Metadatenfelder sind editierbar, Tags sind Chips
mit Autovervollständigung, Serien filtern und ordnen, die Suche deckt die sechs
Felder aus CONCEPT §4 ab (ISBN inklusive). Die Zahlen stehen im `CHANGELOG.md`;
die Belege am Fenster in `docs/screenshots/sprint-2b/`.

Was als Nächstes ansteht, in dieser Reihenfolge:

1. **Regale.** Das Einzige, was der Index weiß und eine Buchdatei nicht, also in
   jede OPF *und* in `library.json` gespiegelt (ADR 0001, Entscheidung 3).
   `ShelfTree`, das Schema und `shelf:shelves` sind fertig; es fehlen Anlegen,
   Umbenennen, Drag und die Sidebar-Zeilen. Danach wird `LibraryModel.applyFilter`
   die leere Menge los, die es heute übergibt, und *Not on any Shelf* wird
   freigeschaltet.
2. **Tabelle (⌘2)**: sortierbar, Spalten wählbar. `BookSort` besitzt die
   SQL-Reihenfolge schon – die Tabellenüberschrift muss dieselbe Quelle nehmen,
   sonst behaupten Menü und Kopfzeile Verschiedenes.
3. **Mehrfachauswahl im Grid** und ein Feld über die Auswahl hinweg ändern.
   `MetadataChange` ist pro Buch gebaut; für n Bücher werden es n Änderungen in
   einem Undo-Schritt (`UndoManager.beginUndoGrouping`).
4. **Sortierung**, gespeichert je Bibliothek.
5. *Duplicates* (Abfrage über `isbn_normalised` und den gefalteten
   Titel-Schlüssel) und **⌘-Klick zum Kombinieren** der Sidebar-Filter.

### Was dabei zu beachten ist

- **Die Feldregeln liegen im Kern, nicht in der Ansicht.** `BookField`,
  `IdentifierEdit`, `TagEdit` und `ISBN` entscheiden, was ein leeres Feld
  bedeutet, wie Autoren getrennt werden, ob „2,5" eine Zahl ist. Ein neues Feld
  ist dort ein Fall und im Inspector drei Zeilen. Die Eigenschaft, die alles
  zusammenhält, ist getestet: *was ein Feld anzeigt, akzeptiert dasselbe Feld
  zurück.*
- **Ein Feld wird beim Abschluss geschrieben, nicht beim Tippen** (⏎ oder
  Fokusverlust), Escape verwirft. Kein Timer – ein Timer schriebe mitten im Wort
  und müsste vor dem Schließen des Fensters geleert werden.
- **Die Bearbeitungstasten hängen an keinem Fokus mehr.** `EditingKeyMonitor`
  ist ein lokaler `NSEvent`-Monitor; seine einzige Regel ist, sich aus Text
  herauszuhalten, den jemand tippt. Menü-Kurzbefehle bleiben draußen (ADR 0006).
  **Offen:** Ein Klick aufs Cover nimmt dem *Suchfeld* die Tastatur nicht
  zuverlässig ab; Escape im Suchfeld tut es. Steht im Backlog.
- **Der Ordner wird bei einer Metadatenänderung nicht umbenannt**
  ([ADR 0007](adr/0007-a-metadata-change-does-not-rename-the-folder.md)). Die
  UUID hält die Identität. „Reorganize Library…" mit Vorschau kommt später.
- **Attribut und Elementtext werden unterschiedlich escaped.** Ein Zeilenumbruch
  in einem Attribut wird sonst beim Parsen zu einem Leerzeichen, und
  `calibre:title_sort`, `calibre:series` und `opf:file-as` sind Attribute. Und:
  `"\r\n"` ist in Swift *ein* `Character` – deshalb laufen beide
  Escaping-Funktionen über Unicode-Skalare.
- **FTS5 kennt kein `ALTER TABLE ADD COLUMN`.** Eine neue Suchspalte heißt:
  Tabelle neu bauen *und aus den Quelltabellen nachfüllen*. Ohne das Nachfüllen
  verliert eine bestehende Bibliothek ihren ganzen Suchindex.
- **`SHELF_TIMING=1`** schaltet die Zeitmessungen im Fenster ein. Ohne die
  Variable ist es still.
- **SlateKit steht auf `0.2.1`.** Der Weg zu einer Änderung: dort ändern,
  `make test && make lint && make contrast`, committen, taggen, pushen, dann
  hier `exactVersion` hochziehen. Achtung beim Hochziehen: `SlateSidebarRow` hat
  in 0.1.4 einen `accessory`-ViewBuilder *vor* `action` bekommen, wodurch
  Trailing-Closures still an den falschen Parameter binden.

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

- **Bildschirmfotos: erledigt.** Die Freigabe „Bildschirmaufnahme" ist erteilt,
  `Scripts/screenshots.sh` läuft, und die Bilder liegen in
  `docs/screenshots/sprint-1/` (Shelf und Selector, gleiche Größe) und
  `docs/screenshots/sprint-2b/`. Drei der vier Vergleichspixel sind byte-gleich
  mit Selector. **Was das Skript braucht:** dass *keine* Shelf-Instanz läuft –
  es bricht sonst mit einer Erklärung ab, statt eine fremde zu fotografieren.
  Und für Selector ein offenes Fenster; eine Instanz unter Xcodes Debugger hat
  meist keines.
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
