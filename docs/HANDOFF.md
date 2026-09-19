# Handoff – where Shelf stands, and what is left

**Next step: release v1.0.** What is open is what Erik has to contribute.

Sprints 1–8 are done. `main` is green, **679 core tests** on macOS *and* on
Linux, **CI is green on all three jobs** including the app build, the version in
`project.yml` is `1.0.0`, and `make release-dry` builds, signs and zips it. The
tag `v1.0.0` is **not** set and will not be set without Erik's word.

**Sprint 8 is why this file says 8 and not 7.** Trying the program found a hole
in the concept rather than a defect in the code: Shelf could order a collection
only inside its own window, and a library kept in it could not leave it. Both
are answered now — rename and merge, `Organize Library…`, and an export whose
archive re-imports as the same library. The numbers are at the top of
`CHANGELOG.md`; the decisions are
[ADR 0018](adr/0018-renaming-merging-and-organising-are-deliberate-operations.md)
and [ADR 0019](adr/0019-export-the-opf-decides-what-an-export-is.md).

---

## What Erik has to do, and nobody else can

**Two things.** Everything else that used to be on this list has been done.

### 1. A Developer ID certificate, and a notarytool profile

Until these exist, **nothing has ever been notarised**, and a Shelf copied to
another Mac says it is damaged and should be moved to the Trash — which is not a
warning about signing, it is what an unsigned app looks like to somebody who did
not build it.

Both are Erik's to make, both cost a yearly Apple Developer Program membership,
and `docs/RELEASE.md` says exactly how, step by step. No script here creates
either, and neither is ever written into a file in this repository. When they
exist, `make release` runs the whole path and steps 6 and 7 stop being skipped.

`make release-dry` proves everything up to that point, and is run before every
release-shaped commit.

### 2. The things only real hardware and real books can answer

All of these are in `docs/BACKLOG.md` with what each would settle:

- **A real e-reader on a cable.** Every device rule is measured against
  `hdiutil` disk images, which is enough for markers, format choice, names,
  verification, resume and the 4 GB limit — and cannot answer whether the
  sandbox lets Shelf list a *real* removable volume without an open panel. That
  is the first line of "To check on real hardware", because if it does not,
  auto-detection is decorative.
- **A real MOBI, AZW3, CBR and a genuinely DRM-protected file.** Everything is
  measured against generated ones, and no genuine `.cbr` has ever been read:
  nothing on this Mac can write a RAR.
- **Erik's real Calibre library.** Sprint 3 is measured against a synthetic one
  of 2 000 books. `~/Downloads/Calibre Library Erik` holds a `metadata.db` with
  no book folders, which exercises the schema and not the import. **Erik has to
  name the path.**
- **A real Calibre reading one of Shelf's exports.** The OPFs are quoted, the
  schema is Calibre's own, and the "For Calibre" mapping has a test — but
  running Calibre's importer over an export would mean writing into Erik's own
  Calibre library, which is not this project's to touch.
- **Google Books answering.** Its shared anonymous quota has returned HTTP 429
  to every request this project has ever made, so no lookup here has had both
  services answering at once and the two-row disagreement case has never been
  photographed. A key would fix it and would be a secret in a shipped app.
- **The welcome screen's logo.** It still shows SlateKit's placeholder rather
  than the app icon. That was never asked for and is a question, not a slip.

---

## What is no longer on that list

Three things were, until 19 September 2026, and all three are done:

- **GitHub Actions had not run since Sprint 4** — every job ended after seven
  seconds with "recent account payments have failed". Both repositories are
  **public** now, so there are no Actions minutes to pay for. CI runs on every
  push and all three jobs are green.
- **SlateKit was private, so the app build skipped itself.** It is public
  (`Erikemmer/SlateKit`), the `SLATEKIT_TOKEN` gate is gone from
  `.github/workflows/ci.yml`, and the job runs. **It had never once run**, from
  Sprint 1 to Sprint 8, and it found two real defects on its first day — see
  `CHANGELOG.md`.
- **Sprint 8's tests had not run on Linux.** They have: 679 green, in the
  container, against the commit they are quoted for.

---

## What a person still has to look at

Two of them, and both are listed at the foot of every run that cannot answer
them:

- **Whether the order VoiceOver reads things in makes sense.** `make
  accessibility` proves every control has a name and no name is an SF Symbol's;
  whether the sequence is the useful one is a judgement and needs an ear.
- **Whether the trackpad stays smooth while the cover cache fills.** A posted
  scroll-wheel event does not reach the table at all, so no script can answer
  it (`docs/BACKLOG.md`, "Measurements still to take by hand").

---

## If the next session is a v1.1

`docs/BACKLOG.md` is the list. The first of Sprint 7's three was fixed in
Sprint 8; the obvious first three now are:

1. **SwiftUI's Edit ▸ Undo never carries the action name**, whatever made the
   change. Measured both ways in Sprint 7. The fix is
   `CommandGroup(replacing: .undoRedo)` and it puts ⌘Z inside a text field on
   the line, which is why it was not done before a release.
