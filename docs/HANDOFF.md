# Handoff – start prompt for a fresh session

Copy the block below into a new Claude Code session in `~/Documents/Shelf`.

---

## Prompt

Du arbeitest mit mir (Erik Emmer) an **Shelf**, einem Mac-only eBook-Manager im
Look & Feel von Selector. Repo: https://github.com/Erikemmer/Shelf (lokal
`~/Documents/Shelf`). Shelf ist ein modern aussehendes Calibre: Bibliothek,
Metadaten, Calibre-Import, Geräte – kein Reader, keine Konvertierung in v1.0.
Stand: Sprints 1–6 fertig, `main` grün, 588 Kern-Tests, SlateKit-Pin 0.3.1.

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

## Nächster Schritt: Sprint 7 – Deutsch, Barrierefreiheit, Signierung → v1.0

**Sprint 6 ist fertig.** ⌘E fragt Open Library und Google Books, ohne
API-Schlüssel, über die ISBN wenn es eine gültige gibt und sonst über Titel und
Autor. Was zurückkommt, ist eine Kandidatenliste mit einer Trefferzahl von 0 bis
100; der gewählte Kandidat steht danach Feld für Feld neben dem Buch, alt über
neu, ein Kästchen je Feld. **Angehakt ist nur, was eine Lücke füllt** – und das
auch nicht immer, siehe unten. Übernehmen geht durch dieselbe Kette wie jede
Änderung im Inspector: Undo zuerst, dann `metadata.opf`, dann der Index
([ADR 0015](adr/0015-online-metadata-two-sources-field-by-field.md)). 588
Kern-Tests, Zahlen im `CHANGELOG.md`, Bilder in
`docs/screenshots/sprint-6/README.md`.

**Die Einschränkung, und sie ist wieder keine Formalie.** Google Books hat an
diesem Tag auf **alle zehn ISBNs mit HTTP 429** geantwortet – das gemeinsame
Kontingent für Anfragen ohne Schlüssel war aufgebraucht, bevor Shelf überhaupt
gefragt hat, und zwar von beiden Hostnamen und mit jedem `country`-Parameter.
Open Library kannte neun von zehn. Das heißt: **Shelf hat noch nie eine Antwort
von Google Books gelesen.** Der Leser ist gegen *eine handgeschriebene* Datei
geprüft, die nach Googles dokumentierter Form gebaut und in
`Tests/ShelfCoreTests/Fixtures/online/README.md` genau so benannt ist. Ein
erneuter Lauf von `Scripts/online-proof.sh` überschreibt sie mit einer echten
Antwort, sobald das Kontingent es zulässt. Das ist die erste Zeile für Sprint 7.

**Drei Dinge, die weiter auf Erik warten** (die ersten beiden seit Sprint 3
bzw. 4):

1. **Eine echte Calibre-Bibliothek.** `~/Downloads/Calibre Library Erik` enthält
   nur `metadata.db` ohne Buchordner. **Erik muss den Pfad nennen.**
2. **Echte Bücher.** Ein gekauftes MOBI oder AZW3, ein echtes CBR, eine wirklich
   DRM-geschützte Datei. **Vier Dateien würden reichen.**
3. **Ein echtes Lesegerät.** Siehe „Die Sandbox-Frage" weiter unten – sie ist
   nach wie vor offen, weil in diesem Lauf kein Wechselmedium angesteckt war.

Was als Nächstes ansteht (CONCEPT §11, Sprint 7):

1. **Deutsch.** Jede UI-Zeichenkette in `Localizable.xcstrings`, mit einem Test,
   der eine fehlende Fassung rot macht – so wie SlateKit es schon hat.
2. **Barrierefreiheit.** Die zwei bekannten Löcher stehen in `docs/BACKLOG.md`
   unter „Housekeeping": Seitenleisten-Zeilen haben keine Rolle, die eine
   Tastatur aktivieren kann, und die Pfeiltasten hängen an der Menüleiste.
3. **Signierung, Notarisierung, Direkt-Download, Runbook.**

### Was dabei aus Sprint 6 mitzunehmen ist

- **Ein Netz-Zugriff ist eine Regel plus ein Socket, und nur das Socket gehört
  in die App.** `MetadataTransport` ist die Naht. Alles darüber – welche URL,
  wie oft, was ein 503 heißt und was ein 429 heißt, ob schon gefragt wurde, was
  die zwei JSON-Formen bedeuten, welcher Kandidat das Buch ist – liegt im Kern
  und ist ohne Netz geprüft. `URLSessionTransport` sind dreißig Zeilen. **Kein
  Test und kein CI-Lauf öffnet ein Socket**; die Tests lesen gespeicherte echte
  Antworten.
