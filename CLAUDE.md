# CLAUDE.md – project rules for Shelf

Read `Programmier-Leitlinie.md` first; it is binding. This file adds the
project-specific part.

## What this is
macOS-only eBook manager in the look and feel of **Selector**: a modern-looking
Calibre. Library, metadata, Calibre import, devices – **no reader, no format
conversion** in v1.0. Core logic in the Swift package `ShelfCore` (UI-free,
builds on Linux), UI in `App/Shelf` (SwiftUI + AppKit) on top of the shared
`SlateKit` package. Concept: `docs/CONCEPT.md`. Architecture:
`docs/ARCHITECTURE.md`.

## The rules that are not negotiable
- **A book file is never written, deleted or overwritten** in v1.0. Metadata
  goes into `metadata.opf` next to the book and into the index – never into the
  book (CONCEPT §4, "Won't").
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

The package is shared with Selector and has two sessions working on it. Three
rules, all of them paid for.

- **Never work in `~/Documents/SlateKit`.** That is the Selector session's
  working copy. Commit `6e4f2ec` was made there and swept up a change of
  Selector's that happened to be lying uncommitted in the same tree
  (`SlateShortcuts.swift`, +8 lines: the shortcut sheet's VoiceOver column
  order). `git add -A` cannot tell whose work it is looking at.

  This session works in its own worktree:

      git -C ~/Documents/SlateKit worktree add ~/Documents/SlateKit-shelf -b shelf/work

  If that fails because of somebody else's uncommitted changes, touch nothing
  there and `git clone https://github.com/Erikemmer/SlateKit ~/Documents/SlateKit-shelf`
  instead. Before every SlateKit commit: `git status --short` and
  `git diff --stat`, and stage **files by name** — never `git add -A`.

- **An existing component keeps its previous look in the default.** What is new
  arrives as an option the host asks for (`SlateChip(style:)`,
  `SlateStarRating(label:)`). The two apps are pinned to different versions on
  purpose; raising a pin for one fix must not redraw a second thing. What cannot
  be made compatible goes in SlateKit's `CHANGELOG.md` under **Breaking**, with
  the reason. A tag is never moved — 0.3.0 stays where it is and the correction
  is 0.3.1.

- **The package is bilingual, whatever this app is.** Selector ships German;
  Shelf is English until Sprint 7. Every string SlateKit draws *itself* has an
  English and a German entry in `Localizable.xcstrings`, and a test fails if one
  is missing. Strings Shelf hands in as parameters ("Mixed", "Add series…") are
  Shelf's own and are translated when Shelf is.

The route for a change: work in the worktree, `make test && make lint &&
make contrast`, commit, tag, push the branch to `main` and push the tag, then
raise `exactVersion` in `project.yml` here and run the four checks.


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
