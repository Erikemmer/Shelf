#!/usr/bin/env python3
"""Renders the release notes for the version about to be released, from
`docs/RELEASE-NOTES.md` — not `CHANGELOG.md`, which stays the technical,
developer-facing log. See the top of that file for why they are separate.

Three outputs, all from the same `## <version>` section:
- no `--lang`: both languages, German first — the GitHub release page
  (no per-viewer language there) and the appcast's own unlabelled
  `<description>`, which is what Sparkle falls back to when it cannot
  match the system language to a `sparkle:releaseNotesLink`.
- `--lang de` / `--lang en`: one language alone, plain prose with no
  language heading — these become `sparkle:releaseNotesLink[xml:lang]`
  siblings of the zip (Sprint 16, Teil B), which Sparkle's own
  `bestNodeInNodes:name:` picks between by the system's language.

Exits 1, loudly, when the version has no section — `make release` must
stop rather than publish with the previous version's text or none at all.

Usage: changelog-notes.py <version> [--lang de|en] [--path docs/RELEASE-NOTES.md]
Prints HTML to stdout.
"""

import argparse
import html
import re
import sys

LANGUAGE_HEADINGS = {"de": "Deutsch", "en": "English"}


def find_version_section(text: str, version: str) -> str | None:
    heading = re.search(rf"^## {re.escape(version)}\s*$", text, re.MULTILINE)
    if not heading:
        return None
    start = heading.end()
    next_heading = re.search(r"^## ", text[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(text)
    return text[start:end].strip("\n")


def find_language_subsection(section: str, language_heading: str) -> str | None:
    heading = re.search(rf"^### {re.escape(language_heading)}\s*$", section, re.MULTILINE)
    if not heading:
        return None
    start = heading.end()
    next_heading = re.search(r"^### ", section[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(section)
    return section[start:end].strip("\n")


def inline(line: str) -> str:
    escaped = html.escape(line, quote=False)
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    escaped = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', escaped)
    return escaped


def render_paragraphs(text: str) -> str:
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    return "\n".join(f"<p>{inline(' '.join(p.split()))}</p>" for p in paragraphs)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("path", nargs="?", default="docs/RELEASE-NOTES.md")
    parser.add_argument("--lang", choices=sorted(LANGUAGE_HEADINGS), default=None)
    args = parser.parse_args()

    with open(args.path, encoding="utf-8") as f:
        text = f.read()

    section = find_version_section(text, args.version)
    if section is None:
        print(
            f"changelog-notes: no “## {args.version}” section in {args.path} – "
            "add the release's own What's New text before running make release",
            file=sys.stderr,
        )
        return 1

    if args.lang:
        subsection = find_language_subsection(section, LANGUAGE_HEADINGS[args.lang])
        if subsection is None:
            print(
                f"changelog-notes: “## {args.version}” in {args.path} has no "
                f"“### {LANGUAGE_HEADINGS[args.lang]}” subsection",
                file=sys.stderr,
            )
            return 1
        print(render_paragraphs(subsection))
        return 0

    print(f"<h2>Shelf {html.escape(args.version)}</h2>")
    for lang in ("de", "en"):
        subsection = find_language_subsection(section, LANGUAGE_HEADINGS[lang])
        if subsection is None:
            print(
                f"changelog-notes: “## {args.version}” in {args.path} has no "
                f"“### {LANGUAGE_HEADINGS[lang]}” subsection",
                file=sys.stderr,
            )
            return 1
        print(f"<h3>{LANGUAGE_HEADINGS[lang]}</h3>")
        print(render_paragraphs(subsection))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
