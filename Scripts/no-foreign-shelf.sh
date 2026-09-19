# Refuses to run alongside a Shelf that is already up. Sourced by every
# script that launches its own instance of the app.
#
# Sourced, not run.
#
# ## Why this exists
#
# Every script that drives the window used to try to make an existing Shelf go
# away before starting its own: Escape to dismiss a sheet, then
# `tell application "Shelf" to quit`, retried several times for good measure,
# and only *then* fail if it would not go. The reasoning, written into more
# than one of these scripts as a comment, was that the only Shelf which could
# possibly be running is a leftover from an earlier run of the same script.
#
# `pgrep` cannot tell that leftover apart from an instance Erik started
# himself and is looking at right now — both are just a pid. One run of
# `make smoke` quit exactly the second kind (CLAUDE.md rule 6: never end a
# process this session did not start), and it did so while doing exactly what
# its own comment said it would never do. A comment is not a guard.
#
# So this checks once, before anything is launched, and refuses outright if
# anything answers to the name. It does not send Escape, it does not ask
# nicely, and it does not retry — those are all ways of *trying* to end a
# process this run did not start, which is the thing being refused.
#
# A script may still end an instance **it goes on to start itself** a few
# lines later — that pid is its own to end, tracked from the moment `open`
# hands it back, never rediscovered by name.
#
# ## Use
#
#     . "$HERE/no-foreign-shelf.sh"
#     require_no_foreign_shelf
#     open -a "$APP" "$LIBRARY" ${SHELF_LANGUAGE_ARGS:-}
#     PID=$(pgrep -x Shelf | head -1)   # safe now: the check above just ran
#
# `require_no_foreign_shelf --allow-xcode` treats a Shelf running under
# Xcode's debugger (⌘R) as reported rather than refused — `smoke.sh`'s
# `SMOKE_ALLOW_XCODE` is the only caller that ever passes it, because it is
# the only one that can measure its own pid alongside a debugged one without
# the two fighting over which gets the keystrokes. Everything else that is
# not the debugged instance is still refused exactly as above, debugger or
# not: this flag widens nothing except that one specific, named case.
require_no_foreign_shelf() {
    local allow_xcode="${1:-}"
    local pid parent
    for pid in $(pgrep -x Shelf); do
        parent=$(ps -o comm= -p "$(ps -o ppid= -p "$pid" | tr -d ' ')" 2>/dev/null)
        case "$parent" in
            *debugserver* | *lldb* | *Xcode*)
                if [ "$allow_xcode" = "--allow-xcode" ]; then
                    echo "note – Shelf is also running from Xcode (pid $pid); leaving it alone" >&2
                    continue
                fi
                echo "FAILED – Shelf is running from Xcode (pid $pid, held by ${parent##*/})." >&2
                echo "       Stop it in Xcode (⌘.) and run this again – a debugged process cannot" >&2
                echo "       be quit from here, and this script does not try." >&2
                exit 1
                ;;
            *)
                echo "FAILED – Shelf is already running (pid $pid)." >&2
                echo "       This script only ever ends an instance it starts itself. Close the" >&2
                echo "       running one yourself (Dock icon or ⌘Q) and run this again." >&2
                exit 1
                ;;
        esac
    done
}
