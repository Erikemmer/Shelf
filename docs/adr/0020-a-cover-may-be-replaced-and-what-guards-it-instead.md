# ADR 0020 – A cover may be replaced, and what guards it instead of a refusal

Date: 2026-09-19 · Status: accepted · Reverses part of CONCEPT §4 ("Could")

## Context

`OnlineCover`, from Sprint 6, refused to write over a cover that was already
there. Its own words:

> **Only on an explicit action, and only when the file has none**
> (CONCEPT §4, "Could"). Never as a side effect of taking over a field, and
> never over a cover that is already there — a person who put their own scan
> in the folder did that on purpose.

That was the right rule *for what existed then*, and the reason it was right is
the part worth keeping: a cover is often the one thing in a book's folder a
person made themselves, and Sprint 6 had no way to get it back. There was no
undo for a cover, the replaced file would have gone to `removeItem`, and the
only protection available was to not do it.

The cost was invisible until somebody used the program. A cover could be
fetched **once per book, ever**, and never corrected. An import that took the
picture out of the wrong one of a book's four formats was permanent. A cover
that came down as a placeholder stayed a placeholder. For a library manager
that is not a careful rule, it is a hole: the most obvious thing a person wants
to do to a book's picture is change it.

## Decision

**A cover may be replaced, from any of four places** — a file chosen in the
open panel, a picture dropped on the inspector, the book's own file, and the
net — and the refusal is replaced by four guards that did not exist in
Sprint 6:

1. **The old file goes to the Trash**, through `FolderDisposal`, the same seam
   an emptied author folder goes through (ADR 0018). A disposal that *cannot*
   take it means nothing is written at all. Shelf does not overwrite a cover
   and never gains the ability to.
2. **⌘Z puts the previous picture back**, byte for byte, because the bytes are
   captured before anything moves and ride on the window's undo stack. Undoing
   the *first* cover on a book takes the file away again, so the folder and the
   book cannot end up saying different things.
3. **The person sees the picture before it replaces anything.** The download
   path has drawn a preview since Sprint 6; what changed is the button under
   it, which now reads **Replace Cover** rather than *Use This Cover* when
   there is something to replace. The evidence is above the button and the
   warning is in it.
4. **Bytes that are not a picture are refused** before the old cover is
   touched — a service answering an HTML error page with a 200, or a text file
   dropped by mistake.

`OnlineCover` is deleted. It was the second place in the program that decided
what putting a cover beside a book means, and the two had already drifted:
`CoverFile`'s own documentation says one place must decide, "because two places
would eventually disagree and a book would show no cover while its cover sat
right there." `CoverReplacement` is that place now, and the download goes
through it like everything else — which is also how it gets the Trash, the
generation and the undo without a second implementation.

## What is explicitly no longer true

- **"Never over a cover that is already there."** Gone. A cover can be replaced
  as often as anybody likes.
- **`OnlineCover.Refusal.coverAlreadyThere`.** Gone with it. There is no state
  in which Shelf declines to change a cover because one exists.
- **"The cover action applies only to books with no cover."** `Download
  Cover…` offers itself for every book.

What is *not* reversed, and is worth saying because this ADR could be misread
as loosening things generally:

- A book file is still never written, deleted or overwritten (CONCEPT §4,
  "Won't"). A cover lands beside the book and nowhere else.
- Nothing is deleted outright. The replaced picture is in the Trash, where a
  person can look at it and drag it back.
- No cover is ever written as a *side effect*. Every one of the four paths is
  something somebody asked for by name.

## The three tests that went with `OnlineCover`

Named, because a deleted test is a claim nobody is checking any more:

| Deleted | Replaced by |
|---|---|
| "a cover is written beside the book, named from its own bytes" | `CoverReplacementTests`: "a book that had no cover at all starts at generation 1 like any other" and "a new cover in another format does not leave the old one beside it" — same claim, and the second one is stronger, because it also checks that nothing else is left in the folder. |
| "a cover that is already there is not written over" | **Nothing, deliberately.** This is the rule being reversed. What stands in its place is not a test but the four guards above, two of which *are* tested: "the cover that was there goes to the disposal, not to removeItem" and "a disposal that fails means nothing is written and nothing is lost". |
| "what is not an image is not written at all" | `CoverReplacementTests`: "bytes that are not a picture are refused before anything is displaced", which additionally proves the old cover survives the attempt, and "whether bytes could be a cover is answerable without writing anything". |

## Consequences

- \+ The most obvious gap in the program is closed, and closed in one place, so
  all four ways in behave the same and are undone the same.
- \+ A cover fetched from the net is now an ordinary edit: same undo, same
  "write the file, then the index", same name in the Edit menu.
- \− The undo stack holds the previous picture in memory, a few hundred
  kilobytes per step. That is the price of restoring a file that has gone to
  the Trash without digging in the Trash for it. The pictures are capped at
  `CoverImageRule.maxEdgePixels` before they get there.
- \− Somebody can replace the wrong book's cover. They can also undo it, see
  the old one come back, and find the replaced file in the Trash. That is the
  trade this ADR is making, and it is the trade every other editable field in
  Shelf already makes.
