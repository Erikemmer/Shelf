# Shelf – Konzept

*eBook-Manager für den Mac im Look & Feel von Selector. Arbeitstitel „Shelf“.*
*Stand: 16. September 2026. Autor: Erik Emmer. Dieses Dokument ist die Grundlage für die Umsetzung durch eine Claude-Code-Sitzung (Opus) mit einer zweiten Claude-Sitzung (Fable) als Reviewer – siehe `SHELF-BUILDER-PROMPT.md` und `SHELF-REVIEWER-PROMPT.md`.*

---

## 0. Ziel in einem Satz

Shelf verwaltet eine lokale Bibliothek von 1.000–10.000 eBooks (EPUB, MOBI/AZW3, PDF, CBZ/CBR) mit Metadaten, Regalen und Tags, übernimmt eine bestehende Calibre-Bibliothek verlustfrei, überträgt Bücher geprüft auf Kobo, Kindle, Tolino und PocketBook – und sieht dabei aus wie Selector, nicht wie Calibre.

## 1. Leitidee

Calibre kann alles und sieht so aus. Shelf macht in v1.0 bewusst weniger – Bibliothek, Metadaten, Geräte – und macht das mit der Ruhe und Geschwindigkeit, die Selector für Fotos hat: dunkle Oberfläche, drei Spalten, Tastatur zuerst, sofort sichtbare Cover, keine Wartedialoge. Die Dateien auf der Platte sind die Wahrheit; die Datenbank ist nur ein Index, der jederzeit neu gebaut werden kann. Nichts an einem Buch wird verändert, gelöscht oder überschrieben, solange der Nutzer es nicht ausdrücklich verlangt – dieselbe Regel wie bei Originalfotos in Selector.

**Was Shelf in v1.0 nicht ist:** kein Reader, kein Konverter, kein Content-Server, kein Plugin-System, kein News-Download, keine DRM-Behandlung (weder entfernen noch umgehen – DRM-geschützte Dateien werden angezeigt, als solche markiert und sonst in Ruhe gelassen).

## 2. Nutzer und Kernszenarien

Ein einzelner Nutzer mit einer großen, über Jahre gewachsenen Calibre-Bibliothek und mehreren Lesegeräten.

1. **Umzug.** Calibre-Ordner wählen → Shelf liest `metadata.db` und Ordnerstruktur, zeigt ein Zählprotokoll (Bücher, Formate, Tags, Serien, Bewertungen, eigene Spalten, Probleme) und kopiert alles in eine neue Shelf-Bibliothek. Calibre-Ordner bleibt byte-für-byte unverändert.
2. **Stöbern.** 8.000 Cover in einem Grid, das beim Scrollen nicht ruckelt; Filter über Sidebar (Regal, Tag, Autor, Serie, Format, gelesen/ungelesen, Bewertung), Volltextsuche über Titel/Autor/Serie/Tags/Beschreibung.
3. **Pflegen.** Buch auswählen → Inspector rechts zeigt Metadaten und Cover, alles direkt editierbar, mit Undo. „Fetch Metadata“ holt Vorschläge von Open Library und Google Books; der Nutzer sieht Alt/Neu nebeneinander und bestätigt pro Feld.
4. **Neu hinzufügen.** EPUB/MOBI/PDF/CBZ ins Fenster ziehen oder Ordner wählen → Metadaten aus der Datei, Duplikat-Erkennung (ISBN, Titel+Autor, Datei-Hash), Einsortieren in den Bibliotheksordner nach `Autor/Titel (id)/`.
5. **Aufs Gerät.** Kobo anstecken → erscheint in der Sidebar unter „Devices“ mit freiem Speicher und den Büchern darauf. Bücher aus der Bibliothek auf das Gerät ziehen → Kopie mit SHA-256-Prüfung, danach „Verified · n books“. Beim Kobo zusätzlich: Lesefortschritt und Regale vom Gerät lesen und in der Bibliothek anzeigen.

## 3. Design

### 3.1 Herkunft

Shelf übernimmt Selectors Erscheinungsbild vollständig: dunkles Schiefergrau, Akzentfarbe, Fenster mit drei Spalten, der schmale Inspector rechts, flache Sidebar links ohne Rahmen, Tastaturbedienung mit sichtbaren Kurzbefehlen, Overlays statt Dialoge. Damit das nicht nur ähnlich, sondern gleich ist, wird das UI aus Selector in ein gemeinsames Paket **SlateKit** herausgelöst (siehe §10 und Sprint 0).

### 3.2 Layout

