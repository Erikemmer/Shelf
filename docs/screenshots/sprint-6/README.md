# Sprint 6 – online metadata

Five pictures of the real window, 1440 × 877, taken by `Scripts/online-shot.sh`
on 18 September 2026 against a twelve-book library built by
`Scripts/online-library.sh`. The books are generated EPUBs carrying the
bibliographic details of real books — a lookup cannot be photographed against
invented ones — and no borrowed book file is in this repository or in the cache.

**Four of the five went to the live services.** What they show is what Open
Library and Google Books said that afternoon, including the parts that are
unflattering.

## `online-candidates.jpg` — the candidate list

*The Left Hand of Darkness*, a book with no ISBN, so the question is title and
author and the answer is a list. Five candidates, best first, each with its
match out of 100: the book itself at 100, an Earthsea omnibus at 94, two
collections at 87 and 85, a Library of America edition at 83.

**My reading:** it does what it is for. The number beside each row is the point —
"best first" alone would have made the 94 look like an answer, and it is an
omnibus. What it also shows is that the ranking is *lenient* with omnibuses:
94 for a volume that contains the book among others is high, and a person could
click it without noticing. Worth narrowing; it is in the backlog rather than
guessed at now.

At the bottom of the sheet and again in the sidebar: **Google Books answered
429.** That is not staged.

## `online-comparison.jpg` — field by field, old beside new

*Clean Code*, asked by ISBN. One record came back, so the sheet opened it
straight away rather than showing a list of one. Seven lines, each saying what
the book holds, what the service says, and which of the two it is: `would
replace` for the title and the publisher, `already the same` for the authors,
the language and the ISBN, `would add` for the tags, `not set` for the date.
One box is ticked — the date, the only line that fills an empty field.

**My reading:** this is the picture the sprint is about, and the thing I would
point at is the *unticked* boxes. The service's title is better than the book's
and its publisher is right; neither is chosen for the person, because both would
overwrite something somebody may have typed. The cover preview on the left is
the real Prentice Hall cover, fetched from Open Library.

## `online-cover.jpg` — a cover, and why nothing is ticked for anybody

*Fantastic Mr Fox*, a book whose folder has no cover file, so **Use This Cover**
is offered under the preview. It is also the most useful picture in the set,
because everything Open Library says about this book is wrong for this book:

| field | what it says | what it is |
|---|---|---|
| Authors | `Roald Dahl & Roal'd Dal'` | the same man, twice, once transliterated |
| Publisher | `Caedmon Audio Cassette` | an audio edition of the work |
| Language | `ja` | a Japanese edition of the work |
| Published | `1917-01-01` | not this book, by fifty years |

None of the four is ticked, and the button reads plain **Apply**, disabled.
Three of them are `would replace`, which is never ticked; the year is `not set`,
which *was* ticked until this picture was looked at — Open Library's search
answers a **work**, and hands out one of its editions' publisher, language and
year. Now a record that describes a work never pre-ticks those three
([ADR 0015](../../adr/0015-online-metadata-two-sources-field-by-field.md)).

**My reading:** the feature found its own worst case and the defaults survived
it. The lines are still drawn, because what a service says is worth seeing even
when it is wrong.

## `online-network-error.jpg` and `online-network-error-status-bar.jpg`

The same lookup with `SHELF_ONLINE_HOST=metadata.invalid` — the name RFC 2606
reserves as never-resolvable — so both services really fail. Nothing on the Mac
was switched off for it.

The sheet says *"Nothing came back. The book keeps everything it has."* and,
small and grey at the bottom, both services' own words. The second shot is the
same moment with the sheet closed: the window is entirely usable and the only
trace is one line in the sidebar's footer, **"Open Library and Google Books did
not answer."**

**My reading:** this is the claim of CONCEPT §9 met — no dialogue, no spinner
left behind, nothing modal. The line is short because the first version was not:
the two services' full sentences came to 130 characters and the footer showed
"…hostname could not be foun…", which tells nobody anything. The full text is
still in the sheet and in the row's tooltip.

## What is not here

- **A Google Books candidate.** Its shared anonymous quota was exhausted all
  day: HTTP 429 to all ten ISBNs of the proof run, from both hostnames and with
  either `country` parameter. Every picture here that says "Google Books
  answered 429" is honest and none of them shows what a Google Books candidate
  looks like beside an Open Library one.
- **A batch.** A multiple selection walks the books one at a time with a
  decision each; the sheet's header reads "Book 3 of 12" and Apply becomes
  "Apply 2 fields and Continue". Not photographed.
