# Handoff – where Shelf stands, and what is left

**`v1.1.0-rc1` is out, published for real, 23 September 2026 — Sparkle 2,
end to end.** Sprint 14 gave Shelf its own update mechanism: `Shelf ▸ Check
for Updates…`, a welcome-screen banner, and a second, separate public
repository, `Erikemmer/shelf-releases`, holding builds and two appcast
feeds (`appcast.xml` stable, `appcast-beta.xml` for `-rc` versions) — never
source, which stays exactly as public as it already was. Full reasoning:
[ADR 0022](adr/0022-updates-separate-delivery-sparkle.md). `MARKETING_VERSION`
is `1.1.0-rc1` now, not `1.0.0` — main had moved well past what the
`v1.0.0` tag names (below) before this sprint even started, and publishing
that work under the tag's own number would have meant two different apps
sharing one version string.

**Still no Developer ID, so `v1.1.0-rc1` shipped exactly the way `v1.0.0`
was handed out: ad hoc, unsigned, `spctl` rejects it and is expected to.**
The difference `make release` no longer refuses to run without a
certificate (Sprint 14, Teil B) — it signs ad hoc, names the download
`Shelf-1.1.0-rc1-unsigned.zip`, and publishes anyway. Both the update
mechanism's own client-side proof (a throwaway test channel, Teil C) and
the real thing (an older build finding and installing `v1.1.0-rc1` over
the real, now-live `appcast-beta.xml`, Teil D) were driven live, with real
clicks, and verified by reading the updated bundle's `Info.plist` back off
disk rather than trusting the window. `CHANGELOG.md`, Sprint 14, has all
four Teile plus the ADR.

**What is still open, past this sprint, is exactly what was open before
it** — a Developer ID certificate and a notarytool profile (below), the
four cover judgement calls, and what only real hardware and real books can
answer. Sparked nothing new onto that list: Shelf has no path for a
*Release*-configuration build to ever reach the beta channel — checked
directly, not assumed — but that is a real limit of Sparkle's own Debug-only
redirect design here, not a gap against some other app, so nothing was
added to `docs/BACKLOG.md` for it.

---

**Below is the previous handoff, kept as it was written — the tag it
describes and the "still open" list under it are both superseded by the
paragraphs above.**

---

**`v1.0.0` is tagged, on commit `4b5856c`.** Erik set it himself on 21
September 2026: `git tag -a v1.0.0 4b5856c -m "Shelf 1.0.0 — unsigned"`,
pushed. That commit is the closing session's v1.0 candidate — 701 core
tests, `main` green, the README's paragraph on opening an unsigned build,
the `CHANGELOG.md` `1.0.0` summary. The signature is missing on purpose;
it is planned as `v1.0.1`, once a Developer ID certificate exists (below).

**`main` has kept moving since the tag, into Sprint 10 — none of it inside
`v1.0.0`.** Opening the tag gets exactly what shipped; opening `main` gets
that plus whatever Sprint 10 has done. So far: `docs/adr/0021-…` (Shelf may
eventually write into an EPUB, on an explicit command that does not exist
yet) and a ZIP archive writer (`ZipArchiveWriter` / `EPUBArchiveWriter`)
proven by a strict round trip against archives this project builds itself —
including fixing a real bug the same day it was found, where the writer
decompressed every entry and stored it back, growing a real EPUB's text by
roughly 2.7×. `CHANGELOG.md` has the numbers. `CLAUDE.md` and
`docs/CONCEPT.md` are unchanged so far: the "never written" rule falls only
once the command that replaces it exists.

**Still open:**

1. **A Developer ID certificate and a notarytool profile.** Nothing has ever
   been notarised. `docs/RELEASE.md` says how; both are Erik's to make.
2. **The four judgement calls about covers**, listed below.
3. **Everything only real hardware and real books can answer**, listed below.