```
┌──────────────┬────────────────────────────────────┬──────────────┐
│ LIBRARY      │  [Grid ▦ | Table ☰]   Search ⌕     │ INSPECTOR    │
│  All Books   │                                    │ ┌──────────┐ │
│  Unread      │   ▣  ▣  ▣  ▣  ▣  ▣  ▣  ▣          │ │  Cover   │ │
│  Recently    │                                    │ └──────────┘ │
│  Added       │   ▣  ▣  ▣  ▣  ▣  ▣  ▣  ▣          │ Title        │
│ SHELVES      │                                    │ Authors      │
│  ▸ Fiction   │   ▣  ▣  ▣  ▣  ▣  ▣  ▣  ▣          │ Series #     │
│  ▸ Work      │                                    │ Rating ★★★★☆ │
│ TAGS         │                                    │ Tags         │
│  scifi (312) │                                    │ Publisher    │
│  …           │                                    │ Published    │
│ AUTHORS      │                                    │ Language     │
│ SERIES       │                                    │ Identifiers  │
│ FORMATS      │                                    │ Formats      │
│ DEVICES      │                                    │ Description  │
│  ⏏ Kobo Clara│                                    │ [Fetch Meta] │
└──────────────┴────────────────────────────────────┴──────────────┘
  8.412 books · 214 shelves · Kobo Clara: 1,2 GB free          ⓘ ⌘?
```

- **Sidebar** (220 pt wie in Selector, keine festen Breiten in den Zeilen – Lehre aus Sprint 6a): Smart Collections (All, Unread, Recently Added, Not on any shelf, Missing cover, Duplicates), Regale (Shelves – hierarchisch, manuell befüllt), Tags, Autoren, Serien, Formate, Geräte. Zählwerte rechts.
- **Mitte:** Cover-Grid (Pendant zum Filmstrip/Grid in Selector; Cover-Größe per Slider/⌘±) oder Tabelle (sortierbar, Spalten wählbar: Titel, Autor, Serie, Bewertung, Tags, Format, Hinzugefügt, Gelesen, Größe). Mehrfachauswahl, Drag auf Regale und Geräte.
- **Inspector** rechts (280 pt): Cover, alle Felder editierbar, Undo/Redo, „Fetch Metadata…“, „Show in Finder“, Formatliste mit Größe und Aktion „Add Format…“.
- **Statusleiste:** Gesamtzahlen, Gerätestatus, Fortschritt von Hintergrundaufgaben (Index, Cover-Cache, Transfer) – genau wie der Warmer-Fortschritt in Selector.
- **Welcome-Screen** wie Selector: „Open Library…“, „Import from Calibre…“, „New Library…“, Zuletzt geöffnet.

### 3.3 Tastatur

| Taste | Wirkung |
|---|---|
| ←→↑↓ | Auswahl im Grid |
| ␣ | Quick Look des Covers / der ersten Seite |
| ⏎ | Buch mit Standard-App öffnen (Apple Books, Preview …) |
| 1–5, 0 | Bewertung |
| R | gelesen/ungelesen umschalten |
| T | Tag-Feld im Inspector fokussieren |
| ⌘F | Suche |
| ⌘I | Inspector ein/aus |
| ⇧⌘I | Add Books… (nachgetragen in Sprint 7: ⌘I gehört laut dieser Tabelle dem Inspector, und ⌥⌘I war doppelt vergeben) |
| ⌘A | Select All Books (nachgetragen in Sprint 7: war in den Menüs und in keiner Übersicht) |
| ⇧⌘W | Close Library (ebenso) |
| ⌘1 / ⌘2 | Cover-Raster / Tabelle |
| ⌘+ / ⌘− | Cover größer / kleiner |
| ↖ / ↘ | erstes / letztes Buch |
| ⌘E | Fetch Metadata |
| ⌘⇧S | Send to Device (Auswahl auf gewähltes Gerät) |
| ⌘⌥I | Import from Calibre… |
| ⌘O | Open Library… |
| ⌘Z / ⇧⌘Z | Undo / Redo |
| ⌘? | Shortcut-Übersicht |

### 3.4 Sprache

UI zuerst Englisch, Deutsch in Sprint 7 (wie Selector). Bezeichner Englisch.

## 4. Funktionsumfang v1.0 (MoSCoW)

**Must**

