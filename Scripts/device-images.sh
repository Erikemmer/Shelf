#!/bin/bash
# Four e-readers made out of disk images, so Sprint 5 can be measured without
# four e-readers on the desk.
#
# `hdiutil` makes one image per device: FAT32 where a real reader is FAT32
# (Kindle, Tolino, PocketBook) and HFS+ for one of them, so the proof run sees
# both a volume with the 4 GB file limit and one without. Each image is then
# given the marker layout CONCEPT §8.1 names, and mounting it puts it under
# /Volumes where Shelf and `shelf-tool` find it exactly as they would a reader.
#
# What this does **not** prove is in docs/BACKLOG.md under "To check on real
# hardware": a real USB device, a cable pulled mid-transfer, a real
# KoboReader.sqlite, and the NSWorkspace mount notification itself.
#
# Usage:
#   Scripts/device-images.sh make [folder]     make and mount the four
#   Scripts/device-images.sh mount [folder]    mount ones already made
#   Scripts/device-images.sh unmount           detach them again
#   Scripts/device-images.sh small [folder] [free mb]
#                                              a nearly full FAT32 Kindle, for
#                                              the "no room" measurement
#
# It only ever detaches volumes whose names are in the table below — a session
# never ends something it did not start (CLAUDE.md).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="${DEVICE_IMAGE_DIR:-$HOME/Library/Caches/Shelf/measure-library-5/device-images}"

# name | file system | size | marker paths (space separated) | books folder
#
# Reference data, one row per device, and the same four the profiles in
# ShelfCore/Devices/Profiles/ describe. The volume names are the ones a real
# device mounts under, which is what makes the Tolino's name route real.
DEVICES=(
    "KOBOeReader|MS-DOS FAT32|64m|.kobo|"
    "Kindle|MS-DOS FAT32|64m|system documents|documents"
    "tolino|HFS+|64m|.tolino Books|Books"
    "PocketBook|MS-DOS FAT32|64m|system applications Books|Books"
)
# Literal, four rows: it cannot be empty unless the table above is edited
# down to nothing, a different, visible change. Every "${DEVICES[@]}" below
# carries the same reasoning, right where it is used, rather than once here
# for the whole file – a later use elsewhere would otherwise inherit a
# guarantee only this declaration earned (Sprint 16, Teil E/F).

say() { echo "device-images: $1"; }
fail() { echo "device-images: FAILED – $1" >&2; exit 1; }

volume_names() {
    local row
    # "${DEVICES[@]}" is never empty under set -u: the literal table above.
    for row in "${DEVICES[@]}"; do echo "${row%%|*}"; done
}

make_images() {
    mkdir -p "$CACHE" || fail "cannot make $CACHE"
    local row name fs size markers books image
    # "${DEVICES[@]}" is never empty under set -u: the literal table above.
    for row in "${DEVICES[@]}"; do
        IFS='|' read -r name fs size markers books <<< "$row"
        image="$CACHE/$name.dmg"
        if [ -f "$image" ]; then
            say "$name.dmg is already there – left alone"
            continue
        fi
        say "making $name ($fs, $size)"
        hdiutil create -size "$size" -fs "$fs" -volname "$name" -ov -quiet "$image" \
            || fail "hdiutil could not make $name"
    done
    mount_images
    lay_out
}

mount_images() {
    local row name rest image
    # "${DEVICES[@]}" is never empty under set -u: the literal table above.
    for row in "${DEVICES[@]}"; do
        name="${row%%|*}"
        image="$CACHE/$name.dmg"
        [ -f "$image" ] || { say "no $name.dmg yet – run 'make' first"; continue; }
        if [ -d "/Volumes/$name" ]; then
            say "$name is already mounted"
            continue
        fi
        hdiutil attach "$image" -quiet || fail "could not mount $name"
        say "mounted /Volumes/$name"
    done
}

