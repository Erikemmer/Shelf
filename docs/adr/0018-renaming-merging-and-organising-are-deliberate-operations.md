# ADR 0018 – Renaming, merging and organising are deliberate operations with a preview

Date: 2026-09-19 · Status: accepted ·
Supersedes [ADR 0007](0007-a-metadata-change-does-not-rename-the-folder.md)

## Context

ADR 0007 answered one question — *when somebody corrects "Ancilary" to
"Ancillary", does the folder follow?* — and answered it **no**. Everything it
gave for that answer is still true, and this ADR keeps all of it. The identity
is the UUID and not the path; a rename is the one file operation that can lose
a book; it would happen at the worst possible moment, as a side effect of a
keystroke; and a batch makes it worse rather than better.

What ADR 0007 did *not* decide, and was read as deciding, is whether Shelf ever
moves a folder at all. Its own text names the way out — "Renaming becomes a
separate, deliberate command — **Reorganize Library…**, with a preview of every
move and a report afterwards" — and then leaves it in the backlog, where it sat
through seven sprints. In the meantime the absence turned into a working
assumption: Shelf does not touch folders.

Trying the program is what found the hole, and it is not about tidiness. Shelf
is supposed to *order* a collection that grew over years. Today it can only do
that in the window. If the same person stands in the library as
"Sebastian Fitzek", "Fitzek, Sebastian" and "S. Fitzek", those are three
authors in the sidebar, three folders on the disk, and three of everything
anywhere else — and every one of Shelf's answers is correct, because every one
of those three strings really is a different string. A library manager that
can only ever agree with the mess is not managing anything.

There is a second half to it, and it is the one the guideline cares about most
(*Leitlinie*, principle 3: no lock-in, every database fully exportable). A
library that lives in Shelf's layout, with Shelf's OPFs, should be able to walk
out of Shelf at any moment without losing what was maintained in it. That is
an export, and until now it was a "Should" nobody had built.

## Decision

**Two things that were one thing are now two.**

1. **Nothing is ever renamed as a side effect.** Editing a title, an author, or
   anything else writes `metadata.opf` and the index, and leaves the path
   exactly where it is. This is ADR 0007, unchanged and still binding, and it
   is the default the program ships with.

2. **Renaming, merging and organising are commands.** Each one is asked for by
   name, shows what it would do before it does anything, and has a way back.
   They are `Rename…`, `Merge into…` and `Organize Library…`.

Between them sits one switch, in the settings: **"Keep folders in step with
metadata changes"**, and it is **off by default**. With it on, a metadata change
queues the book for an organise rather than doing one — so even then nothing
moves inside a keystroke. It is off by default because a path can be referenced
from outside the program: a script, a hardlink backup, a Finder alias, a
Time Machine exclusion. Somebody who has those must not be surprised, and
somebody who has none of them can say so once.

**What a deliberate operation has to have**, all three of them:

* **A preview that is the plan.** The list of `old → new`, the number already
  in the right place, every collision, and everything it cannot touch — and the
  value shown is the value executed, exactly as `ImportPlan` and `TransferPlan`
  already work (ADR 0002, decision 6). There is no second computation that
  could differ from the one the person agreed to.
* **A way back.** A rename or a merge is a metadata change and goes on the undo
  stack as one step, named for what it did: `Undo Merge Authors (37 books)`.
  An organise moves folders, which the undo stack is the wrong place for — it
  has a manifest and its own `Undo Organize` instead, built from that manifest.
* **The import's guarantees, because it is the import's kind of risk.** Hash
  before and after, a manifest written as the run goes on, resume after an
  interruption, no leftovers, and nothing overwritten (ADR 0002).

**What does not change, and is not negotiable:**

* **A book file is never written, never overwritten, never deleted.** An
  organise moves *folders*. The bytes inside them are not touched, and the
  digest taken before the move and after it is what says so.
* **Nothing is deleted outright.** What has to go goes to the Trash — and that
  is a rule about the *mechanism*, not only about the intent. The one folder an
  organise makes go away is an author folder it has itself just emptied, and it
  goes through `FolderDisposal`, which on a Mac is `FileManager.trashItem`.
  There is no `removeItem` on that path, which is what a test asserts by
  handing the runner a disposal that moves nothing and then finding the folder
  still on the disk. A folder is worth little; being able to look in the Trash
  and see what a command did is worth a great deal.

  What counts as emptied is `EmptiedFolder`, a pure rule tested on Linux: the
  folder must hold nothing but the file system's own residue. An **allow-list**
  of names, never "anything beginning with a dot" — a dot file is how a great
  many programs keep something that matters, and `.gitignore` next to
  `.DS_Store` must be the difference between keeping the folder and not.
