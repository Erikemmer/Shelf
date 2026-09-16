# ADR 0004 – SlateKit is shared with Selector, through a tag

Date: 2026-09-16 · Status: accepted

## Context

Shelf is meant to look like Selector, not merely to be dark as well (CONCEPT
§3.1). "Similar" decays: two apps whose palettes and sidebar rows are written
twice drift apart within a sprint, and then the family resemblance is a thing
somebody has to maintain by eye.

Sprint 0 therefore moved Selector's look into its own package, **SlateKit**
(`~/Documents/SlateKit`, `github.com/Erikemmer/SlateKit`), and proved the move
changed nothing: four screens photographed before and after differ in zero of
3.3 million pixels, and two more in zero of 4 786 176 (see SlateKit's README).
That work happened in the Selector repository and is the reason Shelf could
start at all.

## Decision

1. **Shelf depends on SlateKit through a `exactVersion` tag**, never a path
   (`project.yml`: `exactVersion: 0.1.0`). A path dependency would mean an
   afternoon's work in the SlateKit working copy silently changes what this app
   builds and what its tests ran against.
2. **Changing the shared look is its own step**, in this order: change SlateKit,
   `make test && make lint` there, commit, tag, push with `--tags`, then raise
   `exactVersion` here and run the four checks. Both apps move deliberately or
   not at all.
3. **The line between the package and the app is one question:** *could the
   other app use this unchanged?* A row with an icon, a name and a count does
   not care what it is counting, so it lives in SlateKit. A cover grid cell that
   knows about DRM badges and read status does, so it stays here. Anything that
   would need `LibraryEntry` or `BookFileFormat` in its signature has failed the
   test.
4. **What is left in `App/Shelf/Views/Theme.swift`** is Shelf's own: the widths
   of the three columns, the 2:3 aspect ratio of a cover, and which SF Symbol
   stands for which sidebar section. Everything else reads `Slate.*`.
5. **Shelf does not add to SlateKit in Sprint 1.** The package as tagged was
   enough for the welcome screen, the sidebar, the grid cell, the inspector
   blocks, the status bar, the banner and the shortcut sheet. The first thing
   Shelf is likely to need is a table row style in Sprint 2, and that will be a
   change to SlateKit with a new tag, not a copy made here.

## Consequences

* + The two apps are siblings by construction. A change to the accent colour
  reaches both, when both ask for it.
* + Shelf's own view code is small: three columns, a grid cell, an inspector and
  a sheet, because the parts that are merely "how a dark app looks" are not
  here at all.
* − A change that both apps want costs three commits in two repositories and a
  version bump. That is the price of neither app being able to break the other
  by accident, and it is paid rarely.
* − Shelf is pinned to `0.1.0` and will stay there until something needs
  raising. A pin that is never raised is a pin that goes stale, so
  `docs/HANDOFF.md` names it as a thing to check.
* − Two apps sharing one package means a component can be shaped by whichever
  app needed it first. The question in decision 3 is the only defence, and it
  has to be asked every time.
