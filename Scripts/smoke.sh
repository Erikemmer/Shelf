#!/bin/bash
# Smoke test: does the built app actually run?
#
# A green build says nothing about whether the app shows a window and settles
# down. A SwiftUI view that invalidates itself gives a perfectly green build, an
# app that starts, pins a core and never shows a window. This starts it, opens a
# library if one is given, and reports what it measured: the pid, how many
# windows the process has on screen, and how the CPU load develops.
#
# It reports measurements, not diagnoses – what a failure means is for whoever
# reads it to work out.
#
# Usage: Scripts/smoke.sh [library folder]   (or SMOKE_LIBRARY=/path make smoke)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${SMOKE_APP:-}"
LIBRARY="${1:-${SMOKE_LIBRARY:-}}"
MAX_CPU="${SMOKE_MAX_CPU:-20}"
# Set to 1 to run alongside an instance Xcode is debugging instead of refusing.
# The test then measures its own instance, which it tracks by pid – but the
# keystrokes that open a library go to whichever instance is frontmost, so the
# library may not open. The window title in the output says whether it did.
ALLOW_XCODE="${SMOKE_ALLOW_XCODE:-0}"

fail() {
    echo "smoke: FAILED – $1" >&2
    exit 1
}

. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"

# ── The app bundle ────────────────────────────────────────────────────────────
# Both configurations are candidates: `make app` builds Release (that is what
# Erik starts), `make app-debug` builds Debug. `find_current_shelf_app`
# (Scripts/current-shelf-app.sh) is what chooses among them — the one
# stamped with this repository's own HEAD, never merely the newest by a
# bundle folder's own mtime.
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app)" || exit 1
fi
[ -n "$APP" ] && [ -x "$APP/Contents/MacOS/Shelf" ] || fail "no runnable Shelf.app found – run 'make app' first"
verify_shelf_app_is_current "$APP" || exit 1
# Which configuration is being measured matters: a Debug build of the same code
# decodes covers several times slower than a Release one.
echo "smoke: bundle: $APP"

# ── Instances that are already running ────────────────────────────────────────
# A plain `open` would only activate an existing instance, and the test would
# measure that one — not the build this run just made. This never tries to end
# one it finds, debugged or not: see `Scripts/no-foreign-shelf.sh` for why.
# `make smoke` once quit exactly such an instance, unconditionally; this is
# the fix. `--allow-xcode` because this is the one script that can meaningfully
# measure its own pid alongside one Xcode is debugging.
if [ "$ALLOW_XCODE" = "1" ]; then
    require_no_foreign_shelf --allow-xcode
else
    require_no_foreign_shelf
fi

cleanup() {
    [ -n "${PID:-}" ] || return
    kill "$PID" >/dev/null 2>&1
    sleep 1
    kill -9 "$PID" >/dev/null 2>&1
}

# -n forces a fresh instance rather than activating whatever is around.
#
# The library is handed over on the command line rather than typed into the open
# panel through System Events. That needs no automation permission at all, and
# it exercises the same path as dropping a library folder on the app's icon
# (`ShelfApp.onOpenURL`). Selector had to drive the open panel because it has no
# such path; this is the better test *and* the simpler one.
BEFORE=$(pgrep -x Shelf | tr '\n' ' ')
COVERS_BEFORE=0
if [ -n "$LIBRARY" ]; then
    [ -d "$LIBRARY" ] || fail "SMOKE_LIBRARY '$LIBRARY' is not a folder"
    COVERS_BEFORE=$(ls -1 "$LIBRARY/.shelf/covers" 2>/dev/null | wc -l | tr -d ' ')
    # `-a` and not `-n` here: `open -n` with a document argument fails to launch
    # ("Launchd job spawn failed"). The script has already made sure no other
    # instance is running, so there is nothing for `open` to activate instead.
    open -a "$APP" "$LIBRARY" || fail "could not launch $APP with $LIBRARY"
else
    open -n "$APP" || fail "could not launch $APP"
fi
sleep 4
PID=""
for candidate in $(pgrep -x Shelf); do
    case " $BEFORE " in *" $candidate "*) continue ;; esac
    PID="$candidate"
    break
done
[ -n "$PID" ] || fail "the app did not start (no Shelf process)"
echo "smoke: pid $PID"

# ── Settle ────────────────────────────────────────────────────────────────────
if [ -n "$LIBRARY" ]; then
    OPENED="library '$LIBRARY', handed over on the command line"
    # A large library needs a moment to read its index and start its covers.
    sleep 6
else
    OPENED="nothing – measuring the welcome screen"
    sleep 2
fi
echo "smoke: opened $OPENED"

