# Handoff – start prompt for a fresh session

Copy the block below into a new Claude Code session in `~/Documents/Shelf`.

---

## Prompt

Du arbeitest mit mir (Erik Emmer) an **Shelf**, einem Mac-only eBook-Manager im
Look & Feel von Selector. Repo: https://github.com/Erikemmer/Shelf (lokal
`~/Documents/Shelf`). Shelf ist ein modern aussehendes Calibre: Bibliothek,
Metadaten, Calibre-Import, Geräte – kein Reader, keine Konvertierung in v1.0.
Stand: Sprints 1–5 fertig, `main` grün, 531 Kern-Tests, SlateKit-Pin 0.3.1.

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

## Nächster Schritt: Sprint 6 – Online-Metadaten (Open Library, Google Books)

**Sprint 5 ist fertig, gegen Disk-Images.** Shelf erkennt Kobo, Kindle, Tolino
und PocketBook an ihren Markerpfaden; die Geräteprofile sind vier JSON-Dateien
(ADR 0013). Bücher gehen per Drag auf die Gerätezeile oder ⌘⇧S hinüber, im
Format, das *das Gerät* bevorzugt, mit SHA-256-Rückleseprüfung auf der Karte,
Manifest, Wiederaufnahme und Bericht „Verified · n books · Skipped: n ·
Failed: n“. Der Geräteinhalt wird gelistet und den Büchern zugeordnet, ein Kobo
zusätzlich nur lesend ausgelesen. Gelöscht wird ausschließlich hinter einer
Bestätigung, die jede Datei beim Namen nennt (ADR 0014). Zahlen im
`CHANGELOG.md`, Bilder in `docs/screenshots/sprint-5/README.md`.

**Die große Einschränkung, und sie ist keine Formalie.** Kein echtes Gerät war
angesteckt. Die vier „Lesegeräte“ sind `hdiutil`-Images. Alles, was eine *Regel*
ist, ist damit gemessen; alles, was Hardware ist, nicht — die Liste steht in
`docs/BACKLOG.md` unter „To check on real hardware“. Die erste Zeile davon ist
die wichtigste:

> **Die Sandbox lässt die App in ein Disk-Image nicht hineinsehen.**
> `com.apple.security.files.removable-volumes.read-write` steht in den
> Entitlements, und mit ihr konnte die App Name und freien Platz eines Images
> lesen und sein Verzeichnis **nicht** auflisten — eine Karte mit fünf Büchern
> zeigte „0 books“. Für echte Wechselmedien ist genau diese Entitlement gedacht,
> es sollte also gehen. Bewiesen ist es nicht. Geht es nicht, ist die
> automatische Erkennung Zierde, und jedes Gerät muss über
> `Device ▸ Treat Volume as Device…` von Hand gewählt werden. **Das ist mit
> einem Kobo oder Kindle am Kabel in zwei Minuten geklärt und sollte als Erstes
> geklärt werden.**

**Drei Dinge, die weiter auf Erik warten** (die ersten beiden seit Sprint 3
bzw. 4):

1. **Eine echte Calibre-Bibliothek.** `~/Downloads/Calibre Library Erik` enthält
   nur `metadata.db` ohne Buchordner. **Erik muss den Pfad nennen.**
2. **Echte Bücher.** Ein gekauftes MOBI oder AZW3, ein echtes CBR, eine wirklich
   DRM-geschützte Datei. **Vier Dateien würden reichen.**
3. **Ein echtes Lesegerät.** Siehe oben.

Was als Nächstes ansteht (CONCEPT §9, Sprint 6):

1. **Open Library und Google Books**, ohne API-Schlüssel, zuerst über ISBN, dann
   über Titel + Autor.
2. **Kandidatenliste**, dann Feld für Feld alt/neu mit je einer Auswahl — nichts
   wird stillschweigend überschrieben. Das ist dieselbe Haltung, die das
   Zählprotokoll beim Import und das Transfer-Blatt beim Gerät haben: erst
   zeigen, dann tun.
3. **Cover aus dem Netz**, wenn die Datei keins hat.
4. **Netzfehler sind leise**: eine Zeile in der Statusleiste, nie ein Modal.

### Was dabei aus Sprint 5 mitzunehmen ist

- **Ein Netz-Zugriff ist wie ein Gerät: die Regel gehört in den Kern, die
  Verbindung in die App.** `DeviceDetection`, `TransferPlanner`,
  `DeviceFileName` und `DeviceDeletion` sind reine Werte und deshalb ohne Gerät
  geprüft; `DeviceWatcher` und `DeviceModel` halten AppKit und die Tasks. Für
  Sprint 6 heißt das: Parser, Feldabgleich und „welcher Kandidat passt“ in den
  Kern, `URLSession` in die App.
- **Ein Bericht gehört dorthin, worüber er spricht.** Der Import-Bericht liegt
  in der Bibliothek, der Transfer-Bericht auf dem Gerät. Ein Metadaten-Abgleich
  spricht über Bücher — also in die Bibliothek.
- **Nichts wird ohne Namensliste verändert.** Beim Gerät heißt das ADR 0014;
  beim Online-Abgleich heißt es Feld für Feld mit alt und neu nebeneinander.

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
- **Welches Format wer liest, ist eine Tabelle, kein `if`.**
  `BookFileFormat.readerLayer` sagt `.core`, `.app` oder `.none`;
  `BookFileReader` im Kern verteilt die erste Gruppe, `FileReader` in der App die
  zweite. Ein Test prüft, dass `hasReadableMetadata` und `readerLayer` nicht
  auseinanderlaufen können. Ein neues Format ist zwei Zeilen dort und ein Reader.
