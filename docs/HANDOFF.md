# Handoff – where Shelf stands, and what is left

**Next step: release v1.0.** What is open is what Erik has to contribute.

Sprints 1–8 are done. `main` is green, **675 core tests**, the version in
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

Four things, in the order they block something.

### 1. A Developer ID certificate, and a notarytool profile

Until these exist, **nothing has ever been notarised**, and a Shelf copied to
another Mac says it is damaged and should be moved to the Trash — which is not a
warning about signing, it is what an unsigned app looks like to somebody who did
not build it.

Both are Erik's to make, both cost a yearly Apple Developer Program membership,
and `docs/RELEASE.md` says exactly how, step by step. No script here creates
either, and neither is ever written into a file in this repository. When they
exist, `make release` runs the whole path and steps 6 and 7 stop being skipped.

### 2. GitHub Actions has not run since Sprint 4

Every job ends after seven seconds with

> The job was not started because recent account payments have failed or your
> spending limit needs to be increased.

Checked again on 19 September 2026 on three separate pushes. Nothing in this
repository can fix it. It has already cost something once: the Linux build was
broken from Sprint 5 to Sprint 7 (`import Darwin` in `shelf-tool`) and the
Linux job is what exists to catch that.

Until it is sorted, the substitute is a container on this Mac, and it is run
before each release-shaped commit:

```bash
CHECK=~/Library/Caches/Shelf/linux-check-7b
rm -rf "$CHECK" && mkdir -p "$CHECK" && git archive HEAD | tar -x -C "$CHECK"
docker run --rm -v "$CHECK:/src" -w /src swift:6.1 bash -c \
  "apt-get update -qq && apt-get install -y -qq libsqlite3-dev && swift build && swift test"
```

A `git archive` rather than the repository itself, because `Package.resolved`
lives beside the repo and the container cannot read it — and because it then
checks exactly what is committed. Measured 19 September 2026 on `4e53102`:
build 36.0 s, **631 tests green on Linux**. **Sprint 8's 44 new tests have not
been run on Linux**, because Docker was not started for this session — the core
compiles without AppKit, ImageIO or PDFKit as always, and nothing in
`ShelfCore/Organize/`, `ShelfCore/Export/` or `SidecarMetadata` imports
anything but Foundation, but that is an argument and not a run.

### 3. SlateKit is private, and the CI cannot see it

The core does not need it and its tests guard every push; the **app** does, and
GitHub Actions cannot reach a private repository without credentials. The job
skips the app build with a visible warning rather than going red. Two ways out,
and the choice is Erik's:

1. A `SLATEKIT_TOKEN` secret in the Shelf repo — a fine-grained token with read
   access to `Erikemmer/SlateKit`. The job picks it up automatically. Nothing
   becomes public.
2. Make SlateKit public. The package holds only appearance and layout, no
   subject matter — but making it public is a publication, and a session does
   not do that on its own.

### 4. The things only real hardware and real books can answer

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
- **Google Books answering.** Its shared anonymous quota has returned HTTP 429
  to every request this project has ever made, so no lookup here has had both
  services answering at once and the two-row disagreement case has never been
  photographed. A key would fix it and would be a secret in a shipped app.
- **The welcome screen's logo.** It still shows SlateKit's placeholder rather
  than the app icon. That was never asked for and is a question, not a
  slip.

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
**Stand: v1.0 ist freigabebereit**, `main` grün, 675 Kern-Tests, SlateKit-Pin
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

## Was in `~/Library/Caches/Shelf/` von der Sitzung vom 19.09.2026 (Sprint 8) stammt

Angelegt und benannt, wie CLAUDE.md es verlangt — **alles andere dort wurde
nicht angefasst**:

Geblieben ist nur, was noch gebraucht wird:

- `measure-library-8/shots/` (7,2 MB) – die 16-Bücher-Bibliothek, gegen die die
  Sprint-8-Screenshots aufgenommen wurden. `make organize-library` legt sie in
  Sekunden neu an; sie bleibt, weil sie winzig ist und weil die Bilder gegen
  genau diese aufgenommen wurden

Wieder entfernt, weil jedes davon mit einem Befehl neu entsteht:

- `synthetic/` (5,8 GB) – die 5 000 Bücher des Abschlusslaufs
  (`make synthetic`, 3 min, dann `make proof`)
- `measure-library-8/b-check/` (16 MB), `c-check/` (40 MB), `export/` (86 MB),
  `window/` (13 MB) – Arbeitsbibliotheken dieser Sitzung, jede aus
  `shelf-tool synthesise` + `import` in unter einer Minute wieder da

`release/` (146 MB) und `measure-library-7b/` (751 MB) stammen aus der
Vorsitzung und **wurden nicht angefasst**; `make accessibility` braucht das
zweite. Alles andere in `~/Library/Caches/Shelf/` ebenso.