- Bibliothek öffnen/anlegen, Ordner ist die Wahrheit, SQLite-Index rebuildbar
- Import von Dateien und Ordnern (EPUB, MOBI, AZW3, PDF, CBZ, CBR) mit Metadaten aus der Datei, Cover-Extraktion, Duplikatprüfung
- Calibre-Import (metadata.db + Ordner) mit Zählprotokoll vorab und Bericht danach; Originalordner unverändert
- Cover-Grid und Tabelle, flüssig bei 10.000 Büchern (Cover-Cache auf Platte, progressive Ladepipeline aus Selector)
- Sidebar mit Smart Collections, Regalen, Tags, Autoren, Serien, Formaten
- Suche (Titel, Autor, Serie, Tags, Beschreibung, ISBN)
- Inspector mit Metadaten-Editor, Undo/Redo, Bewertung, Gelesen-Status, mehreren Formaten je Buch
- Online-Metadaten (Open Library, Google Books) mit Alt/Neu-Vergleich und Bestätigung
- Geräte: Erkennen von Kobo, Kindle (USB), Tolino, PocketBook; Bücher übertragen mit SHA-256-Prüfung; Bücher auf dem Gerät anzeigen; Löschen auf dem Gerät nur nach Bestätigung mit Namensliste
- Kobo: Lesefortschritt und Regale vom Gerät lesen (nur lesen)
- Kompatible Metadaten-Dateien (`metadata.opf` je Buch, Calibre-Schema) – ein Rückweg nach Calibre bleibt offen
- Undo für alle Metadaten-Änderungen; nichts Irreversibles ohne Dialog
- **Schreibweisen zusammenführen.** Autor, Serie, Verlag und Tag lassen sich
  umbenennen und mehrere zu einer Zielschreibweise zusammenführen. Wirkung auf
  jedes betroffene Buch: `metadata.opf` neu geschrieben, Index nachgezogen,
  `AuthorSort` / `TitleSort` neu berechnet – als *ein* Undo-Schritt, mit
  Bericht. Shelf schlägt nichts vor und wählt nichts aus: welche drei
  Schreibweisen dieselbe Person sind, entscheidet der Nutzer (ADR 0018)
- **„Organize Library…“** – der Befehl, der die Ordner an die Metadaten
  angleicht. Erst eine Vorschau (alt → neu, wie viele schon richtig liegen,
  jede Kollision, alles Unberührbare), dann auf Knopfdruck das Bewegen nach den
  Regeln des Imports: Hash vorher und nachher, Manifest, Wiederaufnahme nach
  Abbruch, kein Rest, Rückweg über das Manifest (ADR 0002, ADR 0018).
  **Ordner werden bewegt, Buchdateien nie verändert.** Ein Schalter in den
  Einstellungen zieht die Ordner nach einer Metadatenänderung automatisch nach;
  er ist standardmäßig **aus**, weil Pfade in Skripten und Hardlink-Backups
  stehen können
- **Export einer Auswahl oder der ganzen Bibliothek als Ordner** (Kopie), mit
  wählbaren Formaten, Struktur (`Autor/Titel/` oder flach), Namensmuster und je
  einem Schalter für `cover.jpg` und `metadata.opf`. Drei Voreinstellungen:
  **Archiv** (alles, wieder importierbar), **Nur die Bücher** (reine Dateien,
  mit sichtbarem Hinweis, was dabei zurückbleibt) und **Für Calibre** (wie Archiv,
  zusätzlich Regale und Gelesen-Status als Calibre-Tags, weil Calibre eine
  unbekannte `<meta>` ignoriert). Zählprotokoll vorher, Bericht nachher; ein
  zweiter Lauf schreibt nur die Unterschiede und liest nie zurück (ADR 0019)
- **„Write into the Book File" / „Ins Buch schreiben"** – auf ausdrückliche
  Anweisung, nie beiläufig: Titel, Autoren, Verlag, Datum, Sprache und
  Beschreibung werden in die EPUB-Datei selbst geschrieben. Erst eine
  Bestätigung, die jedes Buch beim Namen nennt und jedes Feld alt → neu, dann
  – nach Vorprüfung (EPUB? DRM-frei? beschreibbarer Datenträger?) – die neue
  Datei geprüft und erst dann getauscht, das Original in den Papierkorb. Kein
  ⌘Z; der Papierkorb ist der Rückweg. Nur EPUB; PDF, MOBI und AZW3 bleiben
  unangetastet (ADR 0021, Sprint 10 Schritt E1/E2)

**Should**

- Quick Look (Cover, erste Seite)
- Serien-Ansicht (Bücher einer Serie geordnet nach Index, fehlende Bände sichtbar)
- Eigene Calibre-Spalten (Text, Ja/Nein, Datum, Zahl) importieren und anzeigen, in v1.0 nur lesend
- Zuletzt geöffnete Bibliotheken, mehrere Bibliotheken umschaltbar

**Could**

- Send-to-Kindle per E-Mail (SMTP-Konto in Schlüsselbund)
- Regel-basierte Regale (gespeicherte Suchen)
- Cover aus dem Netz nachladen, wenn die Datei keines hat

**Won't (v1.0) – vorgemerkt**

- Format-Konvertierung (v1.x über installiertes Calibre `ebook-convert` als Hilfsprogramm, erkannt und aufgerufen, nie mitgeliefert; eigene Engine nicht geplant)
- Integrierter Reader (v2: EPUB via WebKit, PDF via PDFKit, Comics wie Selector-Viewer)
- Lesefortschritt aufs Gerät schreiben
- iPad, App Store

**Was seit Sprint 10 kein Nicht-Ziel mehr ist.** Hier stand: „Metadaten in
die Buchdatei einbetten (v1.0 schreibt nur `metadata.opf` und Index; die
Buchdatei bleibt unverändert)." Das galt bis Schritt E2 dieses Sprints.
Gefallen ist es kontrolliert, auf ausdrückliche Anweisung und nie beiläufig
– siehe den neuen Punkt oben unter **Must** und ADR 0021. Weiterhin wahr:
kein Format außer EPUB wird je geschrieben, und ohne diese eine Anweisung
ändert sich an einer Buchdatei nichts.

