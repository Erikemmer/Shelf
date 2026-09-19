# Handoff – where Shelf stands, and what is left

**v1.0 is ready to be released. What is open is what Erik has to contribute.**

Sprints 1–7 are done. `main` is green, 631 core tests on macOS and on Linux, the
version in `project.yml` is `1.0.0`, and `make release-dry` builds, signs and
zips it. The tag `v1.0.0` is **not** set and will not be set without Erik's word.

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
build 36.0 s, **631 tests green on Linux**.

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

`docs/BACKLOG.md` is the list, and three items have been sharpened rather than
fixed and are the obvious first three:

1. **A resumed transfer reports as failures the files it wrote itself.** The
   manifest is written every twenty files, so an *untidy* death — a crash, a
   power cut, a cable — can leave up to nineteen on the card that no manifest
   knows about, and the next run fails on each of them. Nothing is lost. The fix
   is in `TransferPlanner`.
2. **SwiftUI's Edit ▸ Undo never carries the action name**, whatever made the
   change. Measured both ways in Sprint 7. The fix is
   `CommandGroup(replacing: .undoRedo)` and it puts ⌘Z inside a text field on
   the line, which is why it was not done before a release.
3. **Editing publisher, language or date across a selection.** Deliberately left
   out in Sprint 2c; a publisher across a selection is a reasonable thing to
   want.

---

## Prompt for a fresh session

Copy the block below into a new Claude Code session in `~/Documents/Shelf`.

---

Du arbeitest mit mir (Erik Emmer) an **Shelf**, einem Mac-only eBook-Manager im
Look & Feel von Selector. Repo: https://github.com/Erikemmer/Shelf (lokal
`~/Documents/Shelf`). Shelf ist ein modern aussehendes Calibre: Bibliothek,
Metadaten, Calibre-Import, Geräte – kein Reader, keine Konvertierung in v1.0.
**Stand: v1.0 ist freigabebereit**, `main` grün, 631 Kern-Tests, SlateKit-Pin
`0.4.1`, Version `1.0.0` in `project.yml`, Tag `v1.0.0` **nicht** gesetzt.

**Lies zuerst, in dieser Reihenfolge:** `Programmier-Leitlinie.md` (bindend),
`CLAUDE.md`, diese Datei ganz oben („Was Erik tun muss“), `CHANGELOG.md` (oben
steht der letzte Stand), `docs/BACKLOG.md`, `docs/RUNBOOK.md`. Das Fachliche
steht vollständig in `docs/CONCEPT.md`, das Datenmodell in `docs/DATA-MODEL.md`,
die Entscheidungen in `docs/adr/` (0001–0017).

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

- `measure-library-7b/` – die 26-Bücher-Bibliothek der Barrierefreiheits-Belege,
  dazu eine synthetische Calibre-Bibliothek und vier Geräte-Images
- `runbook-7b/` – alles, was `make runbook` anlegt
- `linux-check-7b/` – ein `git archive` von HEAD für den Swift-Container
- `synthetic/` – die 5 000 Bücher des Abschlusslaufs (`make synthetic-clean`)
- `release/` – das Ergebnis von `make release-dry`

`linux-check-7/` der Vorsitzung (615 MB) wurde entfernt, weil die Vorsitzung es
ausdrücklich so vermerkt hatte.