# ── Did the library actually open? ────────────────────────────────────────────
# Without permission to automate System Events the window's title cannot be
# read, so the evidence is what the app *did*.
#
# Two pieces of it. The recent-libraries list is written the moment a library
# finishes opening, so it names the library whether or not anything had to be
# decoded — that is the check. The cover count is reported alongside because it
# says whether the pipeline ran, which on a cold cache it must.
if [ -n "$LIBRARY" ]; then
    COVERS_AFTER=$(ls -1 "$LIBRARY/.shelf/covers" 2>/dev/null | wc -l | tr -d ' ')
    echo "smoke: cached covers in the library: $COVERS_BEFORE before, $COVERS_AFTER after"

    RECENTS="$HOME/Library/Containers/de.erikemmer.shelf/Data/Library/Preferences/de.erikemmer.shelf.plist"
    # `plutil -extract … raw` and not `defaults read`: the value is a data blob
    # holding JSON, and `defaults` prints such a blob abbreviated with an
    # ellipsis in the middle, which cannot be decoded. The JSON escapes its
    # slashes (`\/`), so the backslashes come out before the path is looked for.
    if RECORDED=$(plutil -extract recentLibraries raw -o - "$RECENTS" 2>/dev/null | base64 -d 2>/dev/null \
        | tr -d '\\'); then
        if echo "$RECORDED" | grep -qF "$LIBRARY"; then
            echo "smoke: the library is in the app's recent list – it opened"
        else
            echo "smoke: note – the library is not in the app's recent list yet;" \
                "it may still have been reading, or it did not open"
        fi
    else
        echo "smoke: note – could not read the app's recent list, so whether the" \
            "library opened rests on the cover count above"
    fi
fi

# ── Windows ───────────────────────────────────────────────────────────────────
# Counted through the window server, which needs no automation permission.
COUNTS=$(swift "$HERE/window-count.swift" "$PID" 2>/dev/null)
WINDOWS=$(echo "$COUNTS" | awk '{print $1}')
ONSCREEN=$(echo "$COUNTS" | awk '{print $2}')
# The third number: on screen and not a menu-bar strip. See window-count.swift.
REAL=$(echo "$COUNTS" | awk '{print $3}')
if ! [[ "$WINDOWS" =~ ^[0-9]+$ ]]; then
    cleanup
    fail "could not count windows for pid $PID (window-count.swift gave '${COUNTS:-no answer}')"
fi
# The title says whether a library actually opened: "<name> — Shelf".
TITLE=$(osascript -e 'tell application "System Events" to tell process "Shelf" to get name of front window' 2>/dev/null)
echo "smoke: front window title: ${TITLE:-unavailable}"
# The first number is not a window count: four of those layer-0 windows are the
# system's menu bar (1512 x 33 at 0,0, never on screen), and Selector reports the
# same four. A healthy Shelf reads "5 1". Established by launching Selector's
# window list beside Shelf's and by three quit-and-relaunch rounds that stayed at
# one; see CHANGELOG, Sprint 1 follow-up.
echo "smoke: windows: $WINDOWS (of those on screen: $ONSCREEN, real: $REAL)"
if [ "$WINDOWS" -lt 1 ]; then
    # Second opinion before failing: the two ways of asking disagree now and then.
    VIA_EVENTS=$(osascript -e 'tell application "System Events" to tell process "Shelf" to count windows' 2>&1)
    echo "smoke: System Events counts: $VIA_EVENTS"
    cleanup
    fail "measured $WINDOWS windows for pid $PID"
fi
# No real window on screen is a failure, and it was not until Sprint 2b.
#
# The old rule asserted only "at least one window exists", on the argument that
# a minimised window, one on another Space, or one behind another app's
# full-screen window is not "on screen" while the app is perfectly fine. That
# argument does not apply to *this* script: it launches the app itself, on the
# current Space, and never minimises it. It was left as a reported number, and
# a launch that produced no window duly reported "windows: 1 (of those on
# screen: 0)", "front window title: unavailable" — and then "ok". That is the
# one thing the smoke test exists to catch, and it waved it through. It happened
# here, once, while Sprint 2b's numbers were being taken.
#
# Two things had to change for the assertion to be worth making:
#
# 1. **The third number**, not the second. In the run that went wrong the app
#    reported "1 1", and that "1 on screen" was a *menu-bar strip* — a window
#    that is not a window. `window-count.swift` now excludes them.
# 2. **A retry.** The on-screen reading is a momentary one and it flickers: a
#    healthy Shelf measured "5 0 0" and, two seconds later, "5 1 1". Failing on
#    the first zero would make the smoke test unreliable, which is worse than
#    the hole it is closing. A zero that survives five looks is the real thing.
if [ "${REAL:-0}" -lt 1 ] && [ "${SMOKE_ALLOW_OFFSCREEN:-0}" != "1" ]; then
    for _ in 1 2 3 4 5; do
        sleep 1
        REAL=$(swift "$HERE/window-count.swift" "$PID" 2>/dev/null | awk '{print $3}')
        [ "${REAL:-0}" -ge 1 ] && break
    done
    echo "smoke: windows on screen after looking again: ${REAL:-0}"