## 5. Datenmodell

### 5.1 Bibliotheksordner

```
My Library/
  .shelf/
    library.sqlite          Index (jederzeit aus den Ordnern neu baubar)
    covers/                 Cover-Cache (Schlüssel: Buch-UUID + Größe)
    library.json            Name, Schema-Version, benannte Regale, Einstellungen
  Austen, Jane/
    Pride and Prejudice (17)/
      Pride and Prejudice - Jane Austen.epub
      Pride and Prejudice - Jane Austen.azw3
      cover.jpg
      metadata.opf
```

Die Ordnerstruktur ist Calibre-kompatibel (`Autor/Titel (id)/`), damit ein Calibre-Import 1:1 übernehmen kann und ein Rückweg bleibt. `metadata.opf` folgt dem Calibre-OPF-Schema (Dublin Core + `calibre:`-Metas: `series`, `series_index`, `rating`, `timestamp`, `user_metadata` für eigene Spalten). Shelf-eigene Felder (Gelesen-Status, Regalzugehörigkeit, Gerätezuordnung) stehen in `<meta name="shelf:…">`; Calibre ignoriert sie stillschweigend.

**Regel:** Ein Schreibvorgang auf `metadata.opf` schreibt in eine `.opf.part`-Datei und benennt atomar um (wie `.ingest-*.part` bei Selector). Die Buchdatei selbst wird nie *beiläufig* geschrieben – bis Sprint 10 stand hier „Die Buchdatei selbst wird in v1.0 nie geschrieben", ohne Einschränkung; seit Schritt E2 kann sie es, aber ausschließlich über „Write into the Book File", mit eigener Vorprüfung, eigener Bestätigung und eigenem Rückweg über den Papierkorb (ADR 0021, §4 oben). Jeder andere Schreibvorgang in Shelf – eine Bewertung, ein Tag, eine Verschiebung – geht weiterhin ausschließlich nach `metadata.opf` und in den Index.

**Namenskollisionen und Groß-/Kleinschreibung.** Der Soll-Pfad eines Buchs wird
aus seinen Metadaten gebildet (`AutorSort/Titel (Nummer)/`), und zwei Bücher
können denselben ergeben: derselbe Autor, derselbe Titel. Die laufende Nummer
in der Titelkomponente hält sie auseinander – sie ist Teil des Namens und nicht
Schmuck, und genau deshalb steht sie dort. Bleiben zwei Pfade trotzdem gleich,
ist das eine **Kollision**, und eine Kollision wird angezeigt und nicht gelöst:
Shelf bewegt beide Ordner nicht und nennt sie in der Vorschau beim Namen. Nichts
wird überschrieben, nichts zusammengelegt (ADR 0002, Entscheidung 4).

Auf dem Mac kommt ein zweiter Fall dazu, den kein anderes Betriebssystem
kennt. **APFS ist standardmäßig case-insensitive, aber case-preserving:**
`Fitzek` und `fitzek` sind derselbe Ordner, und ein `moveItem` von einem auf
den anderen ist kein Umbenennen, sondern ein Schreiben in sich selbst – auf
manchen Volumes ein Fehler, auf anderen ein Datenverlust. Deshalb gilt:

- **Vergleiche über Pfade falten die Groß-/Kleinschreibung**, wo das Dateisystem
  es tut. Ob es das tut, wird **am Volume selbst gemessen** und nicht geraten:
  eine Datei anlegen und unter der anders geschriebenen Form suchen. Ein
  externes, case-sensitives Volume mit derselben Bibliothek verhält sich
  anders als die interne Platte, und was für beide gelten soll, muss beides
  fragen.
- **Ein Zug, der sich nur in der Groß-/Kleinschreibung unterscheidet**, ist auf
  einem case-insensitiven Volume kein Zug zwischen zwei Ordnern, sondern eine
  Umbenennung desselben. Er läuft über einen eindeutigen Zwischennamen
  (`.shelf-move-<zufällig>`), weil ein direktes `moveItem` dort scheitert.
- **Zwei Bücher, deren Soll-Pfade sich nur in der Groß-/Kleinschreibung
  unterscheiden**, sind auf einem case-insensitiven Volume eine Kollision und
  werden als solche gemeldet – auf einem case-sensitiven Volume sind sie zwei
  Ordner und keine.

### 5.2 Index (SQLite)

Tabellen `books`, `authors`, `book_authors`, `series`, `tags`, `book_tags`, `shelves`, `book_shelves`, `formats`, `identifiers`, `custom_columns`, `custom_values`, `devices`, `device_books`. FTS5-Tabelle über Titel/Autor/Serie/Tags/Beschreibung. Zugriff über GRDB.swift (Swift-6-fähig, gut gewartet) – einzige externe Abhängigkeit im Core neben Foundation. Der Index wird beim Öffnen gegen die Ordner abgeglichen (mtime, Dateiliste); Abweichungen werden angezeigt („3 books changed on disk – Reindex“), nie still verworfen.

