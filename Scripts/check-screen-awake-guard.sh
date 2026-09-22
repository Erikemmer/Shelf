#!/bin/bash
# Checks that no script under Scripts/ can capture a window or read the
# accessibility tree without having called `require_awake_screen`
# (Scripts/screen-awake.sh) first.
#
# The twin of the "stale build" finding, not a new class of mistake: a
# locked screen makes `screencapture -l <window id>` return the window's
# *last drawn frame* — shot after shot byte-identical — and makes the
# accessibility tree degenerate to an application element containing only
# itself, so `ax-dump.swift`, `cell-point.swift` and `menu-point.swift` all
# answer "nothing" rather than failing (`docs/BACKLOG.md`, Sprint 2c,
# "The Mac's screen lock silently breaks every window-driven script").
# Both look exactly like success. `Scripts/screen-awake.sh` already exists
# and every script that needs it already calls it — this is what stops the
# next one from being the exception, the same way
# `Scripts/check-shelf-guard.sh` and `Scripts/check-current-app-guard.sh`
# already do for their own two guards, run inside `make lint` on every
# commit rather than remembered.
#
# A grep, not a parser — see Scripts/check-shelf-guard.sh's own doc comment
# for why that is enough here. A script captures a window or reads the
# accessibility tree the moment it calls `screencapture`, or runs
# `ax-dump.swift`, `cell-point.swift` or `menu-point.swift`. If such a line
# appears in a script that never calls `require_awake_screen`, or calls it
# only after that line, this fails and names the file and the line.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

for script in "$HERE"/*.sh; do
    name="$(basename "$script")"
    # The guard's own file: it defines require_awake_screen, it does not
    # call it, and its doc comments quote the trigger patterns without
    # meaning them.
    [ "$name" = "screen-awake.sh" ] && continue
    # This script's own file, and the other two lint checks': all three
    # quote trigger patterns as plain text inside their own pattern-matching
    # logic, never as a real call, and none has reason to mention
    # require_awake_screen.
    [ "$name" = "check-screen-awake-guard.sh" ] && continue
    [ "$name" = "check-shelf-guard.sh" ] && continue
    [ "$name" = "check-current-app-guard.sh" ] && continue

    guard_line=0
    trigger_line=0
    n=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n + 1))
        lead="${raw%%[![:space:]]*}"
        trimmed="${raw#"$lead"}"
        case "$trimmed" in
            '#'*) continue ;;
        esac

        if [ "$guard_line" -eq 0 ]; then
            case "$trimmed" in
                *require_awake_screen*) guard_line=$n ;;
            esac
        fi

        if [ "$trigger_line" -eq 0 ]; then
            case "$trimmed" in
                *screencapture* | *'ax-dump.swift'* | *'cell-point.swift'* | *'menu-point.swift'*)
                    trigger_line=$n
                    ;;
            esac
        fi
    done <"$script"

    if [ "$trigger_line" -gt 0 ]; then
        if [ "$guard_line" -eq 0 ]; then
            echo "screen-awake: Scripts/$name:$trigger_line captures a window or reads the" >&2
            echo "  accessibility tree but never calls require_awake_screen" >&2
            FAILED=1
        elif [ "$guard_line" -gt "$trigger_line" ]; then
            echo "screen-awake: Scripts/$name:$trigger_line captures a window or reads the" >&2
            echo "  accessibility tree before the guard at line $guard_line" >&2
            FAILED=1
        fi
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "screen-awake: every script under Scripts/ that captures a window or reads the" >&2
    echo "  accessibility tree must call require_awake_screen (Scripts/screen-awake.sh)" >&2
    echo "  before it does — a locked screen makes both look like success." >&2
    exit 1
fi

echo "screen-awake: every script that captures a window or reads the accessibility tree checks for a locked screen first."
