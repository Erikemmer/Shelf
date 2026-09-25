# ADR 0015 – Online metadata: two sources, field by field, never automatic

*18 September 2026. Status: accepted.*

## Context

CONCEPT §9 asks for metadata from Open Library and Google Books, without an API
key, by ISBN where there is one and by title and author otherwise; a candidate
list, then the chosen candidate set against the book field by field with a
checkbox each; a cover fetched when the file has none; and network failures that
are quiet.

Two things were found by asking the services rather than by reading about them,
and both changed the design.

## Decision

### 1. Both services are asked, always, and one failing is not a failure

They disagree often enough to be worth both: Open Library has the subjects and
the covers, Google Books has a description for far more books. A lookup collects
what came back and what did not; the candidate list is whatever arrived, and the
failures are one line in the status bar.

**This is not a hypothetical.** On the day of the proof run Google Books
answered **HTTP 429 — "Quota exceeded … for consumer
project_number:624717413613" — to all ten ISBNs**, from `www.googleapis.com` and
`books.googleapis.com` alike and with `country=DE` and `country=US`. That is the
shared anonymous quota, exhausted by everybody's unkeyed requests together,
before Shelf asked anything. An app that treated "a service refused" as "the
lookup failed" would have had no online metadata at all that day, although Open
Library answered nine of the ten.

### 2. Open Library is asked through `/search.json`, not `/api/books`

CONCEPT §9 names `/api/books?bibkeys=ISBN:…` for an ISBN. It answered **HTTP 404
with an empty body and `content-type: application/json`** to every ISBN tried —
including ISBNs whose books Open Library's own search finds, and with
`jscmd=details` as well as `jscmd=data`. Four ISBNs, four 404s.

`/search.json?q=isbn:…` answers the same book in the same `docs` shape the title
question gets. So there is **one endpoint and one reader**, which is smaller than
what was planned rather than larger. The concept is not amended lightly; it is
amended because the endpoint it names does not answer.

### 3. Nothing is ticked that would replace an answer the book already has

The sheet arrives with boxes ticked only where a field is **empty**. Taking over
a value somebody typed is a decision about their library, and a sheet whose
Apply button quietly overwrites eleven fields is not a confirmation.

Two exceptions widen that, both found by looking at a screenshot:

- **Tags are never pre-ticked**, although adding them takes nothing away. A
  catalogue's subjects are catalogue vocabulary — "Reliability", "Accessible
  book", "Open Library Staff Picks" — and a person's tags are their own.
- **A record that describes a *work* never pre-ticks a publisher, a language or
  a date.** Open Library's search answers a work, and hands out one of its
  editions' fields. For a Puffin paperback of *Fantastic Mr Fox* it offered
  `Caedmon Audio Cassette`, `ja` and **1917** — and the year, being the one that
  filled an empty field, arrived ticked.

The lines are still drawn. What a service says is worth seeing even when it is
wrong, and hiding it would make the sheet look more certain than it is.

### 4. Applying goes through the field rules the inspector uses

`MetadataMerge.apply` hands each ticked line to `BookField`, `TagEdit` or
`IdentifierEdit` — the same rules a typed value goes through. An ISBN whose
check digit does not match is refused whether a person or Google Books offered
it, and a refused line is **left out and named** rather than failing the other
ten. The change then goes through `LibraryModel.apply`: undo registered from the
old book *before* anything is written, then `metadata.opf`, then the index. A
fetched title is undone with ⌘Z exactly like a typed one.

### 5. No automatic bulk match

A multiple selection walks the books one at a time, with a decision for each and
a "Book 3 of 12" in the header. There is no "do them all" button, because a
button that writes to four hundred books on one click is the thing this whole
design exists to avoid.

### 6. Manners towards somebody else's server, as a rule with a test

`NetworkPolicy`: a User-Agent naming the project and its repository and **nothing
about the person**; at most one request per second **per service**; a retry only
for a 5xx or for a request that got no answer at all, with 1 s, 2 s, 4 s; a time
limit; and every answer kept in `~/Library/Caches/Shelf/online/` for a month so
the same ISBN is not asked twice. A 429 is not retried — it is the service
saying stop, and the answer to being told to stop is to stop.

The only thing that leaves the Mac is the ISBN or the title being looked up. No
identifier of the person, the library or the machine; no telemetry.

### 7. The rules are in the core; the socket is in the app

`MetadataTransport` is the seam. Which URL, how often, what a 503 means, whether
this was asked before, what the two JSON shapes mean, which candidate is the
book, and what a candidate would do to it — all of that is `ShelfCore` and all
of it is tested without a network. `URLSessionTransport` is thirty lines in
`App/Shelf`.

The tests read **stored real answers**, fetched once by
`Scripts/online-proof.sh` and trimmed by it; no test and no CI job opens a
socket. The provenance of every file, including the one that is *not* a live
answer, is in `Tests/ShelfCoreTests/Fixtures/online/README.md`.

