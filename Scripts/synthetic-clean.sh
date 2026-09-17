#!/bin/bash
# Deletes the synthetic test material and says how much space came back.
#
# It only ever removes a folder under ~/Library/Caches/Shelf, and it says what
# it is about to do before doing it. Test data is disposable; a script that can
# be pointed at anything is not.
set -uo pipefail

TARGET="${1:-$HOME/Library/Caches/Shelf/synthetic}"
GUARD="$HOME/Library/Caches/Shelf"

case "$TARGET" in
    "$GUARD"/*) ;;
    *)
        echo "refusing: '$TARGET' is not under $GUARD" >&2
        exit 2
        ;;
esac

if [ ! -d "$TARGET" ]; then
    echo "nothing to clean: $TARGET does not exist"
    exit 0
fi

BEFORE=$(LC_ALL=C df -k "$HOME" | awk 'NR==2 {print $4}')
SIZE=$(LC_ALL=C du -sh "$TARGET" | awk '{print $1}')
echo "removing $TARGET ($SIZE)"
rm -rf "$TARGET"
AFTER=$(LC_ALL=C df -k "$HOME" | awk 'NR==2 {print $4}')

# In the C locale, so the arithmetic works on a German Mac too – the same
# lesson as the CPU reading in smoke.sh.
FREED=$(( (AFTER - BEFORE) / 1024 ))
echo "removed. free space now: $(LC_ALL=C df -h "$HOME" | awk 'NR==2 {print $4}') (about ${FREED} MB more than before)"
