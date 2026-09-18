# Handoff – start prompt for a fresh session

Copy the block below into a new Claude Code session in `~/Documents/Shelf`.

---

## Prompt

Du arbeitest mit mir (Erik Emmer) an **Shelf**, einem Mac-only eBook-Manager im
Look & Feel von Selector. Repo: https://github.com/Erikemmer/Shelf (lokal
`~/Documents/Shelf`). Shelf ist ein modern aussehendes Calibre: Bibliothek,
Metadaten, Calibre-Import, Geräte – kein Reader, keine Konvertierung in v1.0.
Stand: Sprints 1–6 fertig, Sprint 7 **angefangen** (Deutsch und der
Release-Weg stehen, Barrierefreiheit und Runbook nicht), `main` grün,
606 Kern-Tests, SlateKit-Pin 0.3.1.

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
- UI-Texte Englisch **und Deutsch**: jedes gezeichnete Wort geht durch `Loc`
  und steht in `App/Shelf/Resources/Localizable.xcstrings`, sonst wird ein Test
  rot (ADR 0016). Bezeichner Englisch, Kommentare erklären das *Warum*. Der frühere Firmenname kommt in diesem Projekt nirgends vor.

---

## Nächster Schritt: Sprint 7 zu Ende bringen → v1.0

**Sprint 7 ist angefangen, nicht fertig.** Drei Dinge sind erledigt und
gepusht; vier stehen aus. Was steht, steht vollständig — es gibt keinen
halbdeutschen Zustand und keinen halben Release-Weg.

### Fertig

1. **Deutsch, vollständig.** `App/Shelf/Resources/Localizable.xcstrings`, 429
   Einträge, Englisch und Deutsch, acht mit Pluralformen. Jedes gezeichnete Wort
   geht durch `Loc` (`App/Shelf/Views/Strings.swift`); Zahlen, Daten und Größen
   über `FormatStyle`; fünf Tests, darunter einer, der **jeden** Satz in
   `App/Shelf` ablehnt, der nicht durch den Katalog geht
   ([ADR 0016](adr/0016-the-core-answers-in-english-the-window-translates.md)).
   Bilder und was das Ansehen gefunden hat: `docs/screenshots/sprint-7/README.md`.
2. **`make release`** – archivieren, signieren, notarisieren, stapeln, prüfen
   ([docs/RELEASE.md](RELEASE.md)). `make release-dry` beweist den Weg bis zur
   Notarisierung mit Ad-hoc-Signatur; **notarisiert wurde noch nie etwas**,
   weil kein Developer-ID-Zertifikat auf diesem Mac liegt.
3. **Die zwei Befunde aus dem Sprint-6-Screenshot**: „Unbekannt" war
   Fixture-Text, und `Book.authorLine` zeigt bei fehlendem Autor jetzt nichts;
   jede Zeile des Vergleichsdialogs nennt ihren Dienst, und wo die beiden
   Dienste sich widersprechen, sind es zwei Zeilen mit je einem Kästchen.

### Offen, in dieser Reihenfolge

1. **Barrierefreiheit.** Nichts davon ist angefasst worden. Die zwei bekannten
   Löcher stehen unter „Housekeeping": Seitenleisten-Zeilen haben keine Rolle,
   die eine Tastatur aktivieren kann (`AXImage` + zwei `AXStaticText`, kein
   `AXButton`), und die Pfeiltasten hängen an der Menüleiste (31 % der Zeit in
   `NSMENU_IS_THROTTLING_…`). Dazu fehlen: VoiceOver-Beschriftungen für Raster,
   Seitenleiste, Inspector, Tabelle und **alle Blätter**, eine sinnvolle
   Vorlesereihenfolge, ein Kontrast-Skript gegen WCAG AA über die
   Paletten-Werte, sichtbare Fokusringe, und ein AX-Baum je Ansicht als Beleg.
   `Scripts/ax-dump.swift` gibt es schon.
2. **Die Kürzel-Übersicht und die Menüs lesen *nicht* dieselbe Tabelle.**
   `ShortcutReference` speist den Willkommens-Einzeiler und das ⌘?-Blatt; die
   Menüleiste in `ShelfApp.swift` deklariert ihre Kürzel von Hand. Die beiden
   *können* auseinanderlaufen. Ein Test, der die Tabelle gegen die
   `.keyboardShortcut(…)`-Deklarationen in `ShelfApp.swift` hält, wäre der
   billige Weg; die Menüs aus der Tabelle zu bauen der gründliche.
3. **`docs/RUNBOOK.md` fehlt ganz.** Sichern und Wiederherstellen, Index neu
   bauen, Umzug auf eine andere Platte, Rückweg nach Calibre, Absturz mitten im
   Import oder Transfer, wo die Logs liegen — jeder Weg einmal ausgeführt und
   die Ausgabe zitiert.
