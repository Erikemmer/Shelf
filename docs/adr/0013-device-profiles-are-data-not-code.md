# ADR 0013 – A device profile is data, not code

*Status: accepted · 18 September 2026 · Sprint 5*

## The question

Shelf has to know four things about an e-reader before it can send a book to it:
how to recognise the volume, where books go on it, which formats it can open,
and which of those to prefer. CONCEPT §8.1 gives that as a table of four
devices.

A table of four devices is a `switch` somebody could write in an afternoon. The
question is what happens on the day there is a fifth — or on the day a Kobo
firmware moves its database, or a PocketBook model turns out to want `books/`
rather than `Books/`.

## What was decided

**One JSON file per device in `Sources/ShelfCore/Devices/Profiles/`, read at
runtime through `Bundle.module`.** Nothing about a device is compiled in.

```json
{
  "id": "kindle",
  "name": "Kindle",
  "markers": ["system", "documents"],
  "volumeNames": [],
  "booksFolder": "documents",
  "formats": ["azw3", "mobi", "pdf"],
  "preferredFormats": ["azw3", "mobi", "pdf"],
  "fileNamePattern": "{author} - {title}",
  "readBack": "fileList",
  "note": "A Kindle does not read EPUB over USB. …"
}
```

A file that will not decode is **left out and named**, never a crash: a profile
somebody edited by hand and broke must cost its own device and nothing else.
`DeviceProfiles.Loaded.failures` carries the reason.

## Why

Three reasons, in the order they matter.

**A device changes without Shelf changing.** Formats, folder names and firmware
are somebody else's decisions, taken on somebody else's schedule. Everything
else in this program describes files Shelf itself writes, and can be corrected
when Shelf is. A profile cannot.

**It is the same argument the rest of the program already makes.** The formats
table, the shortcut list, the articles for sorting and the PDF producer names
are all reference data rather than `if` chains, for the reason the Leitlinie
gives: a row is checkable and a branch is not. A device profile is the same
shape of thing, one step further out — so far out that it leaves the binary.

**It is the only version of this that a user can fix.** A `switch` means a
release, a notarisation and a download for a folder name. A file means a person
with an unusual reader can make it work this afternoon, and send the file back.
That is not offered in the interface in v1.0 — the profiles ship inside the app
bundle — but the mechanism is the one that allows it, and choosing a `switch`
now would be choosing against it.

## What this costs

`Bundle.module` means the target has resources, which means the app bundle
carries `ShelfCore_ShelfCore.bundle`. Checked: the four profiles are in the
built `Shelf.app`, and they load on Linux in CI as well, so the same files
answer in both places.

It also means a profile can be **wrong at runtime** in a way a `switch` cannot.
That is why a bad file is a named failure rather than an empty list, and why
`DeviceTests` loads a folder of deliberately broken JSON and checks that the
good profile beside it still arrives.

## What was rejected

**A `switch` in Swift with the four devices in it.** Simplest to write, and it
makes every one of the three reasons above impossible.

**Profiles in `library.json`.** They are not about a library — the same Kobo is
the same Kobo whichever library is open — and putting them there would mean a
person with two libraries maintains two copies.

**Downloading profiles.** A v1.0 that phones home for a folder name is a v1.0
that needs a privacy policy and an offline story for a feature that works
offline. The file layout allows it later; nothing is built for it now.