### 5.3 Identität

Jedes Buch hat eine UUID (aus Calibre übernommen, sonst neu), gespeichert in `metadata.opf` als `dc:identifier opf:scheme="uuid"`. Formate werden über SHA-256 der Datei identifiziert (Duplikate, Geräteabgleich).

## 6. Formate

| Format | Metadaten | Cover | Technik | Risiko |
|---|---|---|---|---|
| EPUB 2/3 | OPF im ZIP (Dublin Core, Serien aus `calibre:series` oder `belongs-to-collection`) | `cover-image`-Item oder erstes Bild | Foundation + ZIP-Reader (libarchive oder eigenes ZIP-Lesen) | gering |
| MOBI / AZW3 | PalmDB-Header, EXTH-Records (100 Autor, 503 Titel, 104 ISBN, 106 Datum, 201 Cover-Offset) | über EXTH 201 | eigener Parser in `ShelfCore/Formats/Mobi` nach öffentlichen Format-Beschreibungen (MobileRead-Wiki) | mittel – viele Varianten, KFX nicht lesbar (nur Dateiname/Größe) |
| PDF | PDFKit `documentAttributes` | Seite 1 gerendert | PDFKit (App-Schicht, da nicht Linux-fähig) | gering |
| CBZ | keine → Dateiname (`Serie 012 (2019).cbz` per Regex), optional `ComicInfo.xml` | erstes Bild alphabetisch | ZIP | gering |
| CBR | wie CBZ | wie CBZ | libarchive (in macOS enthalten, liest RAR) | mittel – RAR5 abhängig von libarchive-Version; sonst nur Dateiname |

DRM (Adobe ADEPT in EPUB via `META-INF/encryption.xml`, Kindle-DRM via EXTH 209) wird erkannt und als Badge angezeigt; Metadaten kommen dann aus dem Dateinamen bzw. den unverschlüsselten Teilen.

## 7. Calibre-Import

1. Nutzer wählt den Calibre-Ordner (mit `metadata.db`).
2. `CalibreReader` (Core) öffnet `metadata.db` **schreibgeschützt über eine Kopie** in `~/Library/Caches/Shelf/`, liest `books`, `authors`, `books_authors_link`, `series`, `books_series_link`, `tags`, `books_tags_link`, `ratings`, `comments`, `identifiers`, `data` (Formate), `custom_columns` und die `custom_column_*`-Tabellen, `books_plugin_data` wird ignoriert.
3. Zählprotokoll vorab (wie Sort & Export / Ingest): n Bücher, n Formate je Typ, n Tags, n Serien, n Autoren, n eigene Spalten (mit Typ), n Dateien laut DB fehlend auf Platte, n Dateien auf Platte ohne DB-Eintrag, Gesamtgröße, freier Platz am Ziel (× 1,05).
4. Import = **Kopie** in eine neue Shelf-Bibliothek, SHA-256 während des Kopierens, Ziel zurückgelesen, Manifest für Resume – exakt das Muster von Selectors `IngestRunner`. Der Calibre-Ordner wird nie verändert; das Protokoll enthält am Ende „Calibre library untouched · n books verified“.
5. Bericht mit allem, was nicht sauber abgebildet werden konnte (unbekannte Spaltentypen, kaputte OPFs, fehlende Dateien), als `Import-Report.txt` in `.shelf/`.

Nicht in v1.0: Beide Programme parallel auf einem Ordner. Wer Calibre weiter nutzen will, importiert erneut (Resume überspringt Bekanntes über UUID + Hash).

## 8. Geräte

### 8.1 Erkennung

`NSWorkspace`-Volume-Benachrichtigungen; ein Volume ist ein Lesegerät, wenn ein Markerpfad existiert:

| Gerät | Marker | Bücherordner | Formate | Rücklesen |
|---|---|---|---|---|
| Kobo | `.kobo/KoboReader.sqlite` | Wurzel (beliebige Unterordner) | EPUB, KEPUB, PDF, CBZ | Fortschritt, Regale, Lesestatus aus `KoboReader.sqlite` (Kopie, read-only) |
| Kindle (USB) | `system/` + `documents/` | `documents/` | AZW3, MOBI, PDF (EPUB **nicht** – Hinweis anzeigen) | nur Dateiliste |
| Tolino | `.tolino/` oder Volume-Name „tolino“ | `Books/` | EPUB, PDF | nur Dateiliste |
| PocketBook | `system/` + `applications/` | `Books/` | EPUB, PDF, MOBI, CBZ, CBR | nur Dateiliste |

Geräteprofile sind Daten (JSON in `ShelfCore/Devices/Profiles/`), nicht Code, damit neue Modelle ohne Release nachgetragen werden können.

### 8.2 Übertragen

