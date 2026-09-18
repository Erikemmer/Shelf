# ADR 0014 – Deleting on a device happens only after a confirmation that names every file

*Status: accepted · 18 September 2026 · Sprint 5*

## The question

Sprint 5 gives Shelf the ability to write to a device. Reading a device's
contents means Shelf also knows which files are on it, and the obvious next
feature — "make the device match the library" — is one click away.

That click is how people lose books. Not through a bug: through a program doing
exactly what it was asked, to files the person had forgotten were only there.

## What was decided

**Three rules, and they are structural rather than a matter of care.**

1. **Deleting is its own menu item, and nothing else reaches it.** Not a sync,
   not a refresh, not a reconnect, not a transfer tidying up after itself.
   `DeviceDeletion` is not called from `TransferRunner` and cannot be: the
   runner has no reference to it and never removes anything but its own
   `.part` files.
2. **The confirmation names every file.** Not "214 files", not the first ten and
   an ellipsis: every one, by name, with the library book it belongs to where
   that is known. `DeviceDeletion.Confirmation.lines` builds that list in the
   core and a test checks its length equals the number of files.
3. **The library is never touched.** `DeviceDeletion` takes device paths and a
   volume. It has no library to touch, and a path that would leave the volume
   is refused rather than followed.

The sheet adds a fourth thing that is not a rule but a habit: a tickbox saying
the list was read, and a disabled button until it is ticked.

## Why

**A dialog that summarises can be agreed to by accident, and a dialog that
names cannot.** "Delete 214 files?" is a number; the mind checks it against
nothing. Two hundred and fourteen file names is a *list*, and a list is
something a person reads one line of and recognises.

**The fear this dialog answers is not the one it seems to.** Somebody deleting
from a device is not mainly worried about the device. They are worried that the
book will be gone from the library too — because in every other program that
syncs, it might be. So the sheet says what will *not* happen as plainly as what
will, in its second line, before the list.

**Shelf's whole claim is that it does not touch book files** (CONCEPT §1, §4).
This is the one place that claim has an exception, and an exception needs a
fence around it rather than a note in the documentation.

## Why a confirmation rather than the Trash

Orphaned folders in the *library* go to the Trash, where they can be dragged
back out (ADR 0001's sibling reasoning). A device has no Trash — FAT32 has no
such thing, and a `.Trashes` folder on a reader is a folder the reader will
happily show as a book. So on a device the deletion is real, and the
confirmation has to carry the whole weight.

## What this costs

The confirmation is long. A person deleting two hundred books scrolls a list of
two hundred names. That is the intended cost: deleting two hundred books should
not feel like deleting four.

## What was rejected

**"Sync device with library"**, in any form. It is the feature this ADR exists
to refuse. Every implementation of it deletes files as a side effect of an
operation whose name does not mention deleting.

**A count with a "show files" disclosure triangle.** The list has to be the
thing that is agreed to, not a thing that can be agreed to unopened.

**Undo.** There is nowhere to undo to. Saying "undo" over an operation that
cannot be undone would be worse than not offering it.
