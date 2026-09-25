import Foundation

/// Teil B3's first hop: does an ASIN name **exactly one work with exactly
/// one edition** on Open Library — the uniqueness check A2 asked for, before
/// anything about that edition is trusted.
///
/// Found against the real library, 25 ASINs across two sessions (Sprint 20's
/// own five, Sprint 21's twenty more): 1 hit, and that one hit named exactly
/// one work and exactly one edition. No hit ever named more than one of
/// either — the decision rule ADR 0015's own addendum sets out — so a
/// uniqueness failure here is not expected to be common; it is checked
/// anyway, on every call, because a search answering by keyword rather than
/// by exact identifier can in principle find more than one book that once
/// carried the same ASIN on a different printing.
public enum OpenLibraryASINSearch {
    public struct Hit: Equatable, Sendable {
        public var editionKey: String
        /// Present only when the search's own restricted field list
        /// happens to carry it — Teil B2's edition endpoint is asked
        /// regardless and is the real source of an ISBN for this edition.
        public var isbn: String?
    }

    /// `nil` when the search found nothing, or found more than one work, or
    /// found one work with more than one edition — never a guess between
    /// them.
    public static func uniqueEdition(from data: Data) throws -> Hit? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataReadFailure.notAnObject(.openLibrary)
        }
        guard let docs = root["docs"] as? [[String: Any]], docs.count == 1 else { return nil }
        guard let editions = docs[0]["edition_key"] as? [String], editions.count == 1 else { return nil }
        let isbns = docs[0]["isbn"] as? [String]
        let isbn = isbns?.first { ISBN.normalised($0).count == 13 } ?? isbns?.first
        return Hit(editionKey: editions[0], isbn: isbn)
    }
}
