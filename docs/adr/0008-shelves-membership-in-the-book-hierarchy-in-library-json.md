# ADR 0008 – Shelves: membership in the book, hierarchy in `library.json`

Date: 2026-09-17 · Status: accepted

## Context

A shelf is the one thing a library knows that a book file does not. Nothing in
an EPUB says "this is on the Sci-Fi shelf"; it is a decision somebody made about
their collection, and it exists only because Shelf recorded it.

That puts it in tension with ADR 0001, *the folder is the truth and the index is
a cache*. Everything else Shelf shows can be rebuilt by walking the folders and
reading each `metadata.opf`. If shelves lived only in the index, the index would
stop being a cache — deleting it would cost the user an evening's arranging, and
"you can always rebuild it" would quietly become false.

There are two separate things to store, and they are not alike:

1. **Which shelves a book is on.** A fact about that book.
2. **What shelves exist, what is inside what, and in what order.** A fact about
   the library, and one that survives having no books on it at all.

CONCEPT §5.1 already names the answer for the first — `<meta name="shelf:shelves">`
in each book's OPF — and §5.2 names `library.json` for the second. This ADR
writes down why, and what follows from it, because Sprint 2c is where both stop
being placeholders.

## Decision

**A book carries its own shelves.** `Book.shelves` is a list of *stored paths*
(`Fiction/Sci-Fi`), written into that book's `metadata.opf` as a JSON array in
`<meta name="shelf:shelves">`, exactly like every other field of the book.

**`library.json` carries the shape.** The shelves themselves — name, parent,
position — live in the library descriptor, as `[Shelf]`.

**The index holds both, and is the authority for neither.** It resolves a book's
paths against its own `shelves` table when the book is written, and a path with
no shelf behind it is *skipped, not invented*.

**A shelf's name may not contain `/`.** Refused at the point of naming, with a
sentence saying why.

## Why

1. **It keeps the index a cache, and it is provable.** `Scripts/shelf-proof.sh`
   deletes `library.sqlite` and rebuilds from the folders: every book is back on
   its shelf, and the shelf that had no books on it is back from `library.json`.
   Two tests do the same thing headlessly, including the case where
   `library.json` has been lost and only the books remember — a library restored
   from a backup without its `.shelf` folder. There, the shelf is *created* from
   what the books say, because the book said where it stands and the folder is
   the truth.

2. **Membership in the `Book` rather than beside it buys everything else for
   nothing.** It was beside it until this sprint — a value that `OPFDocument`,
   the rebuilder and the editor each passed along by hand — and moving it in
   gave shelves, in one change: `MetadataChange.Field.shelves`, so a shelving is
   undoable; the existing "write the file, then the index" order, so the folder
   stays the truth; and editing across a multiple selection, which would
   otherwise have needed a second path through all of it.

3. **A path is a name, not a pointer, and that is a cost paid deliberately.**
   Nothing in `Fiction/Sci-Fi` says *which* shelf it is, so renaming `Fiction`
   has to rewrite every book that said `Fiction` and every one that said
   `Fiction/Sci-Fi` — and leave `Fictional Places` alone. `ShelfEdit`
   (`pathsAfterMoving`, `pathsAfterRemoving`) does that, matching whole segments,
   with tests.

   The alternative was to store a UUID per book and keep the names only in
   `library.json`. It renames for free. It was not taken because a UUID in a
   `metadata.opf` is unreadable to a person and meaningless to any other
   program: a library opened by Calibre, or read in a text editor, or restored
   without its `.shelf` folder, would show `shelf:shelves="["7f3a…"]"` and
   nobody could tell what it meant. The path is legible, and legibility is the
   reason the OPFs carry anything at all.

4. **The separator is a slash, and a name may not contain one.** `Fiction/Sci-Fi`
   must mean one thing. Escaping was the alternative: `Crime\/Mystery` is
   lossless, and it is a rule invisible in the file that every future reader of
   it would have to know. Refusing the character costs one sentence at the
   moment of naming, and that sentence can explain itself.

5. **An empty shelf is a real thing.** Somebody makes "To Read" before putting
   anything on it. No book can remember that shelf, so only `library.json` can —
   which is the clearest single argument for keeping the shape in a file of its
   own rather than deriving it from what the books happen to say.

6. **The index invents nothing.** A book whose OPF names a shelf the index has
   not been given is filed nowhere rather than on a shelf conjured up in the
   cache. A shelf that exists only in the index is one `library.json` never
   hears about, and two authorities that disagree is the failure this whole
   arrangement exists to prevent. The *rebuild* may create shelves — but it
   writes them into `library.json` in the same breath.

## Consequences

* **A rename touches every book on the shelf.** Renaming a shelf with 400 books
  on it writes 400 small files. That is the price of legible paths, and it is
  one undo step. Measured at 5 000 books: one shelving costs about 2 ms
  including the index, so 400 is under a second.
* **A shelf path is case-insensitive when read back.** `ShelfTree.shelf(atPath:)`
  and the index's own lookup both fold case, so an OPF edited by hand, or a
  library copied between a case-sensitive and a case-insensitive disk, still
  finds its shelf.
* **Selecting a shelf shows what is inside it too.** `Fiction` shows the books on
  `Fiction/Sci-Fi`; a shelf whose books all live in its children would otherwise
  read as empty, which is not what a bookcase does. The sidebar's counts follow
  the same rule, so the number and the list agree.
* **Calibre is unaffected.** It ignores `<meta name>` entries it does not know,
  which is what makes it safe to write this into a library Calibre also reads.
* **"Reorganize Library…" (ADR 0007) is unaffected.** Shelves are not folders;
  moving a book between shelves never moves a file.
