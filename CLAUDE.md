# CLAUDE.md – project rules for Shelf

Read `Programmier-Leitlinie.md` first; it is binding. This file adds the
project-specific part.

## What this is
macOS-only eBook manager in the look and feel of **Selector**: a modern-looking
Calibre. Library, metadata, Calibre import, devices – **no reader, no format
conversion** in v1.0. Core logic in the Swift package `ShelfCore` (UI-free,
builds on Linux), UI in `App/Shelf` (SwiftUI + AppKit) on top of the
`SlateKit` package — Shelf's own since 22 September 2026, no longer shared
with Selector. Concept: `docs/CONCEPT.md`. Architecture:
`docs/ARCHITECTURE.md`.

## The rules that are not negotiable
- **A book file is never written, deleted or overwritten *by accident* — never
  by a routine metadata edit.** Until Sprint 10 this line read, without
  qualification, "a book file is never written, deleted or overwritten in
  v1.0", and that stayed true right up to Schritt E2 of that sprint. It fell
  once, deliberately, with a date (21 September 2026) and a reason, not
  quietly: `docs/adr/0021-metadata-and-a-cover-may-be-written-into-an-epub.md`
  allows an EPUB's own file to be written **on explicit instruction only** —
  "Write into the Book File", reachable nowhere else, gated by preflight (is
  it an EPUB? DRM-free? on a writable volume?), a confirmation naming every
  book and every field old → new, a verified rewrite before anything is
  displaced, and the original to the Trash — never `removeItem`, never
  undone by ⌘Z, because the Trash *is* the way back. A rating, a tag, a
  shelf, a move — every other write in Shelf still goes only into
  `metadata.opf` next to the book and into the index, never into the book
  itself (CONCEPT §4, "Won't"; §12).
- **A Calibre folder is only ever read**, and `metadata.db` through a copy in
  `~/Library/Caches/Shelf/`.
- **The folder is the truth; the index is a cache.** It can be deleted and
  rebuilt at any time (`docs/adr/0001-folder-is-the-truth.md`). Everything that
  cannot be rebuilt from the folders is mirrored into the OPFs.
- **DRM is never removed or worked around.** It is detected, badged, and the
  file is left alone (CONCEPT §12).
- **Deleting on a device only after a confirmation that names every file.**
- **Copy, verify, then trust**: every copy is hashed on both sides before it
  counts (`docs/adr/0002-copy-verify-then-trust.md`).
- Test material is synthetic and generated (`make synthetic`). No borrowed book
  goes into this repository.
- Cache and test-output path: `~/Library/Caches/Shelf/` – **never** under
  `~/Documents`, which is synced.
- **In `~/Library/Caches/Shelf/` a session deletes only what it created itself
  and named as created in its own report.** Everything else stays, however much
  it looks like leftovers: measurements from an earlier sprint, a library
  somebody is comparing against, a half-finished proof run. In doubt, a new
  folder name with the sprint or the date in it – `measure-library-2b/` – rather
  than `rm -rf`. The path is outside the synced folder so that large test
  material is *allowed* there, not so that it is disposable.
- The former company name appears nowhere in this project.

## Stack & conventions
- Swift 6, strict concurrency. `@MainActor` view models, `actor` for background
  services, `Sendable` value types in the core.
- Identifiers in English; UI strings in English (German in Sprint 7); comments
  explain *why*.
- Small functions (~40 lines, ≤ 3 indentation levels), one job per type/file.
- Reference data (formats, shortcuts, device profiles, articles for sorting) as
  tables or enums, not `if` chains.
- Never import AppKit, ImageIO or PDFKit in `ShelfCore`. The Linux CI job is the
  guard rail that enforces this.