- **Was im Index steht, muss aus dem Ordner wieder herleitbar sein** — sonst ist
  der Index keine Cache mehr (ADR 0001). Das DRM-Flag war es nicht, und der
  Rebuild hat neun Badges lautlos auf null gesetzt. Wer ein Feld zum Index
  hinzufügt, beantwortet zuerst: woher kommt das nach `Rebuild Index from
  Folders` wieder?
- **`ImportRunner` kennt nur Bücher, die er selbst angelegt hat.** Für ein Buch,
  das schon in der Bibliothek stand, muss ihm der Aufrufer den vorhandenen
  Eintrag geben (`existingEntry`) — sonst schreibt er einen frischen mit nur der
  neuen Datei darin, und der Index vergisst die anderen.

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
- **libarchive stürzt ab, wenn man ein Format zweimal registriert.**
  `archive_read_support_format_all` registriert rar und rar5 bereits; wer sie
  „sicherheitshalber“ noch einmal namentlich registriert, bekommt SIGSEGV in
  `rar5_cleanup` — die Fehlerbehandlung der zweiten Registrierung dereferenziert
  einen Null-Kontext. Die App starb an der ersten CBR-Datei überhaupt.
- **Eine Fixture, die mit sich selbst kollidiert, misst die Duplikatprüfung.**
  Dreimal in einem Lauf passiert: gleiche Heftnummern, byte-gleiche kaputte
  Dateien, gleicher Seed für den Comic-Inhalt. Jedes Mal sah der Lauf grün aus
  und die Zahl war zu klein. Jede generierte Datei trägt ihren Index jetzt in
  den Bytes.
- **`scroll-at.swift` scrollt bei *negativer* Klickzahl nach unten.** Steht in
  seinem eigenen Kopf; eine positive Zahl scrollt nach oben, und oben war das
  Panel schon — der Screenshot zeigte zweimal brav den Anfang des Inspectors.
- **Die beiden `contentsOfDirectory` widersprechen sich auf FAT.** Die
  Pfad-Form meldet einen Ordner namens `system` als `System`; die URL-Form,
  `readdir`, `ls` und `find` sagen `system`. Auf APFS sind sie sich einig, also
  war der Unit-Test grün und jeder Kindle und jeder PocketBook wurde nicht mehr
  erkannt, sobald der Beweislauf sie auf ein echtes FAT32-Volume legte.
- **APFS ist case-insensitiv, also ist `fileExists` keine Antwort auf „heißt da
  etwas so“.** `/System` und `/Applications` beantworten die Marker eines
  PocketBooks, und der erste Lauf von `shelf-tool devices` meldete brav
  „Macintosh HD → PocketBook“.
- **`screencapture -l <fenster-id>` fotografiert den Backing Store**, und der
  wird bei einer gescrollten SwiftUI-`ScrollView` nicht neu gezeichnet: der
  Seitenleisten-Screenshot zeigte dreimal hintereinander den Anfang der Liste,
  während der Bildschirm das Ende zeigte. `-R` mit dem Fensterrechteck
  fotografiert, was ein Mensch sieht.
- **Die Accessibility-API klemmt die Position einer ausgescrollten Zeile** auf
  den Rahmen der Scroll-Ansicht. Eine Prüfung „ist die Zeile im Fenster“ ist
  damit immer wahr. Der Scrollbalken-Wert ist die Frage, die wirklich zählt.
- **`screencapture -R` fotografiert den Bildschirm**, also auch den Tooltip des
  Dock-Symbols, über dem der Zeiger zufällig stehen blieb.
  `Scripts/cursor-park.swift` schiebt ihn vorher weg.
- **macOS stellt die Fenster wieder her, die eine *abgeschossene* App hatte.**
  Ein Skript, das die App ein Dutzend Mal mit `kill` beendet, hinterlässt einen
  Zustand, der sie alle zurückbringt: `make smoke` meldete zwölf echte Fenster
  auf dem Willkommensbildschirm, wo eins hingehört, und an der App war nichts
  falsch. Ein ordentliches `quit` setzte es zurück.
- **`hdiutil` legt unter etwa 40 MB kein FAT32 an** („Der Vorgang ist nicht
  zugelassen“ bei 6, 12, 16 und 32 MB). Eine fast volle Karte wird deshalb mit
  Ballast gefüllt, nicht klein gemacht.
- **macOS schreibt Akzente auf FAT32 zerlegt** (`Lefèvre` als `e` plus
  Gravis-Zeichen), die Bibliothek hält sie zusammengesetzt. Dass die Zuordnung
  trotzdem trägt, liegt an Swifts kanonischem String-Vergleich — ein
  Byte-Vergleich hätte jedes Buch mit Akzent im Autorennamen verloren, ohne dass
  irgendetwas fehlgeschlagen wäre.
- **Ein Check gegen den ganzen Accessibility-Baum beantwortet „steht das Wort
  irgendwo im Fenster“.** `tree_has "AZW3"` traf die Formats-Sektion der
  Seitenleiste, also war jede Zelle „richtig“, und das Bild zeigte einen Comic
  mit einem Format. Die Frage war „hat *dieses Buch* mehrere Dateien“ — die
  steht im Hilfetext der Zelle.

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
