#!/bin/bash
# Checks that no script under Scripts/ can start a Shelf instance without
# having called `require_no_foreign_shelf` (Scripts/no-foreign-shelf.sh) first.
#
# Sprint 9 pulled that guard into its own file and sourced it into eighteen
# scripts – and sixteen of them never actually called it, because sourcing a
# file and calling what it defines are two different steps and nothing forced
# the second one. Fixing those sixteen by hand does not stop a nineteenth
# script from making the same mistake tomorrow. This does, by running inside
# `make lint` on every commit rather than being remembered.
#
# A grep, not a parser: a line starts a Shelf instance if it calls `open -a`
# against the app path every script here finds for itself (`"$APP"`, or the
# literal name `Shelf`) or executes `Contents/MacOS/Shelf` directly rather
# than merely testing for it with `-x`. If such a line appears in a script
# that never calls `require_no_foreign_shelf`, or calls it only after the
# launch, this fails and names the file and the line.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0

for script in "$HERE"/*.sh; do
    name="$(basename "$script")"
    # The guard's own file: it defines require_no_foreign_shelf, it does not
    # call it, and its doc comments quote both without meaning either.
    [ "$name" = "no-foreign-shelf.sh" ] && continue

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
                *require_no_foreign_shelf*) guard_line=$n ;;
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
            echo "no-foreign-shelf: Scripts/$name:$launch_line starts a Shelf instance but never calls require_no_foreign_shelf" >&2
            FAILED=1
        elif [ "$guard_line" -gt "$launch_line" ]; then
            echo "no-foreign-shelf: Scripts/$name:$launch_line starts a Shelf instance before the guard at line $guard_line" >&2
            FAILED=1
        fi
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo "no-foreign-shelf: every script under Scripts/ that starts a Shelf instance must" >&2
    echo "  call require_no_foreign_shelf (Scripts/no-foreign-shelf.sh) before it does." >&2
    exit 1
fi

echo "no-foreign-shelf: every script that starts a Shelf instance calls the guard first."
