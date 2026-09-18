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

## The other two fixes of this sprint

Three more pictures, taken by `Scripts/duplicates-shot.sh` against
`~/Library/Caches/Shelf/measure-library-6/library` — 415 books, of which four
really are copies (two book folders duplicated the way a person duplicates them
and given fresh UUIDs) and 394 only share a title with something.

### `duplicates-certain.jpg` — what is certainly a copy

The sidebar reads **Duplicates 4 · Possible Duplicates 394**. Before this
sprint it read a single **Duplicates 396**, in a library of 413 books, and
*none* of those 396 was an actual duplicate.

The grid holds exactly the four, in two pairs. The inspector lists **all three**
rules that matched the selected one — same file, same ISBN, same title and
author — which is the other half of the change: a book matched by several rules
now says so instead of being described by the best one alone.

**My reading:** this is what the collection is for. Four is a number somebody
acts on; 396 was a number somebody switches off. And the pair being listed under
`Duplicates` *only*, although its titles match too, is the disjointness rule
visible.

### `duplicates-possible.jpg` — what only looks like one

The same library, the other row. 394 books, every one of them a suspicion, and
the inspector's heading reads **Possible Duplicate** rather than Duplicate.

**My reading:** the grid is full of pairs that share a title — which is exactly
what a library of generated series volumes looks like, and exactly why the rule
had to be separated rather than sharpened. The heading doing the work is the
point: the same panel says "Duplicate" in the other collection.

### `selection-details.jpg` — what is `Mixed`, with its name beside it

415 books selected. The title block is gone — for one book its three type sizes
*are* the labels, and for 415 they were three bare "Mixed" one under the other.
Title, Authors and Series are now named rows in *Details*, beside Publisher,
Published and Language, which always had names.

Two neighbours in that block are fixed with them: **Added** reads a day only
because every book here was added on the same day (it says `Mixed` otherwise
rather than the anchor book's date), and **Size** reads **78.2 MB**, the sum
over the selection rather than the one book's size.

**My reading:** nothing is lost and nothing is ambiguous. The one thing I would
still change is that six rows reading `Mixed` in a column is visually flat —
`Mixed` could be dimmer than a real value — but that is taste, and the defect
was that they had no names.

## What is not here

- **A Google Books candidate.** Its shared anonymous quota was exhausted all
  day: HTTP 429 to all ten ISBNs of the proof run, from both hostnames and with
  either `country` parameter. Every picture here that says "Google Books
  answered 429" is honest and none of them shows what a Google Books candidate
  looks like beside an Open Library one.
- **A batch.** A multiple selection walks the books one at a time with a
  decision each; the sheet's header reads "Book 3 of 12" and Apply becomes
  "Apply 2 fields and Continue". Not photographed.