### 8. A cover is written only on an explicit action, and never over one

`OnlineCover.write` refuses when the folder already has a cover file, checks the
bytes' magic number before writing anything — a service that answers an error
page with a 200 would otherwise leave a `cover.jpg` holding the words "Not
Found" — and writes through a `.part` and a rename. **The book file is not
opened at all**: the cover is a new file beside it (CONCEPT §4, "Won't").

## Consequences

- Shelf needs `com.apple.security.network.client`. Outgoing only; there is no
  server entitlement, because Shelf listens for nothing (CONCEPT §12).
- Two services with no key means two services that can refuse, and one of them
  did, all day. The design survives it; the *evidence* is thinner for Google
  Books than for Open Library, and `docs/BACKLOG.md` says so.
- A person who wants a field the services got right must tick it. That is one
  more click than an app that guesses, and it is the point.
- The response cache means a second lookup of the same book costs nothing and
  shows the same answer — including a wrong one — for a month. `Shelf ▸ Clear
  Downloaded Metadata` names its size and empties it.

## Addendum – 24 September 2026, Sprint 18, Teil C4

**A batch pass now exists, on Erik's explicit instruction, and rule 5 above is
narrower than it reads.** Re-read carefully, rule 5's own reasoning is about a
*title* search: "a multiple selection walks the books one at a time… because a
button that writes to four hundred books on one click is the thing this whole
design exists to avoid" sits directly under "no automatic bulk match", and the
match rule 5 means is the one this ADR spends most of its words on — a title
and an author naming a *book*, of which there may be nine editions, scored and
picked from a list. That is a guess, however good the score, and nothing about
this addendum changes how it is handled: still one book at a time, still a
person choosing.

**An ISBN search is not that kind of match.** It names one edition by
construction (rule 2's own reasoning — the query itself is the identity, not a
score over one), the same fact B3's merge-matching already trusts an ISBN
with and ADR 0002 trusts a hash with. `FillMissingFields.plan` runs
`MetadataMerge`'s own field-by-field trust rules — the identical
`isTickedByDefault` this ADR already requires: empty field only, only from a
record about this edition, never where the two services disagree — for every
book with a valid ISBN, in one pass, and shows **one combined preview naming
every book and every field before anything writes**, exactly ADR 0018's
"preview is the plan" applied to a fetched value instead of a typed one. That
is a previewed, confirmed, undoable command, the same shape `Merge into…` and
`Standardize Fields…` already are — not the silent "four hundred books on one
click" rule 5 was written to rule out. Nothing here lowers the bar for what
gets ticked; it only runs the existing bar over many books instead of one.