- The only external dependency in the core is GRDB.swift. Anything else needs a
  reason in an ADR.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`).

## Workflow for every change
1. Say the goal in one sentence, list files to touch and risks; ask only if a
   real decision is open.
2. Read the affected code and tests first. Run `make test` before changing.
3. Small runnable steps.
4. **Before every commit: `make test && make app && make lint && make smoke`.**
   All four green, or it is not committed – a red step is fixed, never skipped.
5. **`make smoke` is not optional after `make app`.** A green build says nothing
   about a SwiftUI view that invalidates itself: the app starts, pins a core and
   never shows a window. The smoke test opens the app and checks that a window
   exists and the CPU settles. It caught exactly that in Selector.
6. **Never end a process you did not start.** Xcode, `debugserver`, an app
   instance Erik launched with ⌘R – ask first, even when ending it looks
   harmless and obviously right. Processes this session started are its own to
   clean up.
7. **Commit before experimenting.** Before a bisection or any "let's try
   reverting X", save the current state as a WIP commit on a branch. Never
   overwrite uncommitted work with `git checkout` or `git stash` – a stash that
   has been popped is gone.
8. Every change ships with tests and updated docs (`CHANGELOG.md`, and
   `docs/ARCHITECTURE.md` / `docs/DATA-MODEL.md` / a new ADR when relevant).
9. `git status --short` before `git add -A`. `git push` after every finished step.
10. Finish with a short plain-language summary: what changed, why, what to check,
    and explicitly what could not be verified.
11. **A release tag is set only when Erik says so, by name, in a prompt** —
    not "never", and not inferred from a version number being right or a
    session calling itself a closing one. `v1.0.0` was set this way, on
    `4b5856c`, with the exact commands given in the prompt that set it. The
    same holds for every tag after it.

## Lessons carried over from Selector
- **`make smoke` reads the CPU in the C locale.** `ps` formats numbers in the
  user's locale: on a German Mac it says "64,4", shell arithmetic then errors on
  every comparison, and a healthy app is reported as broken.
- **Build outside `~/Documents`.** `SCRATCH` is `~/Library/Caches/Shelf/build`:
  the sync attaches Finder metadata to freshly built files and codesign then
  refuses the test bundle.
- **The cover cache is on disk from Sprint 1**, not retrofitted later. Selector
  paid a sprint for learning that the second time a folder opens has to be fast.
- **SlateKit is used through a tag, never a path.** Otherwise an afternoon's
  work in SlateKit silently changes what this app builds and what its tests ran
  against.

## Working on SlateKit

**SlateKit belongs to Shelf alone now.** Erik said so on 22 September 2026:
Selector pulled its own copy and no longer builds against this package, so
the section below, which held until that date, is retired — kept here,
struck through in spirit rather than deleted, because the reasons it
existed are worth remembering if a package is ever shared again.

- ~~**Never work in `~/Documents/SlateKit`.**~~ That was the Selector
  session's working copy, and commit `6e4f2ec` made there once swept up a
  change of Selector's lying uncommitted in the same tree
  (`SlateShortcuts.swift`, +8 lines) — `git add -A` cannot tell whose work
  it is looking at. Work in `~/Documents/SlateKit` directly now; the
  worktree at `~/Documents/SlateKit-shelf` (branch `shelf/work`) is fully
  merged into `main` and no longer needed, kept only until Erik confirms it
  can go. Still good practice regardless of who else is or is not sharing
  the tree: `git status --short` and `git diff --stat` before a commit,
  and stage **files by name** rather than `git add -A`.

- ~~**An existing component keeps its previous look in the default.**~~
  That existed because two apps were pinned to different versions on
  purpose, and raising a pin for one fix must not redraw a second thing.
  With one app left, breaking a component's look or its API outright is
  Erik's own words — "brich, was du willst" — no longer gated behind an
  opt-in default. Still worth a `CHANGELOG.md` entry under **Breaking**
  when it happens, so the reason survives the commit that made it. A tag
  is still never moved — 0.3.0 stays where it is, a correction is 0.3.1.

- ~~**The package is bilingual, whatever this app is.**~~ That was for
  Selector's German while Shelf was still English. Shelf carries its own
  German now (`App/Shelf/Resources/Localizable.xcstrings`), so whether
  SlateKit's own strings still need both languages is Shelf's call alone —
  not decided here, since nothing has asked to drop either yet.

**Erik's own suggestion, not yet done:** fold SlateKit into this repo as a
local target (`ShelfUI`), so Shelf needs no second repo, then archive
`Erikemmer/SlateKit` on GitHub. A real restructuring — imports everywhere
SlateKit is used, `Package.swift`, `project.yml`, a decision on how (or
whether) to carry the package's own history across — worth its own plan
when Erik asks for it, not a side effect of an unrelated change.

The route for a change, tag pinning included: `make test && make lint &&
make contrast`, commit, tag, push `main` and the tag, then raise
`exactVersion` in `project.yml` here and run the four checks.


## Environment notes
- Xcode project is generated from `project.yml` (XcodeGen). Edit the YAML, never
  the `.xcodeproj`.
- `make smoke` needs permission to automate System Events *only* when it is
  given a library to open. Without the permission it still measures the welcome
  screen, and says so.
- `ShelfCore` and its tests run on Linux in CI, which needs `libsqlite3-dev`
  for GRDB's system-library target.

## Roadmap (short)
Sprint 0 SlateKit (done, in Selector) → **1 scaffolding & EPUB** → 2 metadata
editing, shelves, search → 3 Calibre import → 4 MOBI/AZW3/PDF/CBZ/CBR →
5 devices → 6 online metadata → 7 polish, German, notarisation → **v1.0**.
Details in `docs/CONCEPT.md` §11 and `docs/BACKLOG.md`.
