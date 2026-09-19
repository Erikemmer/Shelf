#!/usr/bin/env python3
"""Reads an accessibility tree dumped by `ax-dump.swift` and says what is wrong
with it.

A dump on its own is evidence nobody reads. This is the part that judges, so
`Scripts/ax-proof.sh` can fail rather than leave twelve text files for somebody
to compare by eye. Three faults, all of them ones this project has actually had:

1. **A control with no name.** A button, a checkbox, a text field, a slider or a
   menu button with no title, description or value is a control VoiceOver
   announces as nothing at all. Shelf's search field and cover-size slider were
   both in this state until Sprint 7.
2. **A name that is an SF Symbol's name.** `book.closed`, `arrow.down.doc`,
   `questionmark.folder`. SwiftUI falls back to the symbol's identifier when an
   `Image` is not hidden and not labelled, so the window announces a line of
   code. Every cover placeholder in the grid did this.
3. **A row of static text where something is meant to be pressed.** Not
   decidable from the tree in general — a heading is static text and should be
   — so it is reported per view only where the caller names a heading the view
   must contain (`--expect-button`).

Usage:
    ax-judge.py <dump file> [--expect-button TEXT]... [--expect TEXT]...

Exit code is 1 if anything failed, so a script can gate on it.
"""

import argparse
import re
import sys
from pathlib import Path

# The roles that are controls: something a person operates, so something that
# has to have a name. `AXUnknown` is deliberately not here — SwiftUI gives it
# to any custom element, including perfectly well-labelled ones.
CONTROL_ROLES = {
    "AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXSlider",
    "AXMenuButton", "AXPopUpButton", "AXTextArea",
}

# A scroll bar's parts are AppKit's own and carry no names by design; naming
# them is neither possible from SwiftUI nor useful.
SKIPPED_SUBROLES = {
    "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
    "AXCloseButton", "AXFullScreenButton", "AXMinimizeButton", "AXZoomButton",
    "AXSegment",
}

LINE = re.compile(r"^(?P<indent>\s*)(?P<role>\S+)(?: \[(?P<subrole>[^\]]+)\])?(?P<rest>.*)$")
FIELD = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')

# Two or more dot-separated lower-case words and nothing else: an SF Symbol
# name as SwiftUI writes it. A sentence never looks like this — it has spaces.
#
# At least one letter is required, or a slider's raw position (0.304347826…)
# reads as a symbol name. That was the first thing this script found, and it
# was wrong about it.
SYMBOL_NAME = re.compile(r"^(?=[a-z0-9.]*[a-z])[a-z0-9]+(\.[a-z0-9]+)+$")


def elements(text):
    for number, line in enumerate(text.splitlines(), start=1):
        match = LINE.match(line)
        if not match or not line.strip():
            continue
        fields = dict(FIELD.findall(match.group("rest") or ""))
        yield number, match.group("role"), match.group("subrole"), fields, line.strip()


def judge(text, expect_buttons, expect_present):
    failures = []
    names = []
    button_names = []
    for number, role, subrole, fields, line in elements(text):
        spoken = fields.get("title") or fields.get("desc") or fields.get("value")
        if spoken:
            names.append(spoken)
        if role == "AXButton" and spoken:
            button_names.append(spoken)
        for key in ("title", "desc", "value", "valueDescription"):
            value = fields.get(key)
            if value and SYMBOL_NAME.match(value):
                failures.append(f"line {number}: announces an SF Symbol's name “{value}” — {line}")
        if role in CONTROL_ROLES and subrole not in SKIPPED_SUBROLES and not spoken:
            failures.append(f"line {number}: a {role} with no name — {line}")

    for wanted in expect_present:
        if not any(wanted in name for name in names):
            failures.append(f"nothing in the tree is called “{wanted}”")
    for wanted in expect_buttons:
        if not any(wanted in name for name in button_names):
            failures.append(f"“{wanted}” is in the tree but not as a button a keyboard can press")
    return failures


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dump")
    parser.add_argument("--expect-button", action="append", default=[])
    parser.add_argument("--expect", action="append", default=[])
    arguments = parser.parse_args()

    text = Path(arguments.dump).read_text(encoding="utf-8")
    failures = judge(text, arguments.expect_button, arguments.expect)
    name = Path(arguments.dump).name
    if not failures:
        print(f"ax-judge: {name}: nothing unnamed, nothing announcing a symbol's name")
        return 0
    print(f"ax-judge: {name}: {len(failures)} finding(s)")
    for failure in failures:
        print(f"  - {failure}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
