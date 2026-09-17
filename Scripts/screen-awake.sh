#!/bin/bash
# Sourced by every script that drives the window. Not run on its own.
#
# A locked screen breaks a window-driven script *without failing it*, which is
# the worst way for anything to break. Measured, during Sprint 2c's screenshot
# run:
#
#   * `screencapture -l <window id>` keeps working and returns the window's
#     *last drawn frame*, so shot after shot comes out byte-identical. Three did.
#   * System Events reports no windows at all.
#   * The accessibility tree degenerates to an application element containing
#     only itself, so every lookup answers "nothing" rather than failing.
#   * `Scripts/window-count.swift` reads `5 0 0` — windows registered with the
#     window server, none composited.
#
# This is very likely also what Sprint 2b wrote down as "one launch produced an
# app with no window, not reproducible, no crash report". The app is fine: it
# still creates and shows its window, and `make smoke` passes while locked.
#
# Usage, as the first thing a script does after defining `fail`:
#
#     . "$HERE/screen-awake.sh"
#     require_awake_screen "$@"

# `grep -c`, and not `grep -q`. Every script that sources this runs under
# `set -o pipefail`, and `grep -q` closes the pipe the moment it matches — so
# `ioreg` dies of SIGPIPE, the pipeline's status becomes 141, and an `if` reads
# a *successful match* as a failure. The guard then waved a locked screen
# straight through, which is precisely the class of silent pass it exists to
# stop.
screen_is_locked() {
    local locked
    locked=$(ioreg -n Root -d1 -r 2>/dev/null | grep -c '"CGSSessionScreenIsLocked"=Yes')
    [ "${locked:-0}" -gt 0 ]
}

require_awake_screen() {
    if screen_is_locked; then
        echo "FAILED – the screen is locked." >&2
        echo "       While it is, a window cannot be driven and a screenshot is the" >&2
        echo "       window's last drawn frame, which looks like success and is not." >&2
        echo "       Unlock the screen and run this again." >&2
        exit 1
    fi
    # Held awake for the length of the run, rather than asking whoever runs it
    # to remember. `-d` keeps the display on, `-i` the system, `-m` the disk,
    # `-s` the system on mains, and `-u` declares the user active — which is
    # what the *screen saver* watches. `-d` alone was not enough: the screen
    # locked in the middle of a run that had already passed this guard, on a
    # Mac whose screen saver starts after five minutes, and the run then failed
    # fifteen seconds later with "⌘2 did not show the table". It had.
    if [ -z "${SHELF_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
        export SHELF_CAFFEINATED=1
        exec caffeinate -dimsu "$0" "$@"
    fi
}

# Called where a script is about to blame the app for something the window did
# not do. A guard that only runs at the start answers the question "was the
# screen locked when this began", and the question that matters is "is it
# locked *now*" — the lock arrives mid-run, and everything after it reads as an
# app that has stopped responding: System Events sees no windows, the
# accessibility tree shrinks to an application element containing only itself,
# and every lookup answers "nothing" rather than failing.
#
#     something_expected || { fail_if_locked_now; fail "…"; }
#
# It prints and exits when the screen is locked, and returns quietly otherwise,
# so the caller's own message is what a reader sees in the ordinary case.
fail_if_locked_now() {
    screen_is_locked || return 0
    echo "FAILED – the screen locked *during* this run." >&2
    echo "       It was awake when the run started, so what follows is not a" >&2
    echo "       verdict on the app: while the screen is locked the accessibility" >&2
    echo "       tree has nothing in it and every keystroke and click is lost." >&2
    echo "       Unlock the screen, keep it unlocked (caffeinate -dimsu -t 14400)," >&2
    echo "       and run this again." >&2
    exit 1
}