Drag auf das Gerät in der Sidebar oder ⌘⇧S. Vorab: passende Formate wählen (Präferenzreihenfolge je Gerät, z. B. Kindle: AZW3 > MOBI > PDF), fehlt eines → Buch in der Liste „cannot be sent: no compatible format“ (Konvertierung ist vorgemerkt, siehe §4). Freier Platz prüfen. Kopie mit SHA-256-Prüfung, Rückleseprüfung, Bericht „Verified · n books · Skipped: n · Failed: n“. Dateinamen auf dem Gerät `{author} - {title}.{ext}`, Sonderzeichen für FAT32 bereinigt.

### 8.3 Löschen auf dem Gerät

Nur über eigenen Menüpunkt mit Bestätigungsdialog, der jede Datei beim Namen nennt. Keine Löschung als Nebenwirkung eines Syncs. Die Bibliothek wird von Gerätelöschungen nie berührt.

### 8.4 Auswerfen

„Eject“ über `NSWorkspace.unmountAndEjectDevice`, nur wenn kein Transfer läuft.

## 9. Online-Metadaten

Quellen: Open Library (`/api/books`, `/search.json`) und Google Books (`/volumes?q=isbn:`), beide ohne API-Schlüssel.

> **Nachtrag aus Sprint 6 (18.09.2026):** `/api/books` antwortete auf jede
> geprüfte ISBN mit HTTP 404 und leerem Rumpf – auch auf ISBNs, deren Bücher die
> Open-Library-Suche findet. Shelf fragt Open Library deshalb für beide Fragen
> über `/search.json`; die Antwort hat dieselbe Form. Google Books antwortete am
> selben Tag auf alle zehn ISBNs mit HTTP 429 (gemeinsames Kontingent ohne
> Schlüssel). Begründung und Messwerte:
> [ADR 0015](adr/0015-online-metadata-two-sources-field-by-field.md). Suche nach ISBN, sonst Titel + Autor. Ergebnis als Kandidatenliste; gewählter Kandidat wird Feld für Feld gegen den Bestand gestellt (Alt | Neu, Checkbox je Feld, Cover-Vorschau). Übernahme schreibt `metadata.opf` und Index, mit Undo. Kein automatischer Massenabgleich in v1.0; Batch nur mit Bestätigung pro Buch. Netzwerkfehler sind still (Meldung in der Statusleiste), nie modal.

## 10. Architektur

```
Shelf/
  Package.swift
  Sources/
    ShelfCore/          UI-frei, Linux-baubar (CI): Modell, Index, Formate, Calibre-
                        Reader, Geräteprofile, Transfer-Planer, Import-Runner,
                        Namensmuster, Reports, reine Regeln
    SlateKit/           gemeinsames UI-Paket mit Selector (siehe Sprint 0):
                        Farben, Typografie, Sidebar, Inspector, Grid, Statusleiste,
                        Overlays, Shortcut-Hilfe, Welcome-Screen-Gerüst
  App/Shelf/            AppKit/SwiftUI-App: Fenster, Cover-Pipeline (aus Selector
                        übernommen: Loader-Koordinator, DecodeGate, Warmer,
                        InteractionWindow), PDFKit, NSWorkspace, Netz, Sandbox
  Tests/                Core-Tests mit synthetischen EPUB/MOBI/CBZ-Dateien,
                        Calibre-Fixture-Bibliothek (5 Bücher) im Repo
  Scripts/              smoke.sh, window-count.swift (aus Selector kopiert),
                        import-dry.swift
  docs/                 CONCEPT.md (dieses Dokument), ARCHITECTURE.md,
                        DATA-MODEL.md, BACKLOG.md, HANDOFF.md, adr/
  Programmier-Leitlinie.md   bindend, aus Selector kopiert
  CLAUDE.md             Prozessregeln aus Selector (smoke nach app, WIP-Commit vor
                        Bisektion, keine fremden Prozesse beenden, Locale-Lehre)
```

**SlateKit** liegt als eigenes Git-Repo (`Erikemmer/SlateKit`) vor und wird von beiden Apps als SPM-Abhängigkeit über Tag eingebunden – nicht als Pfad-Abhängigkeit, damit ein Umbau in Selector Shelf nicht bricht und umgekehrt. Änderungen an SlateKit: eigener Commit dort, Tag, dann Update der Abhängigkeit in der App.

Wiederverwendung aus Selector (kopieren, nicht koppeln, weil fachlich verschieden): `DecodeGate`, `LoadPriority`, `WarmOrder`, `InteractionWindow`, das Loader-Koordinator-Muster, `ContentHasher`/`SHA256Hasher`, das Runner-Muster mit `.part`-Dateien und Manifest, `IngestReport`-Wortlaut („verified“ / „NOT VERIFIED“), `smoke.sh`.