- **Ein Dienst, der ausfällt, ist eine Zeile und kein Abbruch.** Fällt einer
  aus, bleiben die Kandidaten des anderen. Genau das war an dem Tag der
  Normalfall und nicht der Sonderfall.
- **Nichts wird angehakt, was etwas ersetzen würde.** Und seit dem Blick auf den
  Screenshot auch nichts, was aus einem *Werk*-Datensatz stammt und eine
  Auflage beschreibt (Verlag, Sprache, Jahr). Open Library antwortet auf
  Werk-Ebene und reicht die Felder irgendeiner Auflage durch: für ein
  Puffin-Taschenbuch von *Fantastic Mr Fox* kamen `Caedmon Audio Cassette`,
  `ja` und **1917**.
- **Ein Bild ansehen findet, was kein Test findet.** Zwei Fehlverhalten dieses
  Sprints stammen aus genau einem Blick auf je einen Screenshot: das
  vorangehakte Jahr 1917 und „Tags – would replace" über einer Zeile, die nichts
  ersetzt.

### Was dabei zu beachten ist

- **Die Feldregeln liegen im Kern, nicht in der Ansicht.** `BookField`,
  `IdentifierEdit`, `TagEdit`, `ISBN`, `ShelfEdit` und `AcrossBooks` entscheiden,
  was ein leeres Feld bedeutet, wie Autoren getrennt werden, ob „2,5" eine Zahl
  ist. Seit Sprint 6 geht auch jeder Wert aus dem Netz durch dieselben Regeln:
  eine ISBN mit falscher Prüfziffer wird abgelehnt, egal wer sie angeboten hat.
- **Ein Regal steht im Buch, seine Form in `library.json`** (ADR 0008), und
  **eine eigene Spalte genauso** (ADR 0010). Beim Wiederaufbau **zuerst den Baum
  und die Spalten, dann die Bücher**.
- **Der Kern schreibt den Index während des Laufs** (`ImportRunner.saveBatch`),
  nicht erst am Ende.
- **`Metas.known` in `OPFDocument` ist eine Liste von acht Namen, kein Präfix.**
  Wer eine Meta zum Leser hinzufügt, trägt sie dort ein.
- **Was im Index steht, muss aus dem Ordner wieder herleitbar sein** (ADR 0001).
- **`ImportRunner` kennt nur Bücher, die er selbst angelegt hat** – für ein
  vorhandenes Buch braucht er `existingEntry`.
- **`SHELF_TIMING=1`** schaltet die Zeitmessungen im Fenster ein,
  **`SHELF_ONLINE_HOST=metadata.invalid`** schickt die Metadaten-Abfragen an
  einen Namen, den es nie geben wird (RFC 2606) – so wird ein Netzfehler
  fotografiert, ohne an den Systemeinstellungen zu drehen.
- **SlateKit steht auf `0.3.1`**; der Weg zu einer Änderung steht in `CLAUDE.md`.
- **Welches Format wer liest, ist eine Tabelle, kein `if`**
  (`BookFileFormat.readerLayer`).

### Die Sandbox-Frage, unverändert offen

`com.apple.security.files.removable-volumes.read-write` steht in den
Entitlements. Mit ihr konnte die App bei einem **Disk-Image** Name und freien
Platz lesen und das Verzeichnis **nicht** auflisten – eine Karte mit fünf
Büchern zeigte „0 books". Für echte Wechselmedien ist die Entitlement gedacht,
bewiesen ist es nicht. In diesem Lauf war **kein Wechselmedium angesteckt**:
`/Volumes/` enthielt nur `Macintosh HD`, `diskutil list` zeigte keine externe
Platte und `system_profiler SPUSBDataType` überhaupt nichts. Geht es nicht, ist
die automatische Erkennung Zierde, und jedes Gerät muss über
`Device ▸ Treat Volume as Device…` von Hand gewählt werden. **Mit einem Kobo
oder Kindle am Kabel in zwei Minuten geklärt.**

### Fallstricke, die die Sitzungen bezahlt haben

Aus Sprint 6:

