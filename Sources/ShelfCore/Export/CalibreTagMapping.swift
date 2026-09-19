import Foundation

/// The two things Shelf keeps that Calibre cannot read, written as tags it can.
///
/// Shelf stores the read status and shelf membership in each `metadata.opf` as
/// `<meta name="shelf:read">` and `<meta name="shelf:shelves">`. Calibre
/// **ignores a meta it does not know** — which is exactly what makes it safe
/// to write them into a library Calibre also reads, and exactly why they do
/// not survive the way back (`docs/RUNBOOK.md` §6, measured in Sprint 7).
///
/// The way back could have been fixed by writing a Calibre custom column
/// instead, and it was not: a custom column has to be *declared* in Calibre's
/// own `metadata.db` before a value in an OPF means anything, and Shelf never
/// writes to `metadata.db` (ADR 0009). A tag needs no declaration.
///
/// So this is a **mapping and not the fields**, and everything about it says
/// so: the prefix is visible, the dialogue explains it in a sentence, and
/// Shelf's own metas are still written beside the tags. Importing such an
/// export back into Shelf therefore loses nothing and gains a handful of tags
/// that are legible for what they are.
public enum CalibreTagMapping {

    /// What a shelf tag starts with: `Shelf/Fiction/Sci-Fi`.
    ///
    /// Calibre has hierarchical tags of its own and displays exactly this
    /// shape as a tree, so a mapped shelf reads there very much as it reads
    /// here. The separator is the same slash `ShelfTree` uses, which is the
    /// reason a shelf's *name* may not contain one (ADR 0008, decision 4).
    public static let shelfPrefix = "Shelf"

    /// The tag a book that has been read gets.
    public static let readTag = "Read"

    /// The book as it should be written into an exported OPF: the same book,
    /// with the mapped tags added.
    ///
    /// Added, never replacing: a book's real tags are its own, and an export
    /// that quietly dropped them to make room for these would be losing data
    /// in the one operation whose whole purpose is not to.
    public static func mapped(_ book: Book) -> Book {
        var mapped = book
        var tags = book.tags
        for shelf in book.shelves {
            let tag = "\(shelfPrefix)\(ShelfTree.pathSeparator)\(shelf)"
            if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags.append(tag)
            }
        }
        if book.isRead, !tags.contains(where: { $0.caseInsensitiveCompare(readTag) == .orderedSame }) {
            tags.append(readTag)
        }
        mapped.tags = tags.sorted()
        return mapped
    }

    /// Whether a tag is one of ours rather than one somebody typed. What an
    /// import back into Shelf would use if it ever wanted to undo the mapping
    /// — it does not need to, because the real fields are written too, and
    /// this is here so the question has an answer in one place.
    public static func isMapped(_ tag: String) -> Bool {
        tag.caseInsensitiveCompare(readTag) == .orderedSame
            || tag.lowercased().hasPrefix("\(shelfPrefix.lowercased())\(ShelfTree.pathSeparator)")
    }
}