2. **Editing publisher, language or date across a selection.** Deliberately left
   out in Sprint 2c; a publisher across a selection is a reasonable thing to
   want.
3. **A stored `authorSort` per author.** `AuthorSort` is a rule, and a rule gets
   some names wrong — a Dutch *van*, a Spanish double surname. Sprint 8 made
   renaming an author easy and left no way to correct how one *sorts*. It is a
   schema change, which is why it was not smuggled in.

---

## Prompt for a fresh session

Copy the block below into a new Claude Code session in `~/Documents/Shelf`.

---

Du arbeitest mit mir (Erik Emmer) an **Shelf**, einem Mac-only eBook-Manager im
Look & Feel von Selector. Repo: https://github.com/Erikemmer/Shelf (lokal
`~/Documents/Shelf`). Shelf ist ein modern aussehendes Calibre: Bibliothek,
Metadaten, Calibre-Import, Geräte – kein Reader, keine Konvertierung in v1.0.
**Stand: v1.0 ist freigabebereit**, `main` grün, 679 Kern-Tests (macOS und
Linux), CI grün auf allen drei Jobs, SlateKit-Pin
`0.4.1`, Version `1.0.0` in `project.yml`, Tag `v1.0.0` **nicht** gesetzt.
Sprint 8 (Umbenennen/Zusammenführen, „Organize Library…", Export) ist fertig;
oben in `CHANGELOG.md` stehen die Zahlen.

**Lies zuerst, in dieser Reihenfolge:** `Programmier-Leitlinie.md` (bindend),
`CLAUDE.md`, diese Datei ganz oben („Was Erik tun muss“), `CHANGELOG.md` (oben
steht der letzte Stand), `docs/BACKLOG.md`, `docs/RUNBOOK.md`. Das Fachliche
steht vollständig in `docs/CONCEPT.md`, das Datenmodell in `docs/DATA-MODEL.md`,
die Entscheidungen in `docs/adr/` (0001–0019).

**Rollen und Arbeitsweise**

- Du schreibst den Code, prüfst, committest und pushst selbst. Ich lese Berichte
  und entscheide bei echten Entscheidungen. Frag mich nur, wenn eine Entscheidung
  wirklich offen ist oder etwas Irreversibles anstünde; sonst entscheide selbst
  und schreib die Entscheidung in den Bericht.
- Vor jeder Änderung: Ziel in einem Satz, betroffene Dateien, Risiken. Kleine
  lauffähige Schritte. Zu jeder Änderung Tests und Doku. Am Ende jedes Berichts:
  Zusammenfassung in einfacher Sprache und ausdrücklich, was du nicht selbst
  prüfen konntest.
- **Prüfkette vor jedem Commit: `make test && make app && make lint &&
  make smoke`.** Alle vier grün, oder es wird nicht committet.
- **SlateKit nur im eigenen Arbeitsbaum** (`~/Documents/SlateKit-shelf`), nie in
  `~/Documents/SlateKit`. Der ganze Weg steht in `CLAUDE.md`.
- Nichts Irreversibles. Buchdateien werden nie geschrieben; Calibre nur gelesen;
  DRM nie angefasst; auf Geräten nur nach Bestätigung mit Namensliste gelöscht.
  Unter `~/Library/Caches/Shelf/` nur löschen, was diese Sitzung angelegt hat.
- **Den Tag `v1.0.0` setzt du nie ohne mein Wort.**

---

## Was in `~/Library/Caches/Shelf/` von der Sitzung vom 19.09.2026 stammt

Angelegt und benannt, wie CLAUDE.md es verlangt — **alles andere dort wurde
nicht angefasst**:

Geblieben ist nur, was noch gebraucht wird:

- `measure-library-8/shots/` (7,3 MB) – die 16-Bücher-Bibliothek, gegen die die
  Sprint-8-Screenshots in beiden Sprachen aufgenommen wurden.
  `make organize-library` legt sie in Sekunden neu an
- `release/` (153 MB) – das Ergebnis von `make release-dry`

Wieder entfernt, weil jedes davon mit einem Befehl neu entsteht:

- `synthetic/` (5,8 GB) – die 5 000 Bücher des Abschlusslaufs
  (`make synthetic`, 3 min, dann `make proof`)
- `linux-check-8/` (641 MB) – ein `git archive` von HEAD für den Container
- `measure-library-8/b-check|c-check|export|window/` – Arbeitsbibliotheken,
  jede aus `shelf-tool synthesise` + `import` in unter einer Minute wieder da

`measure-library-7b/` (751 MB) stammt aus der Vorsitzung und **wurde nicht
angefasst**; `make accessibility` braucht es. Alles andere dort ebenso.

**Docker** wurde von dieser Sitzung gestartet und von ihr wieder beendet.

**Im Papierkorb** liegen rund vierzig leere Autorenordner aus den
Wegwerf-Bibliotheken der Screenshot-Läufe. Sie sind absichtlich dort geblieben:
sie sind der Beleg, dass „Organize Library…" wirklich in den Papierkorb legt
und nicht löscht.
