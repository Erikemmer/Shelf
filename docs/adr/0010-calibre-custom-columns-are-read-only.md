# ADR 0010 – Calibre's custom columns: values in the book, shape in the library, read-only

Date: 2026-09-17 · Status: accepted

## Context

Calibre lets a user invent columns: `#read_date`, `#owned`, `#shelf_note`,
`#pages`. People who have kept a library for ten years have several, and they
are often the reason the library is theirs rather than a pile of files — a
rating anybody can re-enter, "when I read it" nobody can.

CONCEPT §4 puts them under *Should*: import them and show them, **read-only in
v1.0**.

Three questions had to be answered: where the values live, where the
definitions live, and whether Shelf may write into Calibre's own OPF meta.

## Decision

1. **The values are a field of the book** (`Book.customValues`, label → rendered
   text) and go into each book's `metadata.opf`. The folder is the truth
   (ADR 0001), so anything the folders cannot hold is mirrored into them, and a
   rebuild gets them back. The index's `custom_values` is a cache of that.

2. **The definitions are the library's** and live in `library.json`
   (`customColumns`: the label, the name, the kind). Exactly the split the
   shelves have (ADR 0008): what exists belongs to the library, what a book has
   belongs to the book. A column somebody imported and then emptied survives
   there for the same reason an empty shelf does — no book can remember it.

   It follows that **a rebuild must save the columns before the books**, as it
   already saves the shelf tree first. Without that a rebuilt library kept every
   value and lost every name, and the inspector had nothing to label them with.
   Found by rebuilding one.

3. **One meta, `shelf:custom`, holding a JSON object.** Not one meta per column,
   for the two reasons `shelf:shelves` is one meta holding an array: `<meta
   name=…>` is looked up by name, so a column called `read` would collide with
   Shelf's own field; and a label is free-form text that a joined string cannot
   carry back.

4. **Calibre's own `calibre:user_metadata:#…` metas are left exactly as found.**
   That meta carries *Calibre's* JSON — the column's whole definition, display
   options and all — and writing a bare value into it would be a Shelf library
   claiming to be a Calibre one and then lying about the shape. They are carried
   through unread, like every meta Shelf does not model.

   This is where a promise the documentation had already made turned out to be
   false. `OPFDocument` treated the whole `calibre:` *prefix* as understood, so
   `calibre:user_metadata:#read_date` counted as modelled and was dropped on the
   next write. The known metas are named individually now — eight of them — so
   adding one to the reader and adding it to that list are the same edit.

5. **Read-only, and the reason is not laziness.** Shelf knows what a column is
   called and what kind Calibre said it was, and nothing at all about what
   belongs in one: whether `#owned` means the paper copy, what a `#read_date`
   with no date means, what an enumeration's legal values are. A field Shelf
   cannot validate is a field Shelf should not let anybody type into — and a
   library that goes back to Calibre must find them as it left them.

6. **A datatype this Shelf has never heard of is a line in the report**, with
   the other columns imported around it (CONCEPT §13). A `composite` column is
   skipped with the same breath: Calibre computes it from a template, so there
   is no stored value anywhere to read.

## What this buys

* An import is lossless in the way that matters: 8 000 values over 2 000 books,
  in the folders, in the index, and back after the index is thrown away.
* Nothing Shelf does not understand is destroyed. A round trip through Shelf
  leaves a Calibre library's own metas where they were.
* Sprint 6's "write them too" is a change of controls, not a migration.

## What it costs

* − `Book` has a dictionary nothing can edit, and `MetadataEditor` carries it
  across every change for the same reason it carries the identifiers.
* − The rendered text is a one-way form. A date is stored as a full ISO-8601
  stamp and shown in the reader's region; `2.0` is stored as `2`. Making them
  editable later means deciding what each kind's *value* is, which is the work
  this decision defers rather than avoids.
* − Two places hold the shape: `library.json` and the index's `custom_columns`.
  The second is a cache of the first, and a rebuild is what keeps them in step.
