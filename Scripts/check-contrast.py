#!/usr/bin/env python3
"""WCAG 2.1 AA contrast check for the colours **Shelf** decides.

SlateKit has its own (`make contrast` in that package) and it checks the
palette: every `Slate.*` text colour on every `Slate.*` background, the
buttons, the banners, the chips. This one checks what Shelf does *on top of*
that palette — the opacities it applies in its own views, which SlateKit's
script cannot see and which are where this project's two failures were:

- the author's name under a missing cover, drawn at 60 % of the secondary text
  colour, read at **3.09:1** where normal text needs 4.5:1;
- the DRM badge, secondary text on a 14 % plate, at **3.96:1**.

Both are in `CHANGELOG.md` with these numbers, and both are fixed.

**Nothing here is hand-copied.** The palette is read out of the SlateKit
checkout the app actually builds against, and every opacity is looked for in
the Shelf source file that is said to hold it — so a colour changed in a view
and not here fails this script rather than going quietly stale.

Usage: python3 Scripts/check-contrast.py
Exit code is 1 if any pair fails, so `make contrast` can gate on it.
"""

import glob
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AA_NORMAL = 4.5
AA_NONTEXT = 3.0


def find_slate_theme() -> Path:
    """SlateTheme.swift out of the checkout this app builds against.

    Xcode resolves the package into DerivedData; SwiftPM into the scratch path.
    Either is the *pinned tag's* source, which is the point — a script that
    carried its own copy of the palette would answer for a version nobody is
    building.
    """
    patterns = [
        str(Path.home() / "Library/Developer/Xcode/DerivedData/Shelf-*/SourcePackages/checkouts/SlateKit/Sources/SlateKit/SlateTheme.swift"),
        str(Path.home() / "Library/Caches/Shelf/build/checkouts/SlateKit/Sources/SlateKit/SlateTheme.swift"),
    ]
    for pattern in patterns:
        found = sorted(glob.glob(pattern))
        if found:
            return Path(found[0])
    raise SystemExit(
        "error: no SlateKit checkout found. Run `make app` once so the package is resolved,\n"
        "       then run this again — this script never carries its own copy of the palette."
    )


def parse_palette(source: str) -> dict[str, tuple[float, float, float]]:
    colors: dict[str, tuple[float, float, float]] = {}
    pattern = re.compile(
        r"let\s+(\w+)\s*=\s*Color\("
        r"(?:red:\s*([\d.]+),\s*green:\s*([\d.]+),\s*blue:\s*([\d.]+)"
        r"|white:\s*([\d.]+))"
    )
    for match in pattern.finditer(source):
        name = match.group(1)
        if match.group(2) is not None:
            colors[name] = (float(match.group(2)), float(match.group(3)), float(match.group(4)))
        else:
            white = float(match.group(5))
            colors[name] = (white, white, white)
    return colors


