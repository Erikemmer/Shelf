# ADR 0016 – The core answers in English; the window translates

*18 September 2026. Status: accepted.*

## Context

CONCEPT §3.4 says the interface is English first and German in Sprint 7, and
that identifiers stay English. This is that sprint.

Three things had to be decided before a single word was translated, and two of
them were decided by things that went wrong rather than by preference.

## Decision

### 1. One catalogue, keyed by the English sentence

`App/Shelf/Resources/Localizable.xcstrings`, 429 entries, English and German,
eight of them with plural variations. The **key is the sentence itself**, so the
source still reads as what a person sees and a lost translation falls back to
the English rather than to a key.

One exception, and it is written as an exception: where English has one word
for two things German has two — "Series" is the row above a book's series name
(*Serie*) and the row counting how many series a Calibre library holds
(*Serien*). Those keys carry the place in brackets and the English beside it
(`Loc.contextual`). There are two of them.

### 2. Every drawn word goes through `Loc`, including the plain ones

The first plan was to leave `Text("Add Books…")` alone, because SwiftUI treats a
literal as a `LocalizedStringKey` and localises it for nothing. Two things
killed it:

- **`Text("one " + "two")` is a `String`, not a key**, and is drawn verbatim and
  never translated. A dozen of Shelf's help texts are whole sentences written
  across two lines with a `+`. They would have stayed English in a German
  window, silently, and the source looks exactly like the ones that work.
- **An interpolated key is built by the compiler out of the interpolation's
  *types*** — `Text("Book \(n) of \(m)")` has the key `%1$lld of %2$lld` — so
  no test can check that the catalogue holds it, because no test can read it off
  the source.

Going through a function makes both impossible. The key is a plain literal a
test can read, and a value is a printf argument rather than part of the key.

### 3. ShelfCore stays UI-free, so it answers in English and the window says it

The core is Linux-buildable and has no bundle, no catalogue and no locale
(ADR 0003). It keeps its English — the language every identifier in this project
is in — and `Loc.core` looks that English up in the window's catalogue.

Where a core sentence has a **value** in it, that does not work: "“2,5x” is not
a number" is a sentence no catalogue can hold a key for. Those became decisions
rather than sentences — `BookFieldRejection` and `ShelfEdit.Rejection` were
already enumerations with the value attached, and `SeriesPosition` gained a
`Place` beside its `text`. The core says **which** thing is true and with what;
the window says it in words. The English wording stays in the core for
`shelf-tool` and the tests.

### 4. Reports stay English, deliberately

`Import-Report.txt`, `Transfer-Report.txt` and the readers' own warnings are not
window text. They are evidence: `Scripts/proof-run.sh` greps them, four
screenshot scripts wait for the word "Verified" in the accessibility tree, and
every measurement in `CHANGELOG.md` was read out of one. Translating them would
turn a run's evidence into something that depends on who ran it.

`ByteCount.format` is the same decision one level down: it formats in the C
locale because it writes those reports. The window has `Loc.size`, which is
`FormatStyle` and the reader's locale — 134,5 kB on a German Mac and 134.5 kB on
an English one.

### 5. Numbers, dates and sizes come from `FormatStyle`, never from `String(format:)`

`String(format:)` without a locale formats in the C locale. That is the Selector
lesson — a German Mac's `ps` writes "64,4" and shell arithmetic then fails on
every comparison — in the one place it can still bite an app. `Loc.string`
therefore uses `String.localizedStringWithFormat`, which is also the call that
resolves a catalogue's plural variations.

### 6. Four tests, because none of the three failures is visible

A missing entry draws in English. A missing German draws in English. A literal
that never reached `Loc` draws in English. All three look exactly right in an
English window, and SlateKit lost its whole German this way in 0.3.0 while
building, running and looking correct.

`LocalisationTests` therefore reads the **repository**:

1. every entry has a German translation, and one still marked `new` does not
   count;
2. every entry has an English one — which is how "1 books" was found and fixed;
3. every `Loc.…("…")` key in `App/Shelf` is in the catalogue;
4. every sentence the core can answer with is in the catalogue, walked out of
   the core's own `CaseIterable` enumerations rather than listed, so an eighth
   `BookField` fails this the day it is added;
5. and the blunt one: **no sentence anywhere in `App/Shelf` is drawn without
   going through `Loc`.**

Number five is the one that matters, and it exists because the first German run
came out with an English sidebar: `SlateSidebarRow` takes its title as the first
argument, which was on no list of call shapes, so seven smart collections and
six section headings stayed English while every other word turned over. A test
that only checks what it is shown cannot see that. This one starts from the
other end and asks about every literal in the app.

What is not window text is named in the test, by file or by literal — the log,
the readers' diagnostics, defaults keys, a sort sentinel — which is a list
somebody has to add to deliberately.

## Consequences

- A new sentence costs two lines: `Loc.string("…")` at the call site and an
  entry in the catalogue. Forgetting the second fails a test.
- The catalogue is the source of truth for both languages. It is a JSON file
  Xcode's string-catalogue editor opens, and it is also readable and diffable as
  text.
- `Info.plist` names both languages (`CFBundleLocalizations`). Without `de` a
  German Mac is handed the development region and the catalogue is never asked.
- German is proved by pictures, not by the tests: `Scripts/german-shots.sh`
  starts Shelf in German **through its own defaults domain**, not the Mac's, and
  puts the language back however the run ends. Looking at those pictures is what
  found "Informationen ein-/ausblenden" wrapping onto two lines in the ⌘? sheet.

## What this does not cover

- **The device profiles' `note`** (`ShelfCore/Devices/Profiles/*.json`) is data
  and is still English. Translating it means translating a data file, which is a
  different decision from translating a program.
- **A library's own words are never translated** — a tag, an author, a series, a
  shelf. Only a collection's name is a word Shelf chose, and only that is looked
  up (`LibraryBar.filterTitle`).

## Alternatives not taken

- **Letting SwiftUI localise the literals.** Decision 2 says why not.
- **A catalogue in `ShelfCore` too.** It would give the core a bundle and a
  locale, which is exactly what the Linux job exists to prevent, and it would
  translate the reports as a side effect.
- **Keys like `inspector.rating.label`.** Readable source is worth more here
  than a tidy namespace, and a key that is the sentence gives a fallback that is
  still a sentence.