**Abweichung vom Selector-Verhalten, bewusst:** Das Warmen der Cover pausiert bei Auswahlwechsel, am Größen-Slider und beim Tippen in der Suche – beim Trackpad-Scrollen dagegen nicht. `onScrollPhaseChange` braucht macOS 15, Shelf zielt auf 14; der naheliegende Ersatz (Zellerscheinen als Scroll-Signal) war eine Rückkopplung und hat das Warmen um den Faktor 20 verlangsamt ([ADR 0005](adr/0005-cover-pipeline.md)). Ein Cover-Decode dauert hier ~3 ms statt Selectors ~600 ms für ein RAW, deshalb reicht die Hintergrund-Grenze des `DecodeGate` allein. Sobald das Deployment-Ziel auf macOS 15 steigt, kommt das Scrollen wieder dazu.

## 11. Sprints

**Sprint 0 – SlateKit (in Selector).** Farben, Typografie, Sidebar-Zeilen, Inspector-Gerüst, Grid-Zelle, Statusleiste, Overlay-Container, Shortcut-Fenster, Welcome-Gerüst aus Selector in ein eigenes Paket `SlateKit` verschieben; Selector baut, alle Tests grün, `make smoke` grün, Screenshot vor/nach identisch. Erst dann startet Shelf.

**Sprint 1 – Gerüst und EPUB.** Repo, Pakete, Makefile, smoke, CI (Core auf Linux). Bibliothek anlegen/öffnen, EPUB-Import mit Metadaten und Cover, Index, Cover-Grid mit Ladepipeline, Inspector nur lesend, Welcome-Screen. Messziel: 5.000 synthetische Bücher, Grid scrollt ohne Aussetzer, Öffnen < 2 s bei warmem Cover-Cache.

**Sprint 2 – Pflegen.** Metadaten-Editor mit Undo, Bewertung, Gelesen-Status, Tags, Regale (Drag), Serien, Suche mit FTS5, Tabelle, Smart Collections, Sortierung. `metadata.opf` schreiben (atomar).

**Sprint 3 – Calibre-Import.** `CalibreReader`, Zählprotokoll, Import-Runner mit Prüfung und Resume, Bericht, eigene Spalten lesend. Beweislauf gegen Eriks echte Calibre-Bibliothek: Zahlen vorher/nachher, Stichproben-Hashes, Originalordner unverändert (`find -newer`).

**Sprint 4 – Weitere Formate.** MOBI/AZW3-Parser, PDF, CBZ, CBR, DRM-Erkennung, mehrere Formate je Buch, Quick Look.

**Sprint 5 – Geräte.** Erkennung, Profile, Transfer mit Prüfung, Geräteinhalt anzeigen, Kobo-Rücklesen, Löschen mit Namensliste, Eject. Beweislauf mit jedem vorhandenen Gerät.

**Sprint 6 – Online-Metadaten.** Open Library, Google Books, Vergleichsansicht, Cover-Nachladen.

**Sprint 7 – Polish & Release.** Deutsch, Barrierefreiheit, Shortcut-Übersicht, Signierung + Notarisierung, Direkt-Download, Runbook.

**Sprint 8 – Ordnen und Export.** Der Sprint, der aus einer Lücke entstand, die beim Ausprobieren auffiel: Shelf konnte eine Sammlung bisher nur *im Fenster* ordnen. Steht derselbe Autor als „Sebastian Fitzek“, „Fitzek, Sebastian“ und „S. Fitzek“ in der Bibliothek, blieben das drei Autoren und drei Ordner. Umbenennen und Zusammenführen von Autoren, Serien, Verlagen und Tags; „Organize Library…“ mit Vorschau, Prüfsummen, Manifest und Rückweg; Export in vier Voreinstellungen, davon eine, die den Rückweg nach Calibre verlustfrei macht. Beweislauf gegen 5.000 Bücher, darunter der wichtigste des Sprints: ein Archiv-Export wird in eine leere Bibliothek importiert und beide werden verglichen → **v1.0**.

**Danach (Wünsche):** Konvertierung über `ebook-convert`, Reader, Send-to-Kindle, Fortschritt schreiben, regelbasierte Regale, iPad. Dazu ein lokales Modell oder eine Schnittstelle zu einem Dienst wie Claude, das Schreibweisen, Dubletten und Cover *vorschlägt*: die Vorschläge füllen dieselbe Vorschau-Liste, die der Nutzer heute von Hand füllt und bestätigt, und gehen nie selbst an Dateien. Die Grenze ist die Stelle, an der Sprint 8 sie gezogen hat – ein Vorschlag ist ein Vorschlag, und bestätigt wird von einem Menschen.

## 12. Nicht-Ziele

Kein Nachbau der Calibre-Oberfläche. Keine Plugins. Kein Server, keine Web-Oberfläche. Keine Cloud-Synchronisation der Bibliothek in v1.0 (iCloud-Drive-Bibliotheken werden erkannt und mit Warnung geöffnet; SQLite in iCloud ist ein bekanntes Problem). Kein Umgehen von DRM, in keiner Form.