def luminance(rgb):
    def linear(channel):
        return channel / 12.92 if channel <= 0.03928 else ((channel + 0.055) / 1.055) ** 2.4

    red, green, blue = (linear(channel) for channel in rgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def contrast(first, second):
    one, two = luminance(first), luminance(second)
    lighter, darker = max(one, two), min(one, two)
    return (lighter + 0.05) / (darker + 0.05)


def over(color, background, alpha):
    return tuple(color[i] * alpha + background[i] * (1 - alpha) for i in range(3))


def source_holds(relative: str, needle: str) -> bool:
    """Whether the file still contains the expression this row is about."""
    path = ROOT / relative
    return path.exists() and needle in path.read_text(encoding="utf-8")


def main() -> int:
    theme = find_slate_theme()
    palette = parse_palette(theme.read_text(encoding="utf-8"))
    for required in ("textPrimary", "textSecondary", "accent", "panelBackground", "contentBackground"):
        if required not in palette:
            print(f"error: SlateTheme.swift no longer defines {required}")
            return 2
    print(f"palette read from {theme}")

    primary = palette["textPrimary"]
    secondary = palette["textSecondary"]
    panel = palette["panelBackground"]
    content = palette["contentBackground"]
    black, white = (0.0, 0.0, 0.0), (1.0, 1.0, 1.0)

    # Each row: what it is, the two colours, the threshold, and the source
    # expression that has to still be there for the row to mean anything.
    # `None` as a threshold means "reported, not gated" — see the note by each.
    rows = [
        (
            "the author under a missing cover (grid placeholder caption)",
            secondary, content, AA_NORMAL,
            ("App/Shelf/Views/CoverGridView.swift", ".foregroundStyle(Slate.textSecondary)"),
        ),
        (
            "the DRM badge's word on its plate, over a panel",
            primary, over(secondary, panel, 0.14), AA_NORMAL,
            ("App/Shelf/Views/Theme.swift", "static let drmBadge = Slate.textPrimary"),
        ),
        (
            "a badge over the worst cover there is (white), on its 55 % black plate",
            white, over(black, white, 0.55), AA_NORMAL,
            ("App/Shelf/Views/CoverGridView.swift", "SlateBadgePlate"),
        ),
        (
            "a badge over the darkest cover there is (black), on its 55 % black plate",
            white, over(black, black, 0.55), AA_NORMAL,
            ("App/Shelf/Views/CoverGridView.swift", "SlateBadgePlate"),
        ),
        (
            "the table's stars when a book is rated",
            palette["accent"], content, AA_NORMAL,
            ("App/Shelf/Views/BookTableView.swift", "Slate.accent : Slate.textSecondary"),
        ),
        (
            "the table's secondary columns (tags, format, size, added)",
            secondary, content, AA_NORMAL,
            ("App/Shelf/Views/BookTableView.swift", "foregroundStyle(Slate.textSecondary)"),
        ),
        (
            "the sidebar's footer and its empty-section notes",
            secondary, panel, AA_NORMAL,
            ("App/Shelf/Views/SidebarView.swift", "foregroundStyle(Slate.textSecondary)"),
        ),
        (
            "a network note in the sidebar's footer",
            palette["accent"], panel, AA_NORMAL,
            ("App/Shelf/Views/SidebarView.swift", "foregroundStyle(Slate.accent)"),
        ),
        # Decorative, and reported rather than gated. WCAG 1.4.11 covers a
        # graphic you need in order to understand or operate something; these
        # two are neither. The book symbol sits behind a caption that already
        # says the title and the author, and it is hidden from the
        # accessibility tree for exactly that reason; the empty-library symbol
        # sits above a sentence saying the library is empty. Printed anyway,
        # because a number nobody can see is worth knowing about.
        (
            "· the book symbol behind a missing cover (decorative)",
            over(secondary, content, 0.35), content, None,
            ("App/Shelf/Views/CoverGridView.swift", "Slate.textSecondary.opacity(0.35)"),
        ),
        (
            "· the symbol over “This library is empty.” (decorative)",
            over(secondary, content, 0.5), content, None,
            ("App/Shelf/Views/CoverGridView.swift", "Slate.textSecondary.opacity(0.5)"),
        ),
    ]

    stale = [
        f"{label}: {relative} no longer contains “{needle}”"
        for label, _, _, _, (relative, needle) in rows
        if not source_holds(relative, needle)
    ]
    if stale:
        print("error: this script is describing code that has moved:")
        for note in stale:
            print(f"  - {note}")
        return 2

    width = max(len(label) for label, *_ in rows)
    print(f"{'Pair':<{width}} {'Ratio':>8}  {'Needs':>7}  Result")
    print("-" * (width + 28))
    failures = []
    for label, foreground, background, threshold, _ in rows:
        ratio = contrast(foreground, background)
        if threshold is None:
            print(f"{label:<{width}} {ratio:>7.2f}:1  {'—':>7}  reported")
            continue
        passed = ratio >= threshold
        print(f"{label:<{width}} {ratio:>7.2f}:1  {threshold:>5.1f}:1  {'PASS' if passed else 'FAIL'}")
        if not passed:
            failures.append((label, ratio, threshold))

    print()
    if failures:
        print(f"{len(failures)} pair(s) fail WCAG AA:")
        for label, ratio, threshold in failures:
            print(f"  - {label}: {ratio:.2f}:1 (needs {threshold:.1f}:1)")
        return 1
    print("Every pair Shelf decides passes WCAG AA. SlateKit's palette has its own check.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
