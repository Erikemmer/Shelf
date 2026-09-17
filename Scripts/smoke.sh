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
# Set to 0 to abort instead of quitting an instance that is already running.
KILL_EXISTING="${SMOKE_KILL_EXISTING:-1}"
# Set to 1 to run alongside an instance Xcode is debugging instead of refusing.
# The test then measures its own instance, which it tracks by pid – but the
# keystrokes that open a library go to whichever instance is frontmost, so the
# library may not open. The window title in the output says whether it did.
ALLOW_XCODE="${SMOKE_ALLOW_XCODE:-0}"

fail() {
    echo "smoke: FAILED – $1" >&2
    exit 1
}

# ── The app bundle ────────────────────────────────────────────────────────────
if [ -z "$APP" ]; then
    # Both configurations, newest first: `make app` builds Release (that is what
    # Erik starts), `make app-debug` builds Debug. Measuring whichever happens
    # to be older would report a build nobody is running.
    # Xcode keeps a second, executable-less copy under Index.noindex; skip it.
    while IFS= read -r candidate; do
        candidate="${candidate#* }"
        [ -x "$candidate/Contents/MacOS/Shelf" ] || continue
        APP="$candidate"
        break
    done < <(find ~/Library/Developer/Xcode/DerivedData -name "Shelf.app" -path "*/Build/Products/*" \
        -not -path "*Index.noindex*" -maxdepth 6 -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn)
fi
[ -n "$APP" ] && [ -x "$APP/Contents/MacOS/Shelf" ] || fail "no runnable Shelf.app found – run 'make app' first"
# Which configuration is being measured matters: a Debug build of the same code
# decodes covers several times slower than a Release one.
echo "smoke: bundle: $APP"

# ── Instances that are already running ────────────────────────────────────────
# A plain `open` would only activate an existing instance, and the test would
# measure that one. An instance started from Xcode (⌘R) is held by the debugger:
# it ignores "quit" and even SIGKILL, so there is nothing to do but say so.
for pid in $(pgrep -x Shelf); do
    PARENT=$(ps -o comm= -p "$(ps -o ppid= -p "$pid" | tr -d ' ')" 2>/dev/null)
    case "$PARENT" in
        *debugserver* | *lldb* | *Xcode*)
            [ "$ALLOW_XCODE" = "1" ] && {
                echo "smoke: note – Shelf is also running from Xcode (pid $pid); measuring our own instance"
                continue
            }
            fail "Shelf is running from Xcode (pid $pid, held by ${PARENT##*/}).
       Stop it in Xcode (⌘.) and run 'make smoke' again – a debugged process
       cannot be quit from here.
       To measure a separate instance alongside it: SMOKE_ALLOW_XCODE=1 make smoke"
            ;;
    esac
    if [ "$KILL_EXISTING" = "1" ]; then
        echo "smoke: quitting the Shelf already running (pid $pid)"
    else
        fail "Shelf is already running (pid $pid) – quit it, or unset SMOKE_KILL_EXISTING=0"
    fi
done
if pgrep -x Shelf >/dev/null && [ "$ALLOW_XCODE" != "1" ]; then
    osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
    sleep 2
    pkill -x Shelf >/dev/null 2>&1
    sleep 1
    pgrep -x Shelf >/dev/null && fail "could not quit Shelf (pid $(pgrep -x Shelf | tr '\n' ' '))"
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
if ! [[ "$WINDOWS" =~ ^[0-9]+$ ]]; then
    cleanup
    fail "could not count windows for pid $PID (window-count.swift gave '${COUNTS:-no answer}')"
fi
# The title says whether a library actually opened: "<name> — Shelf".
TITLE=$(osascript -e 'tell application "System Events" to tell process "Shelf" to get name of front window' 2>/dev/null)
echo "smoke: front window title: ${TITLE:-unavailable}"
# Existence is the criterion: a minimised window, one on another Space, or one
# another app's full-screen window covers is not "on screen" while the app is
# perfectly fine. Both numbers are reported and only "at least one" is asserted.
#
# The first number is not a window count: four of those layer-0 windows are the
# system's menu bar (1512 x 33 at 0,0, never on screen), and Selector reports the
# same four. A healthy Shelf reads "5 1". Established by launching Selector's
# window list beside Shelf's and by three quit-and-relaunch rounds that stayed at
# one; see CHANGELOG, Sprint 1 follow-up.
echo "smoke: windows: $WINDOWS (of those on screen: $ONSCREEN)"
if [ "$WINDOWS" -lt 1 ]; then
    # Second opinion before failing: the two ways of asking disagree now and then.
    VIA_EVENTS=$(osascript -e 'tell application "System Events" to tell process "Shelf" to count windows' 2>&1)
    echo "smoke: System Events counts: $VIA_EVENTS"
    cleanup
    fail "measured $WINDOWS windows for pid $PID"
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
