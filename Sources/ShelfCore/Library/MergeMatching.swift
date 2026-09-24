import Foundation

/// Folding a title the way B3 asks: everything `DuplicateKey.foldedTitle`
/// already does, plus a shop's or a scan's own bracketed annotation, which is
/// never part of the work's own title.
public enum TitleNormalization {
    /// Each one a phrase this project has actually seen in a real library,
    /// wrapped in whatever brackets a shop happened to use — `(German
    /// Edition)`, `[eBook]`, `(Kindle Edition)`. Checked as folded words, not
    /// as a regular expression over brackets: `DuplicateKey.fold` already
    /// turns every bracket style into plain spaces, so matching the words is
    /// both simpler and blind to which punctuation a particular shop used.
    static let merchantSuffixWords: [[String]] = [
        ["german", "edition"],
        ["kindle", "edition"],
        ["deutsche", "ausgabe"],
        ["ebook"],
    ]

    /// A title folded for "is this the same work". Strips every merchant
    /// annotation found at the end, repeatedly — `"Title (German Edition)
    /// (Kindle Edition)"` sheds both — and never strips the whole title down
    /// to nothing: a title that *is* just "eBook" keeps its one word.
    public static func matchable(_ title: String) -> String {
        var words = DuplicateKey.foldedTitle(title).split(separator: " ").map(String.init)
        var changed = true
        while changed {
            changed = false
            for suffix in merchantSuffixWords
            where words.count > suffix.count && Array(words.suffix(suffix.count)) == suffix {
                words.removeLast(suffix.count)
                changed = true
            }
        }
        return words.joined(separator: " ")
    }
}

/// Folding an author's name for "is this the same person" — the *safe* half
/// of Teil C's rule only: case, accents, punctuation and word order.
///
/// `"Fitzek, Sebastian"` and `"Sebastian Fitzek"` fold to the same key. An
/// initial standing for a full first name (`"J. Zeh"` against `"Juli Zeh"`)
/// is a different, riskier claim — it needs a shared work or series to
/// confirm, which is what makes it a *proposal* a person confirms rather than
/// something two books can be matched by on their own — so it belongs to
/// "Ähnliche Schreibweisen…" itself (Teil C2), not to this type.
public enum AuthorNameFold {
    public static func normalized(_ name: String) -> String {
        DuplicateKey.fold(name).split(separator: " ").sorted().joined(separator: " ")
    }
}

/// A group of books B3 calls "sicher genug zum Zusammenführen" — the same
/// work, safely enough to merge without a person's own judgement.
public struct MergeGroup: Equatable, Sendable {
    public var bookIDs: [UUID]

    public init(bookIDs: [UUID]) {
        self.bookIDs = bookIDs
    }
}

/// Grouping a library's books into safe merge candidates, per B3.
///
/// Two ways in, and only two: the same valid ISBN, or the same normalised
/// title and first author with nothing that contradicts it. Everything else
/// — a shared title with a different author, a different language, a
/// conflicting ISBN — is left alone and is `Duplicates`' or `Possible
/// Duplicates`' business to show, never this type's to guess past.
public enum MergeCandidates {
    /// `entries` should be the whole library (or the whole set a caller wants
    /// considered) — a group is only ever built from books actually being
    /// compared together, never inferred from one alone.
    public static func certainGroups(among entries: [LibraryEntry]) -> [MergeGroup] {
        var byISBN: [String: [LibraryEntry]] = [:]
        for entry in entries {
            if let isbn = entry.book.isbn, ISBN.isValid(isbn) {
                byISBN[isbn, default: []].append(entry)
            }
        }

        var groups = byISBN.values.filter { $0.count > 1 }.map { Array($0) }
        // A book already grouped by ISBN is not asked again under a looser
        // rule — the same book landing in two groups is not a shape the
        // runner this feeds should ever have to resolve.
        let alreadyGrouped = Set(groups.flatMap { $0.map(\.id) })

        // Every book not already ISBN-grouped, whether it has no ISBN at all
        // or one that simply matched nobody else's — a book carrying an ISBN
        // nothing else shares is not a *conflict* with a sibling that has
        // none, only a gap, and `isbnsAgree` below is what actually catches
        // two genuinely different ISBNs.
        var byTitleAuthor: [String: [LibraryEntry]] = [:]
        for entry in entries where !alreadyGrouped.contains(entry.id) {
            let key =
                "\(TitleNormalization.matchable(entry.book.title))|"
                + AuthorNameFold.normalized(entry.book.primaryAuthor)
            byTitleAuthor[key, default: []].append(entry)
        }
        for candidates in byTitleAuthor.values
        where candidates.count > 1 && languagesAgree(candidates) && isbnsAgree(candidates) {
            groups.append(candidates)
        }

        return groups.map { MergeGroup(bookIDs: $0.map(\.id)) }
    }

    /// No two non-empty languages disagree, once `LanguageCode.normalised`
    /// has had its say. Two files of the very same book routinely disagree
    /// on the *code* rather than the language — a MOBI's EXTH record says
    /// `eng`, an EPUB's `dc:language` says `en` — and comparing the raw
    /// strings would call that a different edition. An empty language is not
    /// a conflict either way: it is a gap this run might fill, not a claim
    /// about which edition the book is.
    private static func languagesAgree(_ entries: [LibraryEntry]) -> Bool {
        Set(entries.compactMap(\.book.language).filter { !$0.isEmpty }.map(LanguageCode.normalised)).count <= 1
    }

    /// A conflicting ISBN means two different editions, whatever the title
    /// and author agree on — checked again here because this branch is
    /// reached by books that individually lack a *usable* one, and two of
    /// them could still each carry a different unusable-looking string that
    /// is nonetheless evidence they disagree.
    private static func isbnsAgree(_ entries: [LibraryEntry]) -> Bool {
        Set(entries.compactMap(\.book.isbn)).count <= 1
    }
}
