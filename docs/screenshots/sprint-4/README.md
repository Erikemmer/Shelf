# Sprint 4 – the pictures, and what each one is evidence of

Taken on 17–18 September 2026 on Erik's Mac (macOS 15.6), against synthetic
libraries under `~/Library/Caches/Shelf/measure-library-4/`. Every image here
was looked at before it was committed; the notes below say what was seen.

## The app icon

| File | What it shows |
|---|---|
| `icon-in-dock.jpg` | Shelf's icon in the Dock, between Apple Books and Firefox. |
| `icon-window-and-dock.jpg` | The whole screen: the welcome window and the Dock. |

At 16 px the two shelf boards and the coloured spines still read as a bookcase;
the individual books merge into bands of colour, which is what that size can
carry.

**One thing the pictures nearly did not show.** The first launch after the build
drew the generic placeholder in the Dock. The bundle was already right —
`AppIcon.icns` present, `CFBundleIconFile` and `CFBundleIconName` both `AppIcon`
— and LaunchServices was serving the icon it had cached from every earlier
build, when the icon set held nothing but a `Contents.json`. `lsregister -f`
clears it.

## Folders no book points at

Made by `Scripts/orphan-shot.sh` against a library whose import was killed after
210 of 260 books.

| File | What it shows |
|---|---|
| `orphans-found.jpg` | `Library ▸ Find Orphaned Folders…`: ten folders, 2.4 MB, each with its title, its path, its file count and whether it still holds a book file. Everything ticked; nothing done. |
| `orphans-confirm.jpg` | The second step: **every file named** — the `.epub`, the `cover.png`, the `metadata.opf` of each folder — "10 folders, 29 files, 2.4 MB", and the sentence "They go to the Trash, not away". |
| `ax-orphans-found.txt`, `ax-orphans-confirm.txt` | The accessibility tree of both, so the text can be read without the image. |

The script stops at the confirmation and presses nothing. Putting a few hundred
files into somebody's Trash as a side effect of taking a screenshot is not a
screenshot script's business.

## The formats

Made by `Scripts/formats-shot.sh`. The import is driven **through the window**
rather than through `shelf-tool`, because the tool has no PDFKit and a PDF it
imported would have no cover — a picture of the tool's limitation rather than of
the app's behaviour.

| File | What it shows |
|---|---|
| `formats-plan.jpg` | The counting protocol before anything is copied. |
| `formats-report.jpg` | Afterwards: "Verified · 65 files · 23 new books · 42 new formats · 1 skipped", 4.6 MB, 24 imported with something missing. |
| `formats-drm-grid.jpg` | Three protected books in the grid, each badged **Kindle DRM**. |
| `formats-inspector-drm.jpg` | One of them selected, with the inspector open. |
| `formats-inspector-many.jpg` | **The one to look at.** One book, four files: EPUB 134.5 KB, AZW3 133.0 KB, MOBI 133.0 KB, PDF 783 B, each with its own file name, and `Add Format…` under them. |
| `formats-cbr.jpg` | A CBR's row, saying what this Mac can do with it: "libarchive 3.7.4, reading RAR and RAR5." |
| `formats-quicklook.jpg` | Quick Look over a PDF (␣): the page itself, rendered. |
| `ax-formats-*.txt` | The accessibility trees behind them. |

### What these pictures are not

* **No genuine CBR was read.** A RAR is a proprietary compressed format and this
  Mac has no tool that can write one, so the `.cbr` in the screenshot library is
  a ZIP under that name. It proves the route in — libarchive opens it, the pages
  sort, the cover comes out, the inspector names the version — and it does not
  prove that a real RAR5 comic parses.
* **No genuinely protected file was read.** The fixtures *announce* protection
  (`META-INF/encryption.xml`, EXTH 209) without being encrypted, which is what
  Shelf's claim about DRM actually needs: it reads the flag and stops
  ([ADR 0012](../../adr/0012-drm-is-recognised-and-nothing-else.md)).
* **The covers are synthetic.** The grey gradients are `MinimalPNG`'s, not book
  covers.

### Three things these pictures caught

Worth recording, because each was a green test run and a wrong picture:

1. **The app crashed on the first CBR it was ever shown.** SIGSEGV in
   `rar5_cleanup`: `LibArchive` registered the RAR5 reader twice, once through
   `archive_read_support_format_all` and once by name, and libarchive's error
   path for a second registration dereferences a null context.
2. **A book with four files on disk showed three in the inspector.** Adding a
   format to a book the library *already* had built a fresh entry holding only
   the new file, and the index took that as the whole truth.
3. **Quick Look of a comic drew a brown book icon.** CBZ was on the list of
   formats macOS previews usefully, on the theory that it would show as an
   archive. It does not. The list is `[.pdf]` now.