- **Ein direkt gestartetes App-Bundle hat für die Accessibility-API keine
  Fenster.** `"$APP/Contents/MacOS/Shelf"` startet die App, sie zeichnet ihr
  Fenster, und `ax-dump.swift` antwortet „no windows for pid …". `open -a` geht
  über LaunchServices und registriert sie richtig. Ein ganzer Screenshot-Lauf.
- **Die Fixtures wären fast Attrappen geworden.** `shelf-tool synthesise`
  schreibt nur manchen Büchern eine ISBN, und ein `sed`, das die ISBN *ersetzt*,
  ersetzt dann nichts. Zehn Bücher gingen mit Titel-Suche statt ISBN-Suche durch
  den Lauf, und der Screenshot sah trotzdem richtig aus.
- **`grep -q` hinter einer Pipe macht unter `pipefail` aus einem Treffer den
  Status 141.** `tree_has` nutzt `grep -c`. Die Skripte sind bash, nicht zsh.
- **Ein Klick auf das Suchfeld direkt nach einem geschlossenen Blatt landet, bevor
  das Fenster die Tastatur zurückhat**, und das Getippte hängt sich an die alte
  Suche an: „Left HandClean Code" findet nichts, und der Fehler beschuldigt das
  Raster. ⌘F über den Menüpunkt kann nicht danebengehen.
- **Ein einziger Kandidat mit 100 Punkten öffnet sich ohne Klick** – gewollt,
  und es hat ein Skript zerlegt, das auf die Kandidatenliste gewartet hat.
- **Open Library ist mal 1,9 s und mal 24 s schnell** für dieselbe Art Frage.
  Ohne Wiederholung meldete der erste Beweislauf drei von zehn als Zeitüberschreitung;
  alle drei antworteten beim zweiten Versuch in unter drei Sekunden.

Aus Sprint 5, weiter gültig:

- **Ein gesperrter Bildschirm** macht jedes fenstergetriebene Skript still
  kaputt; `caffeinate -di` reicht auf diesem Mac nicht, es ist `-dimsu`.
- **`screencapture -l <fenster-id>` fotografiert den Backing Store**, der bei
  einer gescrollten SwiftUI-`ScrollView` nicht neu gezeichnet wird. `-R` mit dem
  Fensterrechteck fotografiert, was ein Mensch sieht – und damit auch den
  Tooltip des Dock-Symbols, weshalb `Scripts/cursor-park.swift` den Zeiger
  vorher wegschiebt.
- **Die beiden `contentsOfDirectory` widersprechen sich auf FAT**; die Pfad-Form
  meldet `system` als `System`.
- **APFS ist case-insensitiv**, also ist `fileExists` keine Antwort auf „heißt da
  etwas so": `/System` und `/Applications` beantworten die Marker eines
  PocketBooks.
- **libarchive stürzt ab, wenn man ein Format zweimal registriert.**
- **macOS stellt die Fenster wieder her, die eine *abgeschossene* App hatte.**
  Ein ordentliches `quit` setzt es zurück.
- **`UInt8(n)` trapt über 255**, und **`hdiutil` legt unter etwa 40 MB kein
  FAT32 an**.
- **Eine Fixture, die mit sich selbst kollidiert, misst die Duplikatprüfung.**
  Jede generierte Datei trägt ihren Index jetzt in den Bytes.
- **macOS schreibt Akzente auf FAT32 zerlegt**; dass die Zuordnung trotzdem
  trägt, liegt an Swifts kanonischem String-Vergleich.
- **Ein Check gegen den ganzen Accessibility-Baum beantwortet „steht das Wort
  irgendwo im Fenster"** – nicht „hat *dieses Buch* mehrere Dateien".

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
- **App-Icon: erledigt.** Eriks fertiges Paket liegt in `docs/icon/`, die
  macOS-Variante ist das `AppIcon`-Asset der App, alle zehn Größen mit `sips`
  geprüft, `iconutil -c icns` als Gegenprobe, Belege in
  `docs/screenshots/sprint-4/`. **Eine Falle für den Nächsten:** der Dock zeigt
  nach dem ersten Build weiter das Standardsymbol, weil LaunchServices das
  Symbol des leeren Icon-Sets zwischengespeichert hat. `lsregister -f <app>`
  räumt das auf; am Bundle ist nichts falsch.
  Der Willkommensschirm zeigt weiterhin das Platzhalter-Logo aus SlateKits
  Welcome-Gerüst, nicht das App-Icon – das war nicht beauftragt und ist keine
  Nachlässigkeit, sondern eine offene Frage an Erik.
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
