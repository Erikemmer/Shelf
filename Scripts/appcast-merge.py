#!/usr/bin/env python3
"""Splices one freshly generated appcast item into a channel's own
accumulated feed, leaving every previously published item exactly as it
was — its download URL included.

Why this exists: Sparkle's own `generate_appcast` applies its
`--download-url-prefix` to *every* archive it finds in the directory it is
pointed at, old and new alike — confirmed by reading its own source
(`Appcast.swift`: `for update in allUpdates { update.downloadUrlPrefix =
downloadURLPrefix }`), and by a local dry run against a second, throwaway
"1.1.0-rc2": the existing "1.1.0-rc1" item came back rewritten to
`.../v1.1.0-rc2/Shelf-1.1.0-rc1-unsigned.zip`, a path nothing was ever
uploaded to (docs/BACKLOG.md / `CHANGELOG.md`, Sprint 15, Teil B). Pointing
`generate_appcast` at the whole accumulated archive folder on every release
is what causes this — an older entry's already-correct URL only survives if
nothing ever asks the tool to touch it again.

The fix: `generate_appcast` is only ever handed the *one* new archive, in a
directory of its own, so the URL it computes is correct for that release
alone. This script then merges that single new `<item>` into the existing
feed by hand — every other item is moved, not regenerated, so its markup
(URL, signature, release notes) survives untouched.

Usage: appcast-merge.py <existing-appcast> <new-item-appcast> <output> [--maximum-versions N]

<existing-appcast> may not exist yet (the very first release on a channel);
then the freshly generated, single-item feed becomes the whole appcast.
<maximum-versions> matches `generate_appcast`'s own default (3) and prunes
the same way: oldest <sparkle:version> first. 0 keeps every item.
"""

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def load(path: Path) -> ET.Element | None:
    if not path.exists():
        return None
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    return ET.parse(path, parser=parser).getroot()


def version_of(item: ET.Element) -> int:
    node = item.find(f"{{{SPARKLE_NS}}}version")
    try:
        return int(node.text) if node is not None and node.text else 0
    except ValueError:
        return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("existing", help="the channel's currently published appcast (may not exist yet)")
    parser.add_argument("new_item", help="a fresh appcast holding only the release just made")
    parser.add_argument("output", help="where the merged appcast is written")
    parser.add_argument("--maximum-versions", type=int, default=3)
    args = parser.parse_args()

    new_root = load(Path(args.new_item))
    if new_root is None:
        sys.exit(f"appcast-merge: {args.new_item}: nothing to merge in")
    new_channel = new_root.find("channel")
    new_items = new_channel.findall("item")
    if not new_items:
        sys.exit(f"appcast-merge: {args.new_item}: no <item> in the freshly generated appcast")
    new_versions = {version_of(item) for item in new_items}

    existing_root = load(Path(args.existing))
    if existing_root is None:
        # The first release on this channel: the fresh, single-item feed
        # generate_appcast just produced is already the whole appcast.
        root = new_root
        kept = new_items
    else:
        channel = existing_root.find("channel")
        old_items = [item for item in channel.findall("item") if version_of(item) not in new_versions]
        for item in channel.findall("item"):
            channel.remove(item)
        merged = new_items + old_items
        merged.sort(key=version_of, reverse=True)
        kept = merged if args.maximum_versions <= 0 else merged[: args.maximum_versions]
        for item in kept:
            channel.append(item)
        root = existing_root

    ET.indent(root, space="    ")
    Path(args.output).write_bytes(
        b'<?xml version="1.0" encoding="utf-8" standalone="yes"?>\n' + ET.tostring(root, encoding="utf-8"))
    print(f"appcast-merge: {len(kept)} item(s) written to {args.output}")


if __name__ == "__main__":
    main()
