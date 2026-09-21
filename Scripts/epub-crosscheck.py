#!/usr/bin/env python3
"""Checks a round-tripped EPUB against its original with a completely
different implementation of ZIP and XML than Shelf's own.

`ZipReader` and `EPUBArchiveWriter` are this project's idea of what a ZIP
archive and an EPUB's OPF are. `zipfile` and `xml.etree.ElementTree` are the
standard library's, written by people who have never seen this codebase.
Three things a source archive that never used this project should agree
with a round-tripped one on:

  1. zipfile.ZipFile(...).testzip() finds no corrupt member.
  2. The entry list is exactly the same, in the same order.
  3. dc:title in content.opf, found the way any generic OPF reader would
     find it (by tag, not by hard-coding this project's own namespace
     prefixes), reads the same before and after.

Usage: epub-crosscheck.py <original.epub> <roundtripped.epub>
Prints "ok: ..." and exits 0 on success; prints "FAILED: ..." and exits 1
otherwise. Called from Scripts/real-epub-proof.sh, not meant to be run by
hand as part of the proof (nothing stops running it by hand too).
"""
import sys
import zipfile
import xml.etree.ElementTree as ElementTree


def opf_path(archive: zipfile.ZipFile) -> str:
    with archive.open("META-INF/container.xml") as handle:
        tree = ElementTree.parse(handle)
    for element in tree.iter():
        # Namespace-agnostic on purpose: a generic reader should not need to
        # know the exact URI this project's own writer happens to use.
        if element.tag.endswith("rootfile"):
            path = element.attrib.get("full-path")
            if path:
                return path
    raise ValueError("no rootfile in META-INF/container.xml")


def title_of(archive: zipfile.ZipFile) -> str:
    path = opf_path(archive)
    with archive.open(path) as handle:
        tree = ElementTree.parse(handle)
    for element in tree.iter():
        if element.tag.endswith("title"):
            return (element.text or "").strip()
    raise ValueError(f"no title element in {path}")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: epub-crosscheck.py <original.epub> <roundtripped.epub>")
        return 2

    original_path, roundtripped_path = sys.argv[1], sys.argv[2]

    with zipfile.ZipFile(original_path) as original, zipfile.ZipFile(roundtripped_path) as roundtripped:
        bad_member = roundtripped.testzip()
        if bad_member is not None:
            print(f"FAILED: {roundtripped_path} - testzip found a corrupt member: {bad_member}")
            return 1

        original_names = original.namelist()
        roundtripped_names = roundtripped.namelist()
        if original_names != roundtripped_names:
            print(f"FAILED: {roundtripped_path} - entry list differs from {original_path}")
            print(f"  original:      {original_names}")
            print(f"  round-tripped: {roundtripped_names}")
            return 1

        try:
            original_title = title_of(original)
            roundtripped_title = title_of(roundtripped)
        except Exception as error:
            print(f"FAILED: {roundtripped_path} - could not read a title: {error}")
            return 1

        if original_title != roundtripped_title:
            print(f"FAILED: {roundtripped_path} - title changed: {original_title!r} -> {roundtripped_title!r}")
            return 1

    print(
        f"ok: {roundtripped_path} - testzip clean, {len(roundtripped_names)} entries match, "
        f"title {original_title!r}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
