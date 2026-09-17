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

require_awake_screen() {
    # `grep -c`, and not `grep -q`. Every script that sources this runs under
    # `set -o pipefail`, and `grep -q` closes the pipe the moment it matches —
    # so `ioreg` dies of SIGPIPE, the pipeline's status becomes 141, and the
    # `if` reads a *successful match* as a failure. The guard then waved a
    # locked screen straight through, which is precisely the class of silent
    # pass it exists to stop.
    local locked
    locked=$(ioreg -n Root -d1 -r 2>/dev/null | grep -c '"CGSSessionScreenIsLocked"=Yes')
    if [ "${locked:-0}" -gt 0 ]; then
        echo "FAILED – the screen is locked." >&2
        echo "       While it is, a window cannot be driven and a screenshot is the" >&2
        echo "       window's last drawn frame, which looks like success and is not." >&2
        echo "       Unlock the screen and run this again." >&2
        exit 1
    fi
    # Held awake for the length of the run, rather than asking whoever runs it
    # to remember. `-d` keeps the display on, `-i` the system.
    if [ -z "${SHELF_CAFFEINATED:-}" ] && command -v caffeinate >/dev/null 2>&1; then
        export SHELF_CAFFEINATED=1
        exec caffeinate -di "$0" "$@"
    fi
}