4. **Die Liste aus `docs/BACKLOG.md`**, die v1.0 nicht mitschleppen soll: der
   Klick aufs Cover und das Suchfeld, „Missing Cover" nach frischem Import,
   „Published" über einer Auswahl, das nackte „Undo" nach einer
   Online-Übernahme, Sortierung nach Tags/Format/Gelesen/Größe, und
   `ZipWriter`/`MinimalPNG`/`SyntheticCalibreLibrary` in ein eigenes
   `ShelfFixtures`-Target.
5. **Abschlusslauf**: `make proof` vollständig gegen 5 000 Bücher, Kalt- und
   Warmstart, Speicher, eine Stunde offen für Lecks, `make release-dry`,
   CHANGELOG mit allen Zahlen, Version auf 1.0.0 in `project.yml`. **Tag
   `v1.0.0` erst, wenn Erik es sagt.**

### Was aus diesem Sprint mitzunehmen ist

- **Ein Satz, den SwiftUI nicht übersetzt, sieht aus wie einer, den es
  übersetzt.** `Text("eins " + "zwei")` ist ein `String` und wird wörtlich
  gezeichnet; ein interpolierter Schlüssel wird vom Compiler aus den *Typen*
  gebaut (`%1$lld of %2$lld`) und ist deshalb für keinen Test lesbar. Beides
  ist der Grund, warum **alles** durch `Loc` geht.
- **Der erste deutsche Lauf hatte eine englische Seitenleiste.**
  `SlateSidebarRow` nimmt den Titel als erstes Argument — auf keiner Liste von
  Aufrufformen. Der stumpfe Test („kein Satz in `App/Shelf` ohne `Loc`") hat
  sechs weitere Stellen gleich mitgefunden. **Ein Test, der nur prüft, was man
  ihm zeigt, prüft zu wenig.**
- **Ein Kernsatz mit einem Wert darin kann nicht übersetzt werden.** „„2,5x" ist
  keine Zahl" hat keinen Katalogschlüssel. Der Kern sagt jetzt *welche*
  Ablehnung, das Fenster sagt sie in Worten — `BookFieldRejection`,
  `ShelfEdit.Rejection`, `SeriesPosition.Place`.
- **Berichte bleiben Englisch, mit Grund.** `Scripts/proof-run.sh` liest sie
  mit `grep`, vier Screenshot-Skripte warten auf das Wort „Verified" im
  AX-Baum. `ByteCount.format` behält deshalb die C-Locale; das Fenster hat
  `Loc.size`.
- **Das ⌘?-Blatt öffnet sich nicht auf ein gepostetes „?" mit ⌘.** Es ist als
  ⌘/ deklariert und als ⌘? gezeichnet. Über den Menüpunkt geht es.
- **`tree_has "Bewegen"` findet „BEWEGEN" nicht.** Die Gruppen im ⌘?-Blatt
  werden in Großbuchstaben gezeichnet.
- **Die Sprache wird nie global umgestellt.** `Scripts/german-shots.sh`
  schreibt `AppleLanguages` in **Shelfs eigene** Defaults-Domain und nimmt sie
  in einem `trap` wieder heraus, auch wenn der Lauf scheitert.

### Was in `~/Library/Caches/Shelf/` von dieser Sitzung stammt

Angelegt und benannt, wie CLAUDE.md es verlangt — **alles andere dort wurde
nicht angefasst**:

- `measure-library-7/` – die Zwölf-Bücher-Bibliothek der deutschen Screenshots
- `linux-check-7/` – ein `git archive` von HEAD, in dem der Swift-Container
  gebaut hat (615 MB, kann weg)
- `release/` – das Ergebnis von `make release-dry`

## Was Erik ansehen muss: die CI läuft seit Sprint 4 überhaupt nicht

Unverändert am 18.09.2026, **dreimal an diesem Tag nachgeprüft** (Läufe
35381934435, 35386308364, 35386741392): jeder Lauf endet nach sieben Sekunden
mit

> The job was not started because recent account payments have failed or your
> spending limit needs to be increased.

Das ist keine Code-Sache und nichts in diesem Repository kann es beheben –
GitHub startet die Jobs nicht. **Vier Sprints ohne CI**, und sie hat sofort
etwas gekostet: der Linux-Build war seit Sprint 5 kaputt (`import Darwin` in
`shelf-tool`), und genau dafür gibt es den Linux-Job.

Bis das geklärt ist, ist der Ersatz ein Container auf diesem Mac:

```bash
docker run --rm -v "$PWD:/src" -w /src swift:6.1 bash -c \
  "apt-get update -qq && apt-get install -y -qq libsqlite3-dev && swift test"
```

Achtung: `Package.resolved` liegt neben dem Repo und der Container kann sie
nicht lesen (I/O-Fehler). Ein `git archive HEAD | tar -x -C <ordner>` und
*dieser* Ordner als Mount umgeht es und prüft obendrein genau das, was
committet ist. Gemessen am 18.09.2026: Build 36,9 s, **588 Tests grün**.

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
