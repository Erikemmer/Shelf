import Foundation

/// Calibre as a second source for "Fill Missing Fields…" — Teil B4.
///
/// Matched by identity, never by a guess: the UUID Calibre gave the book at
/// import (CONCEPT §5.3 — "the identity is a UUID, taken over from Calibre
/// when there is one") or, failing that, an equal, checksum-valid ISBN.
/// Every value then goes through the same field rule the inspector and the
/// online sources already use (`BookField`, `TagEdit`, `IdentifierEdit`): a
/// value from Calibre is checked exactly as a typed one, and only an empty
/// field is ever filled — the same "never overwrite what the book already
/// has" rule ADR 0015 already holds online sources to.
public enum CalibreFieldSource {
    /// The Calibre book that is this Shelf book, or `nil` when the library
    /// holds nothing that matches. Title alone is never enough — CONCEPT
    /// §5.3 already settled this book's identity at import, and a title can
    /// belong to two different editions of two different books.
    public static func matching(_ book: Book, in library: CalibreLibrary) -> CalibreBook? {
        if let byUUID = library.books.first(where: { $0.book.id == book.id }) { return byUUID }
        guard let isbn = book.identifiers["isbn"], ISBN.isValid(isbn) else { return nil }
        let wanted = ISBN.normalised(isbn)
        return library.books.first {
            guard let theirs = $0.book.identifiers["isbn"], ISBN.isValid(theirs) else { return false }
            return ISBN.normalised(theirs) == wanted
        }
    }

    /// Only empty fields, only these six plus tags, never title or authors —
    /// Calibre is asked to fill a gap, not to correct an identity this book
    /// already has.
    public static func fill(
        _ book: Book, from match: CalibreBook
    ) -> (book: Book, proposals: [FillMissingFields.Proposal]) {
        var working = book
        var proposals: [FillMissingFields.Proposal] = []
        let theirs = match.book

        func apply(_ field: BookField, proposed: String?) {
            let current = field.text(of: working)
            guard current.isEmpty, let proposed,
                !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            guard case .changed(let updated) = field.apply(proposed, to: working) else { return }
            working = updated
            proposals.append(
                FillMissingFields.Proposal(
                    label: field.label, current: current, proposed: proposed, source: .calibre))
        }

        // Calibre's own `comments` are real, rich HTML almost every time —
        // reduced to plain paragraphs before it is offered at all, never
        // shown to a person (or stored) as a wall of markup.
        apply(.description, proposed: theirs.description.map(HTMLToPlainParagraphs.reduce))
        apply(.seriesName, proposed: theirs.series?.name)
        apply(.seriesIndex, proposed: theirs.series?.index.map(BookField.number))
        apply(.publisher, proposed: theirs.publisher)
        apply(.language, proposed: theirs.language)
        apply(.published, proposed: theirs.published.map(BookField.day))

        if let isbn = theirs.identifiers["isbn"], ISBN.isValid(isbn),
            (working.identifiers["isbn"] ?? "").isEmpty,
            case .changed(let updated) = IdentifierEdit.set(scheme: "isbn", value: ISBN.normalised(isbn), in: working)
        {
            working = updated
            proposals.append(
                FillMissingFields.Proposal(
                    label: "ISBN", current: "", proposed: ISBN.normalised(isbn), source: .calibre))
        }

        // Tags are the one field this source *adds* rather than fills —
        // but, unlike an online source, only when the book has none of its
        // own at all, never alongside them (the field rule Teil B4 asks
        // for, narrower than the online "add regardless, never pre-tick"
        // rule: Calibre's own tags are trusted enough to apply outright,
        // exactly because the match itself already is, but only where they
        // would not sit beside — and so look like an addition to — tags a
        // person chose).
        if working.tags.isEmpty, !theirs.tags.isEmpty {
            for tag in theirs.tags {
                if case .changed(let updated) = TagEdit.add(tag, to: working) { working = updated }
            }
            if !working.tags.isEmpty {
                proposals.append(
                    FillMissingFields.Proposal(
                        label: "Tags", current: "", proposed: working.tags.joined(separator: ", "),
                        source: .calibre))
            }
        }

        return (working, proposals)
    }
}