# The marker folders each profile looks for. Made after mounting, because a
# FAT32 image has nothing in it until it is.
lay_out() {
    local row name fs size markers books marker
    # "${DEVICES[@]}" is never empty under set -u: the literal table above.
    for row in "${DEVICES[@]}"; do
        IFS='|' read -r name fs size markers books <<< "$row"
        [ -d "/Volumes/$name" ] || continue
        for marker in $markers; do
            # `.kobo` is a file marker on a Kobo (`.kobo/KoboReader.sqlite`),
            # and the database itself is written by `shelf-tool kobo-synthesise`
            # once there are books to describe. The folder is what goes here.
            mkdir -p "/Volumes/$name/$marker" || fail "could not make $marker on $name"
        done
        # A Kobo is recognised by its database, not by the folder, so an empty
        # placeholder goes in until the synthetic one replaces it.
        if [ "$name" = "KOBOeReader" ] && [ ! -f "/Volumes/$name/.kobo/KoboReader.sqlite" ]; then
            : > "/Volumes/$name/.kobo/KoboReader.sqlite"
        fi
        [ -n "$books" ] && mkdir -p "/Volumes/$name/$books"
        say "laid out $name: $markers"
    done
}

unmount_images() {
    local name
    while IFS= read -r name; do
        [ -d "/Volumes/$name" ] || continue
        # By name, and only the four this script makes: never end something
        # this session did not start.
        hdiutil detach "/Volumes/$name" -quiet 2>/dev/null \
            && say "detached $name" \
            || say "could not detach $name (in use?)"
    done < <(volume_names)
    local small
    for small in /Volumes/KINDLESMALL /Volumes/KindleSmall; do
        [ -d "$small" ] && hdiutil detach "$small" -quiet 2>/dev/null && say "detached $small"
    done
    return 0
}

# A nearly full Kindle, for measuring what happens when there is no room.
#
# Ballast rather than a tiny image, and that is not a stylistic choice:
# `hdiutil` refuses to make a FAT32 volume below about 40 MB on this Mac
# ("Der Vorgang ist nicht zugelassen" at 6, 12, 16 and 32 MB; 40 MB works), and
# 40 MB is more than a small transfer needs. So the card is made at the
# smallest size FAT32 allows and then filled to leave `$2` megabytes free —
# which is also closer to the real case, a reader with a year of books on it.
make_small() {
    local free_mb="${1:-3}"
    local size_mb=40
    mkdir -p "$CACHE"
    local image="$CACHE/KindleSmall.dmg"
    [ -d "/Volumes/KINDLESMALL" ] && hdiutil detach "/Volumes/KINDLESMALL" -quiet 2>/dev/null
    hdiutil create -size "${size_mb}m" -fs "MS-DOS FAT32" -volname "KindleSmall" -ov -quiet "$image" \
        || fail "could not make the small Kindle (FAT32 has a minimum size – try a larger one)"
    hdiutil attach "$image" -quiet || fail "could not mount the small Kindle"
    local mount="/Volumes/KINDLESMALL"
    [ -d "$mount" ] || mount="/Volumes/KindleSmall"
    mkdir -p "$mount/system" "$mount/documents"

    # Fill it, leaving room for the ballast file's own overhead.
    local ballast=$(( size_mb - free_mb - 2 ))
    [ "$ballast" -gt 0 ] && dd if=/dev/zero of="$mount/ballast.bin" bs=1m count="$ballast" 2>/dev/null
    say "mounted $mount (${size_mb} MB FAT32, ~${free_mb} MB free after ballast)"
    df -m "$mount" | tail -1
}

case "${1:-make}" in
    make) CACHE="${2:-$CACHE}"; make_images ;;
    mount) CACHE="${2:-$CACHE}"; mount_images; lay_out ;;
    unmount|detach) unmount_images ;;
    small) CACHE="${2:-$CACHE}"; make_small "${3:-3}" ;;
    *) echo "usage: $0 {make|mount|unmount|small} [folder] [mb]"; exit 2 ;;
esac