* **Shelf never guesses which spellings are the same person.** There is no
  similarity detection, no "we found 12 probable duplicates", no automatic
  merge. A merge is a selection somebody made.

## Why no automatic detection of similar spellings

This is the decision inside the decision, and it was made deliberately rather
than deferred.

A fuzzy matcher over author names is easy to write and its failures are
expensive and quiet. "Kim Stanley Robinson" and "Kim Robinson" may be one
person or two. "J. Smith" matches a dozen Smiths. Two spellings that differ by
one letter are usually a typo and sometimes a father and a son. The cost of
getting it right is a list the user has to read anyway; the cost of getting it
wrong is 40 books filed under a name that never existed — and because the merge
writes 40 OPFs, undoing it is a second bulk write rather than a non-event.

So the rule is: **Shelf never chooses; it executes a choice and shows its
work.** The user selects the spellings, picks the target, and sees the count
before pressing anything. That is slower for a library with a hundred variants
and it is the only version of this feature that can be trusted with a
collection somebody spent years on.

This leaves a door open on purpose, and CONCEPT §11 names it as a wish rather
than a plan: a local model, or an interface to a service like Claude, could
*propose* spellings, duplicates and covers. The shape that makes that safe is
already here — a proposal fills the same preview list a person fills by hand,
and the confirmation stays where it is. A suggester never gets to touch a file.

## Why the folder is still not the identity

Worth saying plainly, because this ADR moves folders and ADR 0007's first
argument was that the path carries no identity.

It still carries none. `dc:identifier opf:scheme="uuid"` in each OPF is what
makes a rebuild reconstruct a library rather than reinvent it, and an organise
changes no UUID. That is precisely what makes moving folders *safe* rather than
what makes it unnecessary: a library caught mid-organise, by a crash or a power
cut, is a library where some books are at their old path and some at their new
one — and a rebuild from the folders finds all of them either way, on their
shelves, with their ratings. The index is a cache before the run and a cache
after it.

## Consequences

* **The folder tree becomes something a person can rely on again**, which is
  what makes an export, a backup by hand, and Calibre's own importer useful.
* **A library that is never organised behaves exactly as it did.** Every
  default here is the Sprint 7 behaviour.
* **There is now a code path that moves a book's folder**, and it is the first
  one in this project. Everything else is a copy or a read. That is why the
  proof run kills it mid-flight and compares every checksum afterwards, and why
  `docs/RUNBOOK.md` gained a section for it.
* **ADR 0007 is not deleted and is not wrong.** Its reasoning is the reason the
  switch is off by default. It is superseded only in its silence about the
  deliberate case.

## Addendum – 24 September 2026, Sprint 18, Teil C2

**The door this ADR left open is now open, on Erik's explicit instruction, for
authors and publishers only.** "Shelf never guesses which spellings are the
same person" still stands as the default and as the *execution* path — this
addendum adds a *suggester*, exactly the shape imagined above: `SimilarSpellings`
proposes groups into the same preview a person already fills by hand for
`Merge into…`, and the accepted groups are carried out by `NameEdit.replacing`,
the identical function that command already used. Nothing new writes a file;
the new code only decides which names to put in front of a person, and every
group can be unchecked before anything runs.

Two rules, both narrower than "similar enough":

* **The safe rule** — the exact fold `MergeMatching.swift`'s `AuthorNameFold`
  already uses for matching two books as the same work: case, accents,
  punctuation, word order. "Fitzek, Sebastian" and "Sebastian Fitzek" group;
  two different people never do, because nothing about their names folds the
  same way.
* **The riskier rule** — an initialed given name ("J. Ahlberg") against a full
  one sharing its surname, and *only* when exactly one full-name candidate
  exists **and** the two share a work (B3's own title+author match) or a
  series. Two candidates for the same initial, or no shared work or series at
  all, is left alone and counted, not guessed at — this is the one rule this
  ADR's own "J. Smith matches a dozen Smiths" warning is written about, and it
  is answered by requiring corroborating evidence, not by relaxing the match.

Publishers get only the narrower of the two rules that already existed
informally for them: case, whitespace, punctuation and a legal-form suffix
(GmbH, Verlag, KG, Ltd., Inc.) — never an editorial judgement about which
imprint belongs to which larger house.

The winning spelling is chosen, not asked for: the most complete display form
(never the initialed one, never the sort form "Surname, Given" over "Given
Surname"), the most frequent among ties. A person still sees it before
anything merges, and can reject any one group without rejecting the rest.
