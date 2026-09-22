#!/bin/bash
# Runs every path in `docs/RUNBOOK.md` once, and prints what it did.
#
# A runbook nobody has followed is a wish. Every number and every quoted line in
# that document comes out of this script, so the instructions can be checked
# rather than believed — and so the day one of them stops being true, running
# this says which one.
#
# It works entirely inside its own folder under ~/Library/Caches/Shelf and
# removes only what it made there (CLAUDE.md). The disk image it makes for the
# "move to another drive" path is detached at the end, and only that one.
#
# Usage: Scripts/runbook-proof.sh [folder]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/no-foreign-shelf.sh"
. "$HERE/current-shelf-app.sh"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="${1:-$HOME/Library/Caches/Shelf/runbook-7b}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/Shelf/build}"
TOOL="$SCRATCH/debug/shelf-tool"
VOLUME="ShelfRunbook"

say() { printf '\n══ %s\n' "$1"; }
run() {
    printf '\n$ %s\n' "$*"
    "$@"
}
fail() { echo "runbook-proof: FAILED – $1" >&2; exit 1; }

[ -x "$TOOL" ] || swift build --package-path "$ROOT" --scratch-path "$SCRATCH" || fail "could not build shelf-tool"

# Only this script's own folder, by name.
rm -rf "$WORK"
mkdir -p "$WORK" || fail "cannot make $WORK"
SOURCE="$WORK/source"
LIBRARY="$WORK/library"
BACKUP="$WORK/backup"
RESTORED="$WORK/restored"

say "0. A library to work with"
run "$TOOL" synthesise "$SOURCE" 20 | tail -2
mkdir -p "$LIBRARY"
run "$TOOL" import "$SOURCE" "$LIBRARY" | tail -3

