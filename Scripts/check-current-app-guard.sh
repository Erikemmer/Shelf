#!/bin/bash
# Checks that no script under Scripts/ can start a Shelf instance without
# first verifying, through `verify_shelf_app_is_current`
# (Scripts/current-shelf-app.sh), that the bundle it found is actually built
# from this repository's current HEAD.
#
# The same shape Scripts/check-shelf-guard.sh already has for
# `require_no_foreign_shelf`, for the same reason: a rule that lives only in
# a doc comment does not stop the next script from skipping it. This runs
# inside `make lint` on every commit rather than being remembered.
#
# A grep, not a parser — see Scripts/check-shelf-guard.sh's own doc comment
# for why that is enough here. A script starts a Shelf instance the same way
# that one already detects (`open -a "$APP"`, `open -a Shelf`, or executing
# `Contents/MacOS/Shelf` directly). If such a line appears in a script that
# never calls `verify_shelf_app_is_current`, or calls it only after the
# launch, this fails and names the file and the line.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

for script in "$HERE"/*.sh; do
    name="$(basename "$script")"
    # The check's own file: it defines verify_shelf_app_is_current, it does
    # not call it, and its doc comments quote the launch pattern without
    # meaning it.
    [ "$name" = "current-shelf-app.sh" ] && continue
    # This script's own file, and the other lint check's: both quote the
    # exact same launch patterns as plain text inside their own
    # pattern-matching logic, never as a real launch, and neither has
    # reason to mention verify_shelf_app_is_current.
    [ "$name" = "check-current-app-guard.sh" ] && continue
    [ "$name" = "check-shelf-guard.sh" ] && continue

    guard_line=0
    launch_line=0
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
                *verify_shelf_app_is_current*) guard_line=$n ;;
            esac
        fi

        if [ "$launch_line" -eq 0 ]; then
            case "$trimmed" in
                *'open -a "$APP"'* | *'open -a Shelf'*) launch_line=$n ;;
                *'Contents/MacOS/Shelf'*)
                    case "$trimmed" in
                        *'-x '*) ;; # an existence check, not a launch
                        *) launch_line=$n ;;
                    esac
                    ;;
            esac
        fi
    done <"$script"

    if [ "$launch_line" -gt 0 ]; then
        if [ "$guard_line" -eq 0 ]; then
            echo "current-shelf-app: Scripts/$name:$launch_line starts a Shelf instance but never calls verify_shelf_app_is_current" >&2
            FAILED=1
        elif [ "$guard_line" -gt "$launch_line" ]; then
            echo "current-shelf-app: Scripts/$name:$launch_line starts a Shelf instance before the check at line $guard_line" >&2
            FAILED=1
        fi
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "current-shelf-app: every script under Scripts/ that starts a Shelf instance must" >&2
    echo "  call verify_shelf_app_is_current (Scripts/current-shelf-app.sh) before it does." >&2
    exit 1
fi

echo "current-shelf-app: every script that starts a Shelf instance verifies it first."
