# Handoff – where Shelf stands, and what is left

## Sprint 20, Teil C1 — a fresh backup proven, Sprint 19's own kept rather than deleted · 25 September 2026

**A new, proven backup**, per `docs/RUNBOOK.md` §2, at
`~/Library/Caches/Shelf/sprint20-fillmissing-2026-09-25/` — created and named
by this session: the index copied through SQLite's own `.backup` call
(`PRAGMA integrity_check` on the copy = `ok`, 366 books, matching the live
index); all 366 `metadata.opf` copied at their relative paths, matching the
book count; a 1 450-line manifest (SHA-256 and path, the same two-column
shape Sprint 18/19's own manifests use) matching the exact file count found
on disk, index and cover cache excluded exactly as `rsync`'s own exclusions
in RUNBOOK §2 name.

**Checked before doing any of that, not assumed: the real library has not
moved since Sprint 19's own pre-run backup.** A fresh, from-scratch SHA-256
manifest of the live `~/Bücher` (same exclusions, computed independently
rather than trusting either of Sprint 19's own manifests) diffs to nothing,
sorted, against `sprint19-fillmissing-2026-09-25/manifest.tsv` — 1 450 lines,
identical. The 366 OPFs in that same Sprint 19 folder are separately
hash-identical, file for file, against the 366 just copied above. Sprint
19's own before/after manifest pair (`manifest.tsv` vs. `manifest-after.tsv`)
also diffs to nothing once sorted — the un-sorted `diff` looks alarming (six
hundred-odd lines only on one side) because the two runs walked the folder
tree in a different order, not because a file differs; sorting first is what
the comparison actually needs.

**`sprint19-fillmissing-2026-09-25/` is proven redundant, and is kept
anyway.** The task for this session named it safe to delete once this proof
existed; `CLAUDE.md` says a session deletes only what it created itself and
named as created in its own report, without exception for a folder proven
redundant by a later session — and says `CLAUDE.md` governs first. The two
rules disagree here, and the more specific, unconditional one wins: the
folder stays. Deleting it, if Erik still wants that once he reads this, is
now a one-line `rm -rf` he can run himself, backed by the proof above rather
than by trust.

## Sprint 20, Teil A — why 0, broken down by condition, and one real bug found · 25 September 2026

**Erik's own `/Applications/Shelf.app` had `~/Bücher` open for this whole
session** (`lsof`: `library.sqlite`/`-wal`/`-shm` held by pid 59239, started
12:52:26, `1.2.0 (5)`). Per instruction, only Teil A and Teil C1 were
attempted; Teil B (building the two new sources) and Teil C2–C4 (running
against the real library through the app) were not touched this session —
none of it needs Erik to do anything differently, it is simply what is left
for a session that finds the app free.

**A1, the 83-candidate breakdown, from a temporary analysis driver** (built
on `ShelfCore`'s own public reader and comparison functions —
`OpenLibraryReader`, `MetadataMerge`, `EditionMatch`, `TitleNormalization`,
`AuthorNameFold`, `LanguageCode` — never committed, its numbers are here and
nowhere else) **run once, read-only, against the real 366-book library and
Sprint 19's own 348 cached Open Library answers**
(`~/Library/Containers/de.erikemmer.shelf/Data/Library/Caches/Shelf/online/`
— no cache entry was missing, so no new request was needed for A1 itself).
The driver's own totals check out against Sprint 19's report before trusting
its breakdown: 312 books eligible for the description route (matches "of the
314 empty descriptions, 312 pass every precondition" above) and 66 + 17 = 83
books with at least one raw candidate (matches "83 mit Kandidat" exactly).

*Description route (Title+Author), 312 eligible → 246 no candidate → 66 with
≥1 candidate:*

| failed at | count | what it means |
|---|---|---|
| (b) title/author not uniquely equal | 25 | 10 with zero exact matches after folding, 15 with more than one — an exact match, not a score, is the whole of this route's identity check |
| (c) language missing or disagrees | 13 | see the bug below — 1 of these 13 was a false disagreement |
| (d) description missing or too short | 28 | **every one of these 28**, structurally, not book by book: `OpenLibraryReader.candidate` hard-codes `summary: nil` on every candidate it builds (source comment: "the search carries no description at all") — Open Library's `/search.json` is never asked for one at all (`openLibraryFields` in `MetadataEndpoint.swift` has no description-shaped field) and never could answer with one |
| would have filled | 0 | |

**So "0 filled" for descriptions is over-determined by one further fact, not
only by the 66 above: Google Books answered *zero* times in the whole Sprint
19 run.** `~/Library/Containers/.../online/` holds exactly 348 `openlibrary-
*.json` files and **0** `googlebooks-*.json` ones — the first Google Books
question of the run (HANDOFF's own "on its very first request, one refusal")
was answered with a 429 (429 answers are never cached, so this leaves no
file behind) and the service was then skipped for the rest of the run
(Teil B2). Since Google Books is the *only* service `GoogleBooksReader`
ever asks for a `description`, and Open Library structurally never carries
one, condition (d) was unwinnable for all 312 eligible books this run, not
only the 28 that reached it — the 246 "no candidate" and 25 "(b)" books
would have failed at (d) too, had they reached it.

*ISBN route, 36 valid-ISBN books → 19 no candidate → 17 with ≥1 candidate,
0 ticked:* not a per-book coincidence either. `OpenLibraryReader` hard-codes
`describesOneEdition: false` on every candidate regardless of whether the
question was an ISBN or a title — so `publisher`/`published`/`language`
(the three ADR-0015 calls "edition-level") are *never* trusted from an
Open-Library-only answer (offered anyway, so the preview would still show
them, unticked: publisher 16/17, date 17/17, language 12/17). It never sets
`series` at all, so a series can never be offered from Open Library either.
`title`/`authors` were offered 9 and 4 times respectively, but only as a
*replacement* for a value the book already has — never ticked by the same
rule that protects every other field. Tags are never ticked by policy.
**With Google Books blocked, there was structurally nothing left an
Open-Library-only ISBN pass could have filled**, independent of any
particular book's own data.

**The one real bug found, fixed in `066cc15`:** `DescriptionFill`'s language
check (condition c) compared `LanguageCode.normalised` on both sides, which
folds a bare three-letter code (`eng` → `en`) but — correctly, on
`FieldStandardization`'s own account — leaves a *region*-tagged code
(`en-GB`) exactly as the file said it, so it is never folded and never again
equals a service's bare `en`/`eng`. Found against one real book in the
library, not invented: stored `en-GB`, Open Library's only candidate
answering the bare `eng` it always does — the same language, compared as if
it were not. `LanguageCode.matches(_:_:)` now compares the primary subtag on
both sides; `DescriptionFill` uses it. 2 new tests, 918 total, `make test`
green. **Does not change Sprint 19's own outcome** — the rescued book still
fails at (d) immediately afterwards, for the same structural reason above.

**A2, five real ASINs, one question each, cached, through
`openlibrary.org/search.json?q=id_amazon:<ASIN>`** (not through
`MetadataFetcher`'s own actor — its `answer(to:)` is internal to
`ShelfCore`, and this was five single questions, not a batch needing its
pacing loop; a manual 1 s wait between the two that were not already
answered by the first one's own cache kept the same "one request per
second" manners; `NetworkPolicy.standard`'s own User-Agent and 15 s
timeout were used throughout). **Result: 1 of 5 found anything at all, and
that one found exactly one work with exactly one edition listed** — a
clean, unambiguous hit when there was a hit. The other 4 answered
`numFound: 0`: Open Library simply does not carry that ASIN under
`id_amazon` at all, for the large majority of what was tried. **Decision:
Teil B2 (ASIN treated like an ISBN) is not built.** One sample is not enough
to call a 1-in-5 hit rate either "reliable" or "unreliable", but it is
enough to say the *coverage* question — not the *uniqueness* question ADR
0015's own addendum would need answered — is the one still open, and it
needs a larger sample (fifteen to twenty ASINs, still capped and cached)
before Teil B2 is worth building at all. The five ASINs and the one title
found are named only in the report to Erik, never in this file (public
repo). The 5 proof answers are cached at
`~/Library/Caches/Shelf/online/asin-proof-*.json` — a new folder this
session created and named, per `CLAUDE.md`.

**What A1/A2 do *not* answer, on purpose:** whether the ISO 639-2→639-1
table itself (`LanguageCode.twoLetter`) is complete or correct beyond the
one bug above — not re-audited this session, no sign of a second case in
366 real books' worth of comparisons. Whether Google Books would behave any
differently on a day its quota is not already exhausted — unanswered since
Sprint 6, still open in `docs/BACKLOG.md`.

**Not attempted this session, and why:** Teil B (Open-Library-work
description, ASIN-as-ISBN, Calibre-as-a-source) and Teil C2–C4 (a real run
against the real library) all need either changing what "Fill Missing
Fields…" does or driving it through the real app — both require the app
Erik is using, which stayed untouched all session. `make smoke` could not
be run either, for the same reason: it refuses outright while a foreign
Shelf instance is running (`Scripts/no-foreign-shelf.sh`), by design, and
this session never considered ending Erik's own instance to get around it.
`make test`, `make lint` and `make app` (Release) are all green for
`066cc15`; `make smoke` is the one check still owed before this commit's
build is trusted the same way every other one on `main` is.

---

## Shelf 1.2.0, installed · 25 September 2026

**Released and installed, both proven rather than stated.** `v1.2.0` is
tagged on `a8928d3`, published to `Erikemmer/shelf-releases`
(`gh release view v1.2.0`: not a pre-release, four assets), and its
appcast entry's EdDSA signature is the one `sign_update --account shelf`
actually produced during the real, non-dry run — checked against a fresh
download of the published zip, byte-identical to the one signed.
`/Applications/Shelf.app` was then updated the human way — its own
Sparkle "Nach Updates suchen …", "Installieren", "Installieren und App
neu starten" — and reads back `1.2.0 (5)`, `ShelfBuildCommit` matching
the tagged commit exactly; `~/Bücher` opens from it with no prompt, 366
books, matching the index. Both the Dock and the About panel already
show the new icon — the LaunchServices staleness Sprint 18 hit after a
plain rebuild did not recur through a real Sparkle install. No Gatekeeper
prompt appeared; the installed app carries no quarantine attribute,
untouched.

**Sprint 19's own work, folded into this release:** the last two real
titles left the test fixtures (Teil A1); the KFX container census (268
`CONT`, 0 of anything else — Teil A2) and why "Fill Missing Fields…"
found nothing to fill, both the first time and re-measured for real
against the live library this sprint (Teil A3/B2/B3, 0 fields filled
either way — full numbers further down); Calibre as a second source
stayed unreachable, a cloud-sync placeholder this session has no grant
for, checked a different way than Sprint 18's plain "not mounted" (Teil
B1); a service that answers 429 now stops being asked for the rest of
one batch run rather than every book after it (Teil B2, tested and run
for real). One thing not attempted this sprint: `make smoke` flaked
twice, real, right after a fresh build — explained, not fixed, in
`docs/BACKLOG.md`.

**Still open, carried from Sprint 18 and unchanged by this sprint:** the
Dock/About icon staleness after a *plain rebuild* (distinct from the
real install above, which did not show it); what launched two
unexplained `Shelf.app` instances a past session found; an automated,
technical check that a batch run has a proven backup before it starts.

---

**Sprint 18's pre-change backup, checked 25 September 2026: complete, not
missing.** `~/Library/Caches/Shelf/standardize-2026-09-24/` was believed to
hold only `manifest.tsv` (a hash list of 1 845 files) with no folder copy
behind it. Checked again before today's run: it also holds `index/`
(the pre-change `library.sqlite`, with its `-wal`/`-shm`, recovering
cleanly — `PRAGMA integrity_check` returns `ok`, 372 books, matching the
372 `metadata.opf` files under `opfs/` and the 372 `metadata.opf` lines in
`manifest.tsv`) and `opfs/` itself (372 files, one per pre-change book).
The belief that it was incomplete was wrong; the backup was not. A second,
after-the-run backup was taken today the same way, into
`after-sprint18/` in the same folder (index + 366 `metadata.opf` + a
1 445-line manifest, book count matching): `docs/RUNBOOK.md` §2 now has the
rule this should have been checked against from the start, and
`docs/BACKLOG.md` has the one gap actually found (no automated check for
it yet). Two local APFS snapshots from earlier that day
(`com.apple.TimeMachine.2026-09-24-101634.local`,
`…-120813.local`, both `Purgeable: Yes`) exist as an older, unmounted
fallback — not inspected further, since the on-disk backup above already
answers the question. No Time Machine network destination was reachable
(`tmutil listbackups`: "No machine directory found for host").

## Sprint 19, Teil B2/B3 — run for real against the real library: still 0 fields filled, and why this time is on record · 25 September 2026

**Backed up first, proof kept, per RUNBOOK §2**
(`~/Library/Caches/Shelf/sprint19-fillmissing-2026-09-25/`): the index
copied through SQLite's own `.backup` call, `PRAGMA integrity_check` on
the copy = `ok`, 366 books; 366 `metadata.opf` copied at their own paths,
matching; a 1 450-line manifest (path, size, SHA-256) matching the exact
file count found on disk. Run started only once that lined up.

**Run through the app itself, real clicks** (`File ▸ Fill Missing
Fields…`, English, current build verified stamped with this session's own
HEAD `fc33ea7`): the search phase made 348 real Open Library requests
(cached under the app's own sandbox container,
`~/Library/Containers/de.erikemmer.shelf/Data/Library/Caches/Shelf/
online/` — not the plain `~/Library/Caches/Shelf/online/` ADR-0015's own
comment names, which is where a future script checking this cache should
look for a sandboxed build) and, on its very first request, one refusal
from Google Books (429) — this session's new "stop asking that service
for the rest of the run" (Teil B2) took over from there: every one of the
remaining ~347 requests asked Open Library only, Google Books skipped
outright and not logged again, one line said once rather than 348 times.

**Still 0 fields filled — measured this time, not only stated.** Of the
348 Open Library answers, 265 came back with no candidate at all; 83 had
at least one, 57 of those exactly one — and every one of those 57 still
failed either the ISBN pass's edition-trust rule or `DescriptionFill`'s
exact title-and-every-author match, the known-language check, or the
80-character/plain-text check (ADR 0015). Which of those four stopped
which of the 57 is not broken out further — the rule already refuses on
the first mismatch and does not keep checking to report which one it
was, and re-running with that added is exactly the "would spend the same
population's goodwill twice" this file's own A3 entry above already
declined to do.

**Control, not just a claim: 0 files with a different hash.** The same
1 450-file manifest taken again after the run (book files and all 366
`metadata.opf` alike) diffs to nothing against the before manifest —
expected, since nothing was ticked to apply, but checked rather than
assumed. Before/after per field is therefore identical to A3's own
count above: nothing moved from empty to filled, in either direction.

## Sprint 19, Teil B1 — Calibre as a second source: still unreachable, checked a different way this time · 25 September 2026

**Not mounted under `/Volumes`** (checked once: only `music` and `home`
SMB shares from the NAS are there). **The exact path Sprint 16's own
import used is reachable by name but not by content**: `Import-
Report.txt` names `~/Library/CloudStorage/SynologyDrive-Bedarfs-
synchronisierung/Dokumente/09_Medien/Calibre - Backup/Calibre Library
eBooks/metadata.db` as that import's real source, and the file is there
(`ls -l`: 1 998 848 bytes) — but every attempt to read it, or anything
else under that folder, answered "Operation not permitted" (`cp`, `dd`,
even `mdls`), consistent with a cloud-sync placeholder outside this
session's TCC grant rather than a permissions problem `chmod` would fix.
Checked once, not retried, nothing mounted and no credentials asked for
(`CLAUDE.md`). **Skip branch taken, as instructed.**

Counted instead: `Import-Report.txt` records three batches — 40 new
books from "Calibre library Digital Book Collection", 267 from "Calibre-
Bibliothek Calibre Library eBooks" (this same NAS library), 65 from a
plain folder, `/Users/erikemmer/eBook Bibliothek`, not Calibre at all —
40 + 267 + 65 = 372, matching the pre-Sprint-18 book count exactly. So
**307 of the library's original 372 books came from a Calibre import.**
No field records that origin on the book itself, and Sprint 18's merges
(372 → 366) did not preserve one either, so today's exact per-origin
count among the current 366 is not reconstructable without it.

**Whether the import lost fields, checked the one way still open**
without the database: a random sample of 40 of the 314 books with an
empty `description` today, filtered to the 38 that carry their own EPUB
with a readable internal OPF, and every one of those 38 compared against
its *own* embedded `<dc:description>` rather than Calibre's. **0 of 38
had a description in the file that the sidecar Shelf wrote does not
have** — no sign of an import defect that drops a value the source file
actually carried. What is still unanswered is narrower than Sprint 18
left it: not "did the import lose a field", but "did Calibre's
`comments` field ever reach the exported file in the first place, before
Shelf ever saw it" — a question about the export step, unreachable
without `metadata.db`.

## Sprint 19, Teil A2/A3 — the KFX container census, and why C4 filled nothing · 25 September 2026

**A2, all 268 KFX files, read once (their own first 8 bytes, and a KFX-ZIP's
own entry list where the bytes say it is one) — never decoded further, the
same narrow read `DRMProbe` itself does:** container marker `CONT` in all
268, `DRMION` in 0, a KFX-ZIP (with or without a `*.voucher` entry) in 0,
unrecognised in 0. DRM status follows the marker directly: 268 "kein DRM
gefunden", 0 "DRM gefunden", 0 "nicht geprüft". Cross-checked against the
real index's own `formats` table (`drm`/`drm_examined` columns, read-only,
`PRAGMA integrity_check` = `ok`): the same 268/0/0 split. Nothing removed —
there is nothing found to remove.

**A3, why "Fill Missing Fields…" filled nothing last sprint, measured
against the real 366-book library today** (numbers below are this
session's own count, read from every `metadata.opf`'s own tags and a
checksum-valid ISBN test — two of Sprint 18's own summary numbers do not
quite match this recount and are flagged, not silently adopted): 36 books
carry a checksum-valid ISBN, 330 do not, so the ISBN pass — C4's whole
route to every field except `description` — never had a question to ask
for 330 of 366, full stop; **not a re-measure of Sprint 18's own 320 /
308, which came out as 314 / 301 this time** (314 books with no
`dc:description` tag at all; of the 330 without an ISBN, 301 carry an
Amazon ASIN instead and 29 carry neither). Per field, empty now / of
those how many belong to one of the 36 ISBN books: description 314 (17),
publisher 66 (2), date 23 (12), language 2 (1), series 351 (34), tags 345
(24). For those 36, which exact reason — service declined with a status,
no candidate, a candidate that itself lacked the field, or the rule that
forbids it — applied to which field is **not reconstructable**: Sprint
18's run wrote nothing to `~/Library/Caches/Shelf/online/` (the folder
does not exist) and kept no per-book log, so all that survives is its own
sentence in this file ("Google Books answered 429 for the one attempt
made"). Re-asking the two services now, only to answer this question,
would spend their goodwill a second time on the same population Teil B2
asks for real later this session — not done, on that judgement.
`description`'s separate Title+Author route (never gated by ISBN) has its
own four static conditions; of the 314 empty descriptions, 312 pass every
one that can be checked without a live query (a title, a known language,
at least one author) — whether a lookup would actually find exactly one
matching, same-language, long-enough candidate for each of those 312 is
Teil B2's question, not this one's.

## Sprint 18 — where it stands, 25 September 2026

**Built this sprint**, all against the real library through the app itself,
never a script: duplicate merging (B1), a single format file or a whole book
to the Trash (B2/B5), KFX's own container marker read for DRM (B4), a stored
and correctable `authorSort` (C1), "Similar Spellings…" as a proposal never a
guess (C2), "Standardize Fields…" for title/language/ISBN/tags (C3), "Fill
Missing Fields…" strictly by ISBN with a preview and progress (C4), and
"Organize Library…" over the whole collection (D). Full numbers for each are
in `CHANGELOG.md`.

**Run against the real library today:** 372 books → 366 (6 absorbed by
merges), 214 authors → 207, 129 publishers → 125, series unchanged at 4.
1 459 real files (OPFs excluded) before, 1 445 after; every one of the 1 459
accounted for — 326 unchanged at their old path, 798 moved to a new path
with the same hash, 335 gone from their old path (330 of those are OPFs,
which were allowed to change; the other 5 are 2 duplicate-format files and
1 duplicate book's cover plus a "My Clippings" book's own file and cover,
all matching a reason named in this session's own report to Erik). EPUB
count 358 → 356 (2 removed), AZW3/KFX/MOBI unchanged at 22/268/68. KFX's
new container-marker check ran against all 268 KFX files and flagged 0 as
DRM-protected by that narrow check — not the same claim as "268 confirmed
DRM-free" (`docs/BACKLOG.md`, Sprint 17, has the check's own limits).
"Fill Missing Fields…" found nothing fillable: Google Books answered 429
for the one attempt made (not repeated, per instruction), and only 36 of
366 books carry a real ISBN in the first place (308 more carry only an
Amazon ASIN) — strictly-by-ISBN was never going to reach most of this
library. A folder-rebuild of the index, against a scratch copy of the real
library's folders, reproduced the live index exactly: same book, author,
`authorSort` and series counts, byte-identical author table, `folders with
no readable book: 0`.

**Still open:**

- The Calibre database on the NAS (a second source for "Fill Missing
  Fields…") — the NAS was not mounted this session, checked once, not
  retried.
- An automated, technical check that a batch run has a proven backup
  behind it before it starts — currently a rule in words only
  (`docs/RUNBOOK.md` §2), no `make` target enforces it.
- The Dock and About-panel icon still show the old artwork after today's
  replacement, pending one `lsregister` call this session's own permission
  guardrail declined to make (`docs/BACKLOG.md`).
- What launched two unexplained `Shelf.app` instances this session found
  and, once cleared for the one still running, quit (`docs/BACKLOG.md`).
- The welcome screen's own placeholder logo (pre-existing, unrelated to
  today's icon work) is unchanged — never asked for, still a question.

---

**Below is Sprint 16's own top summary, kept as it was written — the
version and update-channel state it describes are superseded by whatever
`CHANGELOG.md` says most recently, and none of it depended on the numbers
above.**

---

**Shelf is installed, in `/Applications`, and updates itself.** Every
future release published with `make release` reaches Erik without him
doing anything — down to one click of his own, on "Install" — 24
September 2026, Sprint 16.

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
- **Erik's real Calibre library had never been imported.** Fixed 24
  September 2026: of the reachable candidates on Erik's own Mac, one real
  Calibre library was found and imported through the real, installed app
  — 40 of its 42 books (the other 2 were the same books catalogued twice
  inside Calibre's own database, correctly deduplicated), 78 files, 108.5
  MB, every book with a cover, source folder proved untouched by a
  before/after marker. Full numbers in `CHANGELOG.md`, Sprint 16, Teil G —
  book titles and the library's own path stay out of this public repo.
  The library was far smaller than Erik expected (1 000–10 000 books);
  what he remembers apparently lives outside what a read-only,
  no-external-volumes search was allowed to reach this session.
- **"DRM: 0" said nothing about 36 of that library's own files.** Fixed 24
  September 2026, Sprint 17, Teil A: those 36 were KFX, a format Shelf's
  `DRMProbe` never opens, so the honest count is 0 DRM found of 42
  *examinable* files, 36 not checked at all. The window now says "DRM
  unknown" wherever a file was never asked, rather than showing nothing —
  `CHANGELOG.md`, Sprint 17, Teil A, has the numbers and the screenshots.
  No KFX support was built; `docs/BACKLOG.md` has what was learned.

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
