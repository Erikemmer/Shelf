#!/usr/bin/env python3
"""Renders the CHANGELOG.md section for the version about to be released as
the plain HTML Sparkle's `generate_appcast` picks up as an update's release
notes (same filename as the archive, `.html` extension).

Shelf's CHANGELOG.md is not keyed by version (it reads "Sprint 14, Teil B",
not "[1.1.0-rc1]") — entries are written before a version number for that
work exists. So "the section for this version" is not found by matching a
version string; it is everything newest-first down to the last release's
own marker: an HTML comment, `<!-- shelf-release: v<version> · <date> -->`,
that `make release` inserts *below* whatever it just published, once
publishing succeeds (see Scripts/release.sh). The first one was backfilled
by hand at the v1.0.0/Sprint 9 boundary, in the same commit that added this
script.

Not a general Markdown renderer — just enough for this file's own style:
headings, bold, inline code, links, nested bullet lists, paragraphs. A
markdown table passes through as a paragraph per row rather than a real
<table> – good enough to read, not meant to be byte-identical to a full
CommonMark implementation.

Usage: changelog-notes.py <version> [changelog-path]
Prints HTML to stdout; exits 1 if no marker is found (nothing to bound the
section, which means either the marker was removed or this is the very
first release and the backfill above is missing).
"""

import html
import re
import sys

MARKER = re.compile(r"<!--\s*shelf-release:.*?-->", re.DOTALL)


def find_section(text: str) -> str | None:
    # The file opens with a title and a one-paragraph preamble before the
    # first "## " heading — that is never part of any release's notes.
    first_heading = re.search(r"^##\s", text, re.MULTILINE)
    if not first_heading:
        return None
    start = first_heading.start()
    marker = MARKER.search(text, start)
    if not marker:
        return None
    return text[start : marker.start()].strip("\n")


def inline(line: str) -> str:
    escaped = html.escape(line, quote=False)
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', escaped)
    return escaped


def render(section: str) -> str:
    lines = section.split("\n")
    out: list[str] = []
    in_list = False
    # A bullet's text wraps across indented continuation lines (this file's
    # own soft-wrap convention) rather than each line being its own bullet,
    # so those lines extend the current <li>/<p> instead of starting a new one.
    current: list[str] | None = None
    current_is_item = False

    def flush() -> None:
        nonlocal current, current_is_item
        if current:
            text = " ".join(inline(p) for p in current)
            out.append(f"<li>{text}</li>" if current_is_item else f"<p>{text}</p>")
        current = None
        current_is_item = False

    for raw in lines:
        stripped = raw.strip()
        if stripped.startswith("## ") or stripped.startswith("### "):
            flush()
            if in_list:
                out.append("</ul>")
                in_list = False
            level = 2 if stripped.startswith("## ") else 3
            text = stripped[level + 1 :]
            out.append(f"<h{level}>{inline(text)}</h{level}>")
        elif stripped.startswith("- "):
            flush()
            if not in_list:
                out.append("<ul>")
                in_list = True
            current = [stripped[2:]]
            current_is_item = True
        elif stripped == "" or stripped == "---":
            flush()
            if in_list:
                out.append("</ul>")
                in_list = False
        elif current is not None:
            current.append(stripped)
        else:
            current = [stripped]

    flush()
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: changelog-notes.py <version> [changelog-path]", file=sys.stderr)
        return 2
    version = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) > 2 else "CHANGELOG.md"

    with open(path, encoding="utf-8") as f:
        text = f.read()

    section = find_section(text)
    if section is None:
        print(
            "changelog-notes: no shelf-release marker found in "
            f"{path} – nothing bounds the section for {version!r}",
            file=sys.stderr,
        )
        return 1

    print(f"<h2>Shelf {html.escape(version)}</h2>")
    print(render(section))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