**The one field allowed outside ISBN identity is `description`, and only
under `DescriptionFill`'s own four conditions** (empty field; exactly one
Title+Author candidate matching the book's title and every author exactly;
a known language agreeing with the book's own; a plain-text summary over 80
characters). This is deliberately the risk rule 5 warns about, narrowed as
far as it can go: the field a wrong edition costs the least (a description is
close to the same across a book's printings) and the identity check borrows
what a title search cannot usually offer — an *exact*, not scored, agreement
on both title and every author, standing in for the ISBN this book does not
have or whose search came back with nothing. Everything else stays
ISBN-only; there is still no scored Title+Author guess for a publisher, a
date, a language or a series here or anywhere this addendum touches.

## Addendum – 25 September 2026, Sprint 19, Teil B2

**A 429 now stops that service for the rest of one batch pass, not just the
one request that got it.** Until today, "a 429 is an instruction, not a
hiccup" (`NetworkPolicy.shouldRetry`) only ever governed the *retry* — the
answer to being told to stop was never asking that one request again, but
the very next book's own ISBN or Title+Author question still asked the same
service fresh, and a shared quota exhausted on book one would have logged
the same "429" sentence, unhelpfully, up to 366 times. `FillMissingFields
.plan` now remembers which service refused with 429 and passes it back into
every later `MetadataFetcher.candidates(for:skipping:)` call for the rest of
that one run, so the sentence is said once and the rest of the run simply
does not ask again — counted in `Result.serviceSkips`, not silently dropped.

**Scoped to one `plan` call, not to the fetcher.** `OnlineMetadataModel` and
`FillMissingFieldsModel` deliberately share one `MetadataFetcher` instance
(so the two features' requests are paced against each other) — blocking a
service inside the fetcher itself would have meant a batch run's 429 also
silently emptying the one-book "Fetch Metadata…" sheet for the rest of the
app session, which nobody asked for and nothing would have explained. The
block lives in the loop that has a "run" to speak of; the actor stays as
stateless about refusals as it always was.

## Addendum – 25 September 2026, Sprint 21, Teil A1/A2 — two probes, before building anything

**A1: Open Library's own per-ISBN edition endpoint genuinely answers one
edition — unlike `/api/books` (rule 2 above) and unlike `/search.json`
(rule 3), neither of which this addendum touches.** `/isbn/<ISBN>.json`
(redirecting to `/books/<OLID>.json`) is a different endpoint from both:
asked for 10 of the library's 36 real ISBN books, cached, it answered 6 of
10, and every one of the 6 carried `publishers`, `publish_date` and
`languages` — real edition-level fields, not a work's guess at one. Teil B2
builds on this.

**A2: 20 more real ASINs, cached, `/search.json?q=id_amazon:<ASIN>`,
alongside Sprint 20's own five — 25 in total, the decision rule's own
threshold.** 1 hit across all 25 (Sprint 20's own), naming exactly one work
and exactly one edition; the 24 others answered `numFound: 0`. No hit, in
25 tries, ever named more than one of either. The decision rule this ADR's
own addendum below sets: coverage does not decide whether B3 gets built,
uniqueness does — and no probe ever failed the uniqueness question, however
rarely it fires. Teil B3 builds on this.

## Addendum – 25 September 2026, Sprint 21, Teil B1/B2/B3 — a work's own
description, a real edition by ISBN, and an ASIN treated the same way

**B2 — `OpenLibraryEditionReader` reads `/isbn/<ISBN>.json`, and its answer
is folded into the same-ISBN `/search.json` candidate, never shown beside
it.** Both are Open Library's own opinion about one book; keeping them as
two separate "Open Library" lines would have made `MetadataMerge`'s own
per-source contest logic (rule 3's "two answers to one field are two
lines") see one service disagreeing with itself. `EditionMerge.folding`
instead **replaces** the `/search.json` candidate's `publisher`,
`published` and `language` with the edition endpoint's own values — never
half of one and half of the other: a field the edition record does not
carry is left empty, not inherited from the work-level guess it would
otherwise wear a newly-`true` `describesOneEdition` flag over. Where
`/search.json` found nothing at all for this ISBN, the edition record
stands on its own. The endpoint is asked from `FillMissingFields`' own ISBN
branch only — never from `MetadataFetcher.candidates(for:)`, the seam the
one-book "Fetch Metadata…" sheet and every existing test already depend on
— so nothing about that sheet's own request shape changes by this
endpoint's existing at all. A 429 from it blocks Open Library for the rest
of the run, the identical rule the addendum below already set for
`/search.json`'s own refusal.

**B3 — an ASIN is asked through the same `/search.json?q=id_amazon:<ASIN>`
Teil A2 probed, and only trusted once `OpenLibraryASINSearch.uniqueEdition`
confirms exactly one work with exactly one `edition_key`.** That key is
then asked directly, `/books/<OLID>.json` — the identical shape and reader
`/isbn/<ISBN>.json` redirects to, so B3 is B2 with a different first hop,
not a second set of field rules. An ASIN search naming more than one work,
or one work with more than one edition, fills nothing — never a guess
between candidates the way rule 5 forbids for a title. `FillMissingFields`
only ever reaches this branch for a book with **no** valid ISBN; a book
that has one is never additionally asked its ASIN.

**B1 — a description, the one field Open Library's `/search.json` has
never carried (rule "the search carries no description at all",
`OpenLibraryReader`).** `OpenLibraryWorkReader` reads a work's own record,
`/works/<key>.json` — found, not assumed, to answer `description` as
**an object**, `{"type": "/type/text", "value": "…"}`, never a plain
string, on every real work record this project has read that carries one
at all. Reached two ways: from `DescriptionFill`'s own Title+Author match
(conditions (a)–(c) unchanged), once that match is Open Library's and its
inline `summary` is (as it always is) `nil` — its candidate `id` already
names the work key; and from B2/B3's own edition record, whose `works`
field names the same key without any Title+Author guess at all, gated only
by the edition's own language agreeing with the book's (there is no second
candidate here to disambiguate against — an ISBN or a uniquely-resolved
ASIN is already a stronger identity guarantee than condition (b) ever
gives a title search). Condition (d) — long enough, no markup beyond a
paragraph break — applies unchanged to a work-level answer exactly as it
already did to Google Books' inline one.

**Test data throughout is invented — no real ISBN, ASIN, title or author
from Erik's library is in any fixture or test name (`CLAUDE.md`).** The
probes above ran against the real library and are named, with counts, only
in the report to Erik and in `docs/HANDOFF.md`; nothing from them is
quoted here.

## Alternatives not taken

- **An API key for Google Books.** It would fix the 429, and it would be a
  secret in a shipped app, which is a secret everybody has. CONCEPT §9 says
  without a key and this keeps to it.
- **Asking one service and falling back to the other.** Cheaper on their
  servers, and it hides the disagreement that makes two services worth having.
- **Matching automatically above some score.** A single candidate scoring 100 —
  the service repeating the ISBN back — opens without a click, and that is as
  far as it goes. Writing without a person looking is what CONCEPT §9 forbids.