**The 907 ms question is closed, on a quiet disk.** Sprint 9's own
907–1 028 ms against Sprint 8's 738 ms was measured on a disk at 98–100 %
capacity, right after `make proof` itself had written and deleted several
gigabytes — exactly the condition APFS is known to slow down under.
Re-measured 22 September 2026 with 16–18 GiB free (53 % used, not 98–100 %):
**index read 986 ms, 774 ms, 811 ms** across three runs in a row against
the same 4 996-book synthetic library — two of three within 5–10 % of
Sprint 8's own number, none near Sprint 9's sustained 907–1 028 ms.
`CHANGELOG.md`, Sprint 11, Nachsitzung, Teil C, has the full numbers and
what is only assumed (the first run's own 986 ms, taken immediately after
`make proof`'s own heavy disk traffic, was not re-isolated from that).

---

**Below is the closing v1.0 session's own report, kept as it was written —
the tag it describes as not yet set is now `4b5856c`, see the top of this
file.**

Sprints 1–**9** are done. `main` is green, **701 core tests** on macOS *and* on
Linux, **CI is green on all three jobs** including the app build, the version in
`project.yml` is `1.0.0`, and `make release-dry` builds, signs and zips it —
run in full on 19 September 2026: ad-hoc, universal (x86_64 and arm64),
hardened runtime on, 13 MB app / 5.7 MB zip, notarise and staple skipped and
saying so. `make proof` ran the same day against the schema Sprint 9 changed:
4 996 books, 0 failures anywhere, and the `v3-cover-generation` migration's
cost against an already-populated index measured at ≈180 ms — the same range
as opening one that never needed it, because a constant-default `ADD COLUMN`
is metadata-only in SQLite. Numbers for both in `CHANGELOG.md`, including one
this session could not cleanly settle: opening now reads 907–1 028 ms against
Sprint 8's 738 ms, measured on a disk that was at 98–100 % capacity from the
proof run itself, which is reason enough on its own without Sprint 9's one
extra column — worth a re-measurement on a quiet disk before it is trusted
either way. The tag `v1.0.0` is **not** set and will not be set without
Erik's word.

**Sprint 9 is why this file says 9 and not 8.** Trying the program found the
most visible hole in the grid: a book's cover could not be changed. It can now,
four ways, all down one path — the old picture goes to the Trash, ⌘Z puts it
back, and the grid shows the new one at once, after a restart and after a
rebuild. The numbers are at the top of `CHANGELOG.md`; the one reversed
decision is
[ADR 0020](adr/0020-a-cover-may-be-replaced-and-what-guards-it-instead.md).

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

**Three things**, one of which is only a judgement. Everything else that used to
be on this list has been done.

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

### 2. Four things about covers that only you can judge

None of these is a defect. They are decisions that were made for you and are
cheap to reverse.

- **The size ceiling is 1 600 px on the long edge.** Reasoned from the
  pipeline's own numbers — 1.6 × the largest tier it ever decodes (ADR 0005) —
  and not from looking at covers on your screen. It is one constant in
  `CoverImageRule`. A 3 200 × 4 800 photograph comes down to 1 067 × 1 600 and
  46 KB; if that looks soft to you on a large display, raise it.
- **`Download Cover…` may now replace a cover you put there yourself.** Sprint 6
  refused this on purpose and ADR 0020 reverses it. The guard is that the
  button says *Replace Cover* over a preview, the old file is in the Trash and
  ⌘Z works. **Look at that button in both languages and say whether it warns
  you enough.**
- **A cover cannot be set for a multiple selection**, deliberately. If you want
  it, it wants its own confirmation — it is one picture onto many books.
- **`Take Cover from Book File` was more than you asked for.** It stays, but
  it is the one part of this sprint nobody specified, so it is the one most
  worth your disagreement.

### 3. The things only real hardware and real books can answer

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
**Stand: v1.0 ist freigabebereit**, `main` grün, 701 Kern-Tests (macOS und
Linux), CI grün auf allen drei Jobs, SlateKit-Pin
`0.4.1`, Version `1.0.0` in `project.yml`, Tag `v1.0.0` **nicht** gesetzt.
Sprint 9 (Cover ändern — vier Wege, Papierkorb statt Löschen, ⇧⌘Z repariert)
ist fertig, ebenso ein `make proof`-Lauf gegen das geänderte Schema und ein
`make release-dry`; oben in `CHANGELOG.md` stehen die Zahlen.

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