**Was seit Sprint 8 kein Nicht-Ziel mehr ist.** „Die Ordner in Ruhe lassen“ stand hier nicht als Satz, aber es war die Haltung: ADR 0007 hielt fest, dass eine Metadatenänderung den Ordner nicht umbenennt, und daraus wurde gelesen, Shelf rühre Ordner überhaupt nicht an. Das gilt so nicht mehr. ADR 0018 trennt die beiden Dinge: **beiläufig** wird nie umbenannt, **auf ausdrückliche Anweisung, mit Vorschau und Rückweg** schon. Ordner werden bewegt, Inhalte nicht. Und nichts wird endgültig gelöscht – was weggehen soll, geht in den Papierkorb.

**Was seit Sprint 10 kein Nicht-Ziel mehr ist.** Hier stand bis dahin, ohne Einschränkung: „eine Buchdatei wird nie geschrieben, nie überschrieben, nie gelöscht." Das war bis Schritt E2 dieses Sprints wahr und ist es beiläufig immer noch – gefallen ist es genau einmal, mit Datum (21. September 2026) und Begründung, nicht stillschweigend. ADR 0021 erlaubt **auf ausdrückliche Anweisung, mit Vorprüfung, Vorschau und Rückweg über den Papierkorb**, Metadaten und ein Cover in eine EPUB-Datei zu schreiben – „Write into the Book File", nirgends sonst erreichbar. Weiterhin nicht verhandelbar: kein anderes Format wird je geschrieben, eine Buchdatei wird nie *überschrieben* (immer neu geschrieben, geprüft, dann getauscht), nie ohne diese eine Bestätigung, und nie gelöscht – das Original geht in den Papierkorb, mit ausdrücklich keinem ⌘Z, weil der Papierkorb selbst der Rückweg ist.

## 13. Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| MOBI/AZW3-Varianten und KFX | Parser gegen Fixture-Sammlung testen; KFX nur als Datei führen; Fehler pro Datei sammeln, nie den Import abbrechen |
| CBR ohne RAR5-Unterstützung | libarchive-Version zur Laufzeit prüfen; Fallback Dateiname; klar im Inspector anzeigen |
| Calibre-Schema-Änderungen | Reader gegen Schema-Version in `metadata.db` (`library_id`, `user_version`) prüfen; unbekannte Version = Warnung, nicht Abbruch |
| Große Bibliothek, Grid ruckelt | Ladepipeline aus Selector 6a, Cover-Cache auf Platte ab Sprint 1 (nicht wie bei Selector nachgereicht); der Cache schreibt **JPEG**, nicht HEIC: gemessen 1,05 ms gegen 38,4 ms je Cover, weil HEIC pro Bild eine HEVC-Sitzung über den Hardware-Encoder aufsetzt – 19,9 KB statt 8,2 KB je Bild ist der Preis dafür ([ADR 0005](adr/0005-cover-pipeline.md)) |
| Geräte-Marker treffen nicht | Profile als Daten; „Treat this volume as device…“ als manueller Weg |
| FAT32-Dateinamen, 4-GB-Grenze | Bereinigungsregel in Core mit Tests; Größenprüfung vor Kopie |
| SQLite-Sperren bei Absturz | WAL-Modus, Index ist rebuildbar, Ordner bleibt Wahrheit |
| Sandbox-Zugriff auf Volumes | Security-scoped Bookmarks je Bibliothek und Gerät; Zugriff nur über Auswahl-Dialog |

## 14. Qualitätsregeln

Es gilt `Programmier-Leitlinie.md`. Zusätzlich die in Selector erarbeiteten Prozessregeln (in `CLAUDE.md`): `make test && make app && make lint && make smoke` vor jedem Commit; ein Commit pro Anliegen, Conventional Commits; WIP-Commit vor jeder Fehlersuche per Bisektion; nie einen Prozess beenden, den die Sitzung nicht gestartet hat; Messwerte in den CHANGELOG; jeder Beweislauf mit echten Daten dokumentiert Zahlen vorher/nachher und „Quelle unverändert“; alles, was nicht selbst geprüft werden konnte, wird beim Namen genannt. Core bleibt Linux-baubar.

## 15. Offene Entscheidungen (bewusst offen gelassen)

1. Bundle-ID-Präfix und Namensraum ohne Firmenbezug – Vorschlag `de.erikemmer`.
2. ZIP-Lesen: libarchive (System, auch für RAR) oder eigene ZIP-Implementierung im Core (Linux-CI-fähig)? Vorschlag: eigener minimaler ZIP-Reader im Core für EPUB/CBZ (testbar auf Linux), libarchive nur für CBR in der App-Schicht.
3. Regale hierarchisch (Ordner in Ordnern) oder flach mit Präfix? Vorschlag: hierarchisch, weil die Sidebar es ohnehin kann.

Punkt 1 entschieden: `de.erikemmer`, keine Migration alter Defaults nötig, weil die ID von Anfang an stimmt.