say "1. What is the truth and what is a cache"
echo "the whole library folder:"
du -sh "$LIBRARY"
echo "what is *only* a cache, and can be deleted at any time:"
du -sh "$LIBRARY/.shelf/covers" 2>/dev/null
du -sh "$LIBRARY"/.shelf/library.sqlite* 2>/dev/null
echo "what has to be kept:"
echo "  library.json          $(du -h "$LIBRARY/.shelf/library.json" 2>/dev/null | cut -f1)"
echo "  the book folders      $(find "$LIBRARY" -mindepth 2 -maxdepth 2 -type d -not -path "*/.shelf/*" | wc -l | tr -d ' ') of them"
echo "  a metadata.opf each   $(find "$LIBRARY" -name metadata.opf | wc -l | tr -d ' ') of them"

say "2. Back up — everything except the two things that rebuild themselves"
# `ditto` rather than `cp -R`: it keeps extended attributes and resource forks,
# and it is the copy macOS itself uses.
run rm -rf "$BACKUP"
run mkdir -p "$BACKUP"
run rsync -a --exclude ".shelf/covers/" --exclude ".shelf/library.sqlite*" "$LIBRARY/" "$BACKUP/"
echo "the backup, without the cache:"
du -sh "$BACKUP"
echo "what is in it:"
ls -A "$BACKUP" | head -5
ls -A "$BACKUP/.shelf"

say "3. Restore — copy it back and rebuild the index from the folders"
run rm -rf "$RESTORED"
run cp -R "$BACKUP" "$RESTORED"
echo "there is no index in the restored copy:"
ls -A "$RESTORED/.shelf"
run "$TOOL" rebuild "$RESTORED" | tail -4
echo "and the two libraries agree about how many books they hold:"
BEFORE_COUNT=$("$TOOL" rebuild "$LIBRARY" 2>/dev/null | grep -m1 -Eo '[0-9]+ books')
AFTER_COUNT=$("$TOOL" rebuild "$RESTORED" 2>/dev/null | grep -m1 -Eo '[0-9]+ books')
echo "  original: ${BEFORE_COUNT:-?} · restored: ${AFTER_COUNT:-?}"
[ "$BEFORE_COUNT" = "$AFTER_COUNT" ] || fail "the restored library holds a different number of books"

say "4. Rebuild the index on its own — throw it away and ask for it back"
run rm -f "$RESTORED/.shelf/library.sqlite" "$RESTORED/.shelf/library.sqlite-wal" "$RESTORED/.shelf/library.sqlite-shm"
run "$TOOL" rebuild "$RESTORED" | tail -4

say "5. Move to another drive"
IMAGE="$WORK/other-drive.dmg"
run hdiutil create -size 200m -fs HFS+ -volname "$VOLUME" -quiet "$IMAGE"
run hdiutil attach "$IMAGE" -quiet
if [ -d "/Volumes/$VOLUME" ]; then
    run rsync -a "$LIBRARY/" "/Volumes/$VOLUME/library/"
    echo "the moved library, opened by the tool on the other drive:"
    run "$TOOL" rebuild "/Volumes/$VOLUME/library" | tail -3
    run hdiutil detach "/Volumes/$VOLUME" -quiet
    echo "  the image is detached again; it was this script's own"
else
    echo "  the image did not mount — this path was not proved"
fi

say "6. The way back to Calibre"
echo "the folder tree Calibre's “Add books from directories” walks:"
find "$LIBRARY" -mindepth 2 -maxdepth 2 -type d -not -path "*/.shelf/*" | head -3
echo "one book's folder:"
FIRST=$(find "$LIBRARY" -mindepth 2 -maxdepth 2 -type d -not -path "*/.shelf/*" | head -1)
ls -A "$FIRST"
echo "and the metadata Calibre reads out of it:"
grep -E "dc:title|dc:creator|dc:identifier" "$FIRST/metadata.opf" | head -4

say "7. A crash in the middle of an import"
KILLED="$WORK/killed-library"
BIG="$WORK/big-source"
mkdir -p "$KILLED"
run "$TOOL" synthesise "$BIG" 400 | tail -1
# Started here, so stopping it is this script's own business.
"$TOOL" import "$BIG" "$KILLED" >"$WORK/import.log" 2>&1 &
IMPORTER=$!
sleep 6
kill -9 "$IMPORTER" 2>/dev/null
wait "$IMPORTER" 2>/dev/null
echo "the import was killed after six seconds. What it left:"
find "$KILLED" -mindepth 2 -maxdepth 2 -type d | wc -l | tr -d ' ' | sed 's/^/  book folders on disk: /'
echo "the same import again, which resumes rather than starting over:"
run "$TOOL" import "$BIG" "$KILLED" | tail -4

say "8. Folders no book points at"
run "$TOOL" orphans "$KILLED" | tail -6

say "9. A crash in the middle of a transfer"
#
# A real device profile, not the plain image from step 5: `send` refuses a
# volume no profile matches, which is the right refusal and not the thing being
# shown here. `Scripts/device-images.sh` makes a Kindle with the marker layout
# CONCEPT §8.1 names.
"$HERE/device-images.sh" make "$WORK/device-images" >/dev/null 2>&1
if [ -d /Volumes/KOBOeReader ]; then
    on_card() { find /Volumes/KOBOeReader -name "*.epub" 2>/dev/null | wc -l | tr -d ' '; }
    partials() { find /Volumes/KOBOeReader -name "*.part" 2>/dev/null | wc -l | tr -d ' '; }
    # How many files the device's own manifest records. `grep -c` on a file
    # that is not there prints nothing *and* fails, so the fallback has to be
    # inside the substitution — with it outside, the line read "0\n0".
    recorded() {
        local manifest
        manifest=$(find /Volumes/KOBOeReader -name device-manifest.json 2>/dev/null | head -1)
        [ -n "$manifest" ] || { echo 0; return; }
        grep -c '"sha256"' "$manifest" 2>/dev/null | tr -d ' \n' || echo 0
        echo
    }
    echo "before anything is sent:   $(on_card) book files · $(partials) .part · $(recorded) in the manifest"
    # Started here, so stopping it is this script's own business.
    "$TOOL" send "$LIBRARY" /Volumes/KOBOeReader 20 >"$WORK/send.log" 2>&1 &
    SENDER=$!
    sleep 1
    kill -9 "$SENDER" 2>/dev/null
    wait "$SENDER" 2>/dev/null
    echo "killed after one second:   $(on_card) book files · $(partials) .part · $(recorded) in the manifest"
    echo "the same transfer again — every file is hashed on both sides before it counts:"
    run "$TOOL" send "$LIBRARY" /Volumes/KOBOeReader 20 | tail -12
    echo "afterwards:                $(on_card) book files · $(partials) .part · $(recorded) in the manifest"
    "$HERE/device-images.sh" unmount >/dev/null 2>&1
    echo "  the card is detached again; it was this script's own"
else
    echo "  the Kobo image did not mount — this path was not proved"
fi

say "10. Where the reports and the logs are"
echo "the import report, appended to once per import:"
ls -la "$LIBRARY/.shelf/Import-Report.txt" 2>/dev/null || echo "  none yet"
tail -6 "$LIBRARY/.shelf/Import-Report.txt" 2>/dev/null
echo
echo "the app's own log. It goes to the unified log and not to a file, and it is"
echo "quiet: notice and above, plus one error per message the window shows."
echo "So there is something to read only when something has gone wrong — which"
echo "this makes happen, by opening a folder that is not a library:"
#
# The failure chosen is the one a person is most likely to meet: a library
# written by a newer Shelf. `schemaVersion` higher than this build understands
# is refused rather than opened, because writing such a library back could drop
# fields it does not know about (DATA-MODEL §2).
APP="${RUNBOOK_APP:-}"
# A soft check, not the hard refusal require_no_foreign_shelf gives every
# other caller: this is one section of a much longer proof run, and no
# candidate stamped with HEAD (or a Shelf already open — Erik's, or a
# leftover) should make this section skip itself rather than take the rest
# of the runbook proof down with it. `find_current_shelf_app`'s own stderr
# is silenced here for the same reason: this section fails quietly, it does
# not name candidates the way a hard refusal does. The subshell keeps
# require_no_foreign_shelf's own `exit` from doing that while still asking
# the one question that matters: is a foreign Shelf running right now.
if [ -z "$APP" ]; then
    APP="$(find_current_shelf_app 2>/dev/null)"
fi
if [ -n "$APP" ] && verify_shelf_app_is_current "$APP" >/dev/null 2>&1 && (require_no_foreign_shelf) >/dev/null 2>&1; then
    SINCE=$(date "+%Y-%m-%d %H:%M:%S")
    FROM_THE_FUTURE="$WORK/from-the-future"
    rm -rf "$FROM_THE_FUTURE"
    cp -R "$BACKUP" "$FROM_THE_FUTURE"
    python3 - "$FROM_THE_FUTURE/.shelf/library.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    library = json.load(handle)
library["schemaVersion"] = 99
with open(path, "w", encoding="utf-8") as handle:
    json.dump(library, handle, indent=2, sort_keys=True)
PYEOF
    echo "  a copy of the library with schemaVersion 99, which this Shelf cannot read:"
    open -a "$APP" "$FROM_THE_FUTURE" >/dev/null 2>&1
    sleep 8
    osascript -e 'tell application "Shelf" to quit' >/dev/null 2>&1
    sleep 3
    printf '\n$ %s\n' "log show --start '$SINCE' --predicate 'subsystem == \"de.erikemmer.shelf\"' --info"
    log show --start "$SINCE" --predicate 'subsystem == "de.erikemmer.shelf"' --info 2>/dev/null | tail -4
else
    echo "  (skipped: no built Shelf.app, the one found is not built from this"
    echo "   repository's current HEAD, or one is already running — this script"
    echo "   never ends a Shelf it did not start and never rebuilds one for you)"
fi

say "Done"
echo "everything above happened inside $WORK, which is this script's own and"
echo "nothing else was touched. Remove it with:  rm -rf $WORK"
