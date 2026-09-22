#!/usr/bin/env python3
"""Removes a real EPUB's cover — the image entry, its manifest <item>, and
every cover declaration (EPUB 2's <meta name="cover">, EPUB 3's
properties="cover-image", or both) — and nothing else.

Built for Sprint 11's own Fall b gap: `EPUBCoverPatch`'s "add a cover the
manifest does not have yet" branch had only ever run against synthetic
archives this project builds itself. Every real Gutenberg book Shelf has
(`Scripts/real-epubs.sh`) already carries a cover, so there was no real book
to prove Fall b against — this script makes one, with a tool that is not
Shelf's own code, the same reason `Scripts/epub-crosscheck.py` exists: a
defect Shelf's own writer and Shelf's own stripper share would never show up
by testing one against the other.

Deliberately NOT a full XML round-trip: the OPF is edited as text, removing
only the exact spans of the cover's <item> and its <meta name="cover">, so
everything else in the file — formatting, whitespace, every other element —
is untouched. A full ElementTree parse-and-reserialise would risk
reformatting the whole document for the sake of removing two tags.

Usage: strip-epub-cover.py <input.epub> <output.epub>
Prints what it removed (the cover's id, href and media-type, and which
declaration forms were found) and exits 0. Exits 1 with an explanation if
the book has no cover to strip, or its shape does not match what this
script knows how to edit safely — never guesses, never edits blindly.
"""
import re
import sys
import zipfile
import xml.etree.ElementTree as ElementTree


def opf_path(archive: zipfile.ZipFile) -> str:
    with archive.open("META-INF/container.xml") as handle:
        tree = ElementTree.parse(handle)
    for element in tree.iter():
        if element.tag.endswith("rootfile"):
            path = element.attrib.get("full-path")
            if path:
                return path
    raise ValueError("no rootfile in META-INF/container.xml")


def find_cover_id(opf_text: str) -> str | None:
    """The manifest item's own id that names the cover, from whichever
    declaration is present — EPUB 2's <meta name="cover" content="id">,
    or EPUB 3's <item ... properties="...cover-image...">."""
    meta = re.search(r'<meta\b[^>]*\bname=["\']cover["\'][^>]*\bcontent=["\']([^"\']+)["\']', opf_text)
    if meta:
        return meta.group(1)
    meta = re.search(r'<meta\b[^>]*\bcontent=["\']([^"\']+)["\'][^>]*\bname=["\']cover["\']', opf_text)
    if meta:
        return meta.group(1)
    item = re.search(
        r'<item\b(?:(?!/>).)*?\bproperties=["\'][^"\']*cover-image[^"\']*["\'](?:(?!/>).)*?/>', opf_text, re.DOTALL
    )
    if item:
        id_match = re.search(r'\bid=["\']([^"\']+)["\']', item.group(0))
        if id_match:
            return id_match.group(1)
    return None


def item_tag_for_id(opf_text: str, item_id: str) -> re.Match:
    """The exact span of the self-closing <item .../> tag whose id equals
    `item_id`, wherever its attributes fall in the tag — the same
    attribute-order independence `EPUBOPFPatch`'s own scanner has."""
    for match in re.finditer(r"<item\b[^>]*?/>", opf_text):
        if re.search(rf'\bid=["\']{re.escape(item_id)}["\']', match.group(0)):
            return match
    raise ValueError(f"no self-closing <item id=\"{item_id}\"> found in the manifest")


def meta_cover_tag(opf_text: str) -> re.Match | None:
    return re.search(r'<meta\b[^>]*\bname=["\']cover["\'][^>]*/>', opf_text)


def strip_cover(original_path: str, output_path: str) -> None:
    with zipfile.ZipFile(original_path) as source:
        opf = opf_path(source)
        opf_text = source.read(opf).decode("utf-8")

        cover_id = find_cover_id(opf_text)
        if cover_id is None:
            raise ValueError(f"{original_path}: no cover declaration found (nothing to strip)")

        item_match = item_tag_for_id(opf_text, cover_id)
        item_tag = item_match.group(0)
        href_match = re.search(r'\bhref=["\']([^"\']+)["\']', item_tag)
        media_type_match = re.search(r'\bmedia-type=["\']([^"\']+)["\']', item_tag)
        if href_match is None:
            raise ValueError(f"{original_path}: the cover's <item> has no href")
        href = href_match.group(1)
        media_type = media_type_match.group(1) if media_type_match else "?"

        folder = "/".join(opf.split("/")[:-1])
        cover_path = f"{folder}/{href}" if folder else href
        if cover_path not in source.namelist():
            raise ValueError(f"{original_path}: the manifest's own cover {cover_path} is not in the archive")

        new_opf_text = opf_text[: item_match.start()] + opf_text[item_match.end() :]
        meta_match = meta_cover_tag(new_opf_text)
        removed_meta = meta_match is not None
        if meta_match:
            new_opf_text = new_opf_text[: meta_match.start()] + new_opf_text[meta_match.end() :]

        with zipfile.ZipFile(output_path, "w") as dest:
            for info in source.infolist():
                data = source.read(info.filename)
                if info.filename == cover_path:
                    continue
                if info.filename == opf:
                    data = new_opf_text.encode("utf-8")
                compress_type = zipfile.ZIP_STORED if info.filename == "mimetype" else zipfile.ZIP_DEFLATED
                dest.writestr(info.filename, data, compress_type=compress_type)

        forms = []
        if removed_meta:
            forms.append("EPUB 2 <meta name=\"cover\">")
        if "cover-image" in item_tag:
            forms.append("EPUB 3 properties=\"cover-image\"")
        print(
            f"{original_path}: removed cover id={cover_id!r} href={cover_path!r} media-type={media_type!r}, "
            f"declaration form(s): {', '.join(forms) if forms else '(none found in the item itself)'}"
        )


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: strip-epub-cover.py <input.epub> <output.epub>")
        return 2
    try:
        strip_cover(sys.argv[1], sys.argv[2])
    except Exception as error:
        print(f"FAILED: {error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
