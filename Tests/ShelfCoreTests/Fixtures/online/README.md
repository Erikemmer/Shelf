# Stored answers from the two metadata services

Every file here is what a service actually said, fetched by
`Scripts/online-proof.sh` on **18 September 2026** and trimmed of the fields
ShelfCore never reads — with two exceptions, named below.

**The tests never touch the network, and neither does CI** (CONCEPT §14). A
reader that is checked against a live service is a test that fails when
somebody else's server is having a bad afternoon, and passes for reasons it
cannot name. These files are the only input `OpenLibraryReader` and
`GoogleBooksReader` are ever tested against.

## What was trimmed

| File | Kept | Dropped |
|---|---|---|
| `openlibrary-isbn-*.json` | the first `doc` | the other docs |
| | the asked-for ISBN plus five others | the rest — *Dune* answers about two hundred |
| | twelve subjects, which is what the reader keeps | the rest — *Nineteen Eighty-Four* answers a hundred |
| `openlibrary-title-*.json` | all five docs, same per-doc trim | — |
| `googlebooks-*.json` | `id` and the twelve `volumeInfo` fields the reader reads | `saleInfo`, `accessInfo`, `searchInfo`, `readingModes`, `panelizationSummary` |

The trimming is done by `jq` inside the proof script, so re-running it produces
the same shapes rather than something hand-edited.

## The two that are not live answers, and why

**`googlebooks-volume-reconstructed.json` was written by hand.** On the day of
the run, `https://www.googleapis.com/books/v1/volumes` answered **HTTP 429,
"Quota exceeded … for consumer project_number:624717413613", to all ten
ISBNs** — that is the shared anonymous quota, exhausted before Shelf asked
anything, and it was 429 from `books.googleapis.com` as well and with
`country=DE` and `country=US`. No live volume record could be obtained, so the
one the reader is tested against is built from Google's documented response
shape. It is marked here rather than passed off as a measurement.

**`googlebooks-quota-exceeded-429.json` is the real 429**, kept because it is
worth a test of its own: it is what the app has to survive quietly, and all ten
requests got it byte for byte. Nine identical copies were not worth keeping.

**`googlebooks-empty.json`** is the documented shape of "nobody has this" —
`totalItems: 0` and no `items` key at all, which is the case that made an early
reader throw instead of answering "no candidates".

When the quota allows, re-run `Scripts/online-proof.sh`: it overwrites these
files with live answers, and `docs/BACKLOG.md` carries the line asking for it.
