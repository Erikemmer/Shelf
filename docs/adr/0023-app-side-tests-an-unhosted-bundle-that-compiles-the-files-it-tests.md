# ADR 0023 – App-side tests: an unhosted bundle that compiles the files it tests

Date: 2026-10-11 · Status: accepted

## Context

`ShelfCoreTests` is the only test target and runs on Linux, so nothing that
needs ImageIO or AppKit could be tested. `CoverImage` was the first case
(`docs/BACKLOG.md`, Sprint 9): the rule was tested, the carrying out — measure,
scale, re-encode, HEIC and TIFF — had only `Scripts/cover-shot.sh` as evidence.

Two shapes were possible for an Xcode unit-test bundle:

1. **Hosted** (`TEST_HOST` = Shelf.app, `@testable import Shelf`). Every run
   starts the whole app — window, Sparkle, the library it last opened. The
   project has a guard against exactly that (`Scripts/no-foreign-shelf.sh`,
   `make smoke`'s refusal) and a test run would need to be exempt from it.
2. **Unhosted**, with the files under test listed as sources of the test
   bundle itself.

## Decision

**Unhosted.** `ShelfAppTests` (`project.yml`, `App/ShelfTests/`) compiles
`App/Shelf/Services/CoverImage.swift` and `App/Shelf/Views/Strings.swift`
(for `Loc`) directly and depends on `ShelfCore` only. No app starts, no window
exists, nothing touches a library.

- `make test` runs `swift test` and then `make test-app`
  (`xcodebuild test -only-testing:ShelfAppTests`, derived data under
  `$(SCRATCH)/xcode-tests`). `make test-core` runs the first half alone.
- `ShelfCore` stays free of ImageIO and AppKit; no new dependency.
- Test pictures are drawn in memory (CoreGraphics/ImageIO), never stored.

## Consequences

- The pattern for future app-side tests: **a file is testable here if it
  imports only Foundation, system frameworks and `ShelfCore`**; add it to the
  bundle's `sources`. A file that reaches into SwiftUI view models or other app
  files either gets split (decision in the core, execution in the app — as
  `CoverImageRule`/`CoverImage` already are) or, if that is unreasonable, is
  the day a hosted bundle is justified in its own ADR.
- `Bundle.main` in the test bundle is the test runner, so `Loc` answers in
  English; localisation is not what these tests check.
- Linux CI does not run this target. A macOS CI job running `make test-app`
  is the follow-up (`.github/workflows/ci.yml`).