fi
if [ "${REAL:-0}" -lt 1 ] && [ "${SMOKE_ALLOW_OFFSCREEN:-0}" != "1" ]; then
    VIA_EVENTS=$(osascript -e 'tell application "System Events" to tell process "Shelf" to count windows' 2>&1)
    echo "smoke: System Events counts: $VIA_EVENTS"
    cleanup
    fail "the app is running but has no real window on screen, five looks apart.
       Either the launch produced no window at all, or the window opened
       somewhere this Space cannot see. If it keeps happening with a window
       plainly visible, set SMOKE_ALLOW_OFFSCREEN=1 and say so in the report."
fi

# **And no more than one.** One app, one library, one window (CONCEPT §3.2, and
# the reason `AppDelegate` handles an incoming folder itself rather than through
# `onOpenURL`, which would open a window per URL).
#
# This was a reported number and not an assertion until Sprint 7, and it duly
# reported "windows: 11 (of those on screen: 7, real: 7)" and then said "ok".
# The cause was four `NSWindow Frame …AppWindow-N` keys accumulated in the app's
# own defaults — SwiftUI remembers a window per scene it has seen, and this
# script's own `cleanup` kills the app. Removing those keys brought it back to
# "5 1 1" at once. Sprint 1 recorded the same symptom as "six, growing by one
# per launch" and could not reproduce it; now there is a check that would have.
#
# It is an assertion rather than a note for the same reason the zero is: a
# number printed in a passing run is a number nobody reads.
if [ "${REAL:-0}" -gt 1 ] && [ "${SMOKE_ALLOW_MANY_WINDOWS:-0}" != "1" ]; then
    cleanup
    fail "the app has ${REAL} windows on screen and should have one.
       SwiftUI remembers a window per scene in the app's own defaults; a run
       that was killed rather than quit can leave one behind. To see them:
         plutil -p ~/Library/Containers/de.erikemmer.shelf/Data/Library/Preferences/de.erikemmer.shelf.plist \
           | grep 'NSWindow Frame'
       Removing those keys puts it back to one. If several windows are wanted
       one day, set SMOKE_ALLOW_MANY_WINDOWS=1 and say so in the report."
fi

# ── CPU and memory ────────────────────────────────────────────────────────────
# The cover warmer keeps a core busy for a while; the test records the trace and
# passes as soon as it drops below the threshold. Memory is recorded alongside,
# because the cover caches have byte budgets and a budget nobody measures is a
# hope (CONCEPT §11: under 1.5 GB with 5 000 books).
TRACE=""
PEAK_RSS=0
SECONDS_WAITED=0
for _ in $(seq 1 12); do
    sleep 5
    pgrep -x Shelf >/dev/null || { echo "smoke: trace:$TRACE"; fail "the app quit on its own"; }
    # `ps` formats the number in the user's locale: on a German Mac it reads
    # "64,4", and `[ … -lt … ]` compares whole numbers only. Every comparison
    # then errors out, the trace never counts as settled, and a perfectly
    # healthy app is reported as a failure – which is what happened in Selector.
    # Ask in the C locale, and cut at either separator anyway.
    CPU=$(LC_ALL=C ps -o %cpu= -p "$PID" | tr -d ' ')
    CPU_WHOLE=${CPU%%[.,]*}
    # Resident size in KB; the same locale caution does not apply, it is an
    # integer, but asking in C costs nothing and keeps the two readings alike.
    RSS=$(LC_ALL=C ps -o rss= -p "$PID" | tr -d ' ')
    [[ "$RSS" =~ ^[0-9]+$ ]] || RSS=0
    [ "$RSS" -gt "$PEAK_RSS" ] && PEAK_RSS=$RSS
    SECONDS_WAITED=$((SECONDS_WAITED + 5))
    TRACE="$TRACE ${CPU}%/$((RSS / 1024))MB"
    if ! [[ "$CPU_WHOLE" =~ ^[0-9]+$ ]]; then
        echo "smoke: trace:$TRACE"
        cleanup
        fail "could not read the CPU load for pid $PID (ps gave '${CPU:-no answer}')"
    fi
    if [ "$CPU_WHOLE" -lt "$MAX_CPU" ]; then
        echo "smoke: trace (CPU/memory):$TRACE"
        echo "smoke: ok – pid $PID, $WINDOWS window(s), CPU at ${CPU} % after ${SECONDS_WAITED} s," \
            "peak memory $((PEAK_RSS / 1024)) MB"
        cleanup
        exit 0
    fi
done

echo "smoke: trace (CPU/memory):$TRACE"
echo "smoke: peak memory $((PEAK_RSS / 1024)) MB"
cleanup
fail "CPU stayed at or above ${MAX_CPU} % for a minute (last reading ${CPU}%)"
