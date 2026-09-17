# ADR 0009 – Calibre is read through a copy of `metadata.db`, and its WAL with it

Date: 2026-09-17 · Status: accepted

## Context

A Calibre library is a folder of books and one file that gives them meaning.
The folders can be walked; `metadata.db` is the only place the series, the
ratings, the custom columns and the reading history live, and it is the one
thing in that library that cannot be reconstructed from anything else. A
Calibre user who has lost it once keeps backups of it.

Somebody importing into Shelf has not stopped using Calibre. They are trying
Shelf *because* they still have the library, and Calibre may well be open in
the next window.

Opening somebody's live SQLite database is not free, even for reading. SQLite
takes locks. With a write-ahead log it may create `-shm` and `-wal` files that
were not there. A reader that crashes at the wrong moment can leave a hot
journal behind. None of those are likely, and all of them are somebody else's
library.

## Decision

1. **`metadata.db` is never opened in place.** `CalibreReader.read` copies it
   into a folder of its own under a cache directory the *caller* names, opens
   the copy, and removes the folder when the read is over. The Calibre folder is
   only ever read, and a test compares every file's size and modification date
   across a read to say so.

2. **The write-ahead log is copied with it.** `metadata.db-wal` and
   `metadata.db-shm` go along if they are there. Calibre uses WAL, so while
   Calibre is open the newest rows are *in the log and not in the database
   file*. A copy of the one file is the library as of the last checkpoint —
   which could be hours ago — and an import would then silently miss the newest
   books rather than failing. There is a test that holds a connection open the
   way Calibre does and checks the book in the log comes back.

3. **The copy is opened read-only** anyway. Nothing here has any business
   writing to a Calibre database, copy or not, and a reader that cannot write
   cannot write by accident.

4. **The cache directory is a parameter**, not a constant. `ShelfCore` builds on
   Linux, where `~/Library/Caches` does not exist; and a test that wrote into
   the real cache would be a test that can ruin a measurement somebody else is
   in the middle of (CLAUDE.md on that folder).

5. **An unknown schema version is a warning, not a refusal** (CONCEPT §13).
   Calibre raises `user_version` for changes that mostly do not touch the dozen
   tables read here, and a reader that refused every new version would break for
   everybody on the day Calibre shipped one. The sentence says what was found,
   what is known, and that the import will go ahead and report what it could not
   read.

6. **Every optional table is read through one helper** that turns "no such
   table" into a line in the report. A database with no book folders beside it
   — which is exactly what `Calibre Library Erik` in `~/Downloads` is — reads as
   a library whose files are missing, not as a failure.

## What this buys

* The source is provably untouched: 6 001 files, byte for byte identical across
  a dry run, an import and a resumed import (`CHANGELOG.md`, Sprint 3).
* Calibre can be running. That is the normal case, not the exception.
* A library that is odd in a way nobody anticipated still imports, and the
  report says what was odd.

## What it costs

* − A copy of `metadata.db`. On a large library that is tens of megabytes and a
  second or two; on Erik's it is the price of not touching the original.
* − The copy is made before anything is known about the library, including
  whether it is a Calibre library at all. A folder with no `metadata.db` is
  refused before any copying, which is the only cheap check there is.
* − Two reads of the same library — the counting protocol and the import — copy
  the database twice. They could share one copy; they do not, because a census
  somebody looked at ten minutes ago is not evidence about the library now.
