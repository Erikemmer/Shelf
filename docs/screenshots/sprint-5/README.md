# Sprint 5 – devices, and what each picture is evidence of

Taken on 18 September 2026 on Erik's Mac (macOS 15.6) by `Scripts/device-shot.sh`,
against a synthetic 413-book library under
`~/Library/Caches/Shelf/measure-library-5/` and four e-readers made out of
`hdiutil` disk images by `Scripts/device-images.sh`. Every image here was looked
at before it was committed; the notes below say what was seen.

**What these pictures are not.** The "readers" are disk images, so no real
device was plugged into this Mac. What that costs is set out in
`docs/BACKLOG.md` under "To check on real hardware", and it is not a small list:
a real USB device, a cable pulled mid-transfer, and a real `KoboReader.sqlite`
are all still unproven.

**And one thing the pictures had to work around.** The app sandbox grants
`files.removable-volumes` for real removable media and **not** for a mounted disk
image: with the entitlement in place the app could read an image's name and free
space and could *not* list its directory, so a card with five books on it showed
"0 books". So these shots use `Device ▸ Treat Volume as Device ▸ Kindle…`, where
choosing the volume in an open panel is what the sandbox takes as permission.
That is a real route a person has — it is the way in for a reader Shelf does not
recognise — but it means **no picture here shows a device found by its marker
alone.** That is the first line of the hardware list.

## The pictures

| File | What it shows |
|---|---|
| `devices-sidebar.jpg` | The sidebar scrolled to the bottom: `KINDLE · 212 books · 36.5 MB free` with its eject button, and `tolino · 0 books · 62.5 MB free` under it. |
| `devices-transfer-sheet.jpg` | The counting protocol before a byte moves. |
| `devices-report.jpg` | What the finished transfer says for itself. |
| `devices-contents.jpg` | Everything on the card, and which book of the library each file is. |
| `devices-delete-confirmation.jpg` | The confirmation that names every file. |

### devices-sidebar.jpg

Two readers, each with the number of books Shelf recognises on it and the room
left, and an eject button on the row. The grid behind it carries the other half
of the feature: the small device badge in the top-left corner of the covers that
are on the Kindle, and not on the ones that are not.

### devices-transfer-sheet.jpg

The line that matters is `212 books · AZW3 206 · MOBI 3 · PDF 3 · 201 cannot be
sent · 25.5 MB`, over the device's own sentence — "A Kindle does not read EPUB
over USB". Below it, each book with the format chosen for it and the path it
will get: `AZW3 · documents/Becky Lefèvre - A Desolation #164.azw3`. Nothing has
been written at this point.

The 201 that cannot be sent are the comics and the EPUB-only books; they are
named in the list further down, which this screenshot does not reach — the
summary line says how many, and the list says which, which is the division the
sheet is built on.

### devices-report.jpg

`Verified · 212 books · Skipped: 201 · Failed: 0`, and "Verified" means what it
says: each of those 212 was read back off the card and its digest compared with
the source's. The last line says where the report is kept — on the device, in
`.shelf/Send-Report.txt`, so a card carried to another Mac still says what is on
it and how it got there.

### devices-contents.jpg

Every file on the card, with its size and how Shelf knows which book it is —
"sent by Shelf" here, because the manifest names them; a file somebody else put
on the card reads "matched by name". This is also the only place `Delete from
Device…` can be reached from, and the button is disabled until something is
ticked: choosing the files is part of deleting them.

### devices-delete-confirmation.jpg

`Delete 4 files from “KINDLE”?` over the sentence that answers the fear this
dialog exists for — "Your library is not touched — the books stay in it, and can
be sent again" — and then **every file by name**, with the book it belongs to.
Four here; it would be four hundred lines for four hundred files, because a
dialog that summarises is a dialog that can be agreed to by accident. The
tickbox and the greyed-out button are the second deliberate act.
