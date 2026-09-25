import Foundation

/// Open Library's own per-**ISBN** edition endpoint (`/isbn/<ISBN>.json`,
/// which redirects to `/books/<OLID>.json`) and its per-**edition-key** twin
/// (`/books/<OLID>.json` asked directly, once B3 already knows the key).
///
/// **This is not `/search.json`.** That endpoint answers a *work* — every
/// edition of it rolled together, `describesOneEdition: false`
/// (`OpenLibraryReader`). This one answers **one printing**: its own
/// publisher, its own `publish_date`, its own language — the three fields
/// ADR 0015 calls edition-level and refuses to trust from a work record.
/// Found by asking rather than by reading about it, the same way `/api/books`
/// was found *not* to answer an ISBN at all (Sprint 6, ADR 0015): a probe of
/// ten real ISBNs from the real library answered six, every one of the six
/// carrying `publishers`, `publish_date` and `languages` (Sprint 21, Teil A1).
///
/// Read as tolerantly as every other reader here: a field this endpoint does
/// not carry is missing, never an error.
public enum OpenLibraryEditionReader {
    public static func edition(from data: Data, isbn: String?) throws -> OpenLibraryEdition? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataReadFailure.notAnObject(.openLibrary)
        }
        // A record with no title is not a record — the same guard
        // `OpenLibraryReader.candidate` and `GoogleBooksReader.candidate` use.
        guard let title = OpenLibraryReader.string(root["title"]) else { return nil }

        let publishDate = OpenLibraryReader.string(root["publish_date"])
        let languages = root["languages"] as? [[String: Any]]
        let language = languages?.first.flatMap { OpenLibraryReader.string($0["key"]) }.map(languageCode)
        let works = root["works"] as? [[String: Any]]
        let workKey = works?.first.flatMap { OpenLibraryReader.string($0["key"]) }
        let isbns = root["isbn_13"] as? [String]
        let resolvedISBN = isbn ?? isbns?.first

        return OpenLibraryEdition(
            isbn: resolvedISBN,
            title: title,
            publisher: (root["publishers"] as? [String])?.first,
            publishedText: publishDate,
            published: publishDate.flatMap(OnlineDate.parse),
            language: language,
            workKey: workKey)
    }

    /// `"/languages/eng"` → `"eng"` → `LanguageCode.normalised`, the same
    /// folding every other language value here goes through.
    static func languageCode(_ key: String) -> String {
        LanguageCode.normalised(key.split(separator: "/").last.map(String.init) ?? key)
    }
}

/// One edition-level answer from Open Library — narrower than
/// `MetadataCandidate`: only what `/isbn/<ISBN>.json` and `/books/<OLID>.json`
/// actually carry, because that is the only thing `FillMissingFields`'
/// Teil B2/B3 ever ask this endpoint for. Never shown on its own — folded
/// into the matching `/search.json` candidate, or stands in for it when that
/// search found nothing (`EditionMerge`).
public struct OpenLibraryEdition: Equatable, Sendable {
    public var isbn: String?
    public var title: String
    public var publisher: String?
    public var publishedText: String?
    public var published: Date?
    public var language: String?
    /// `/works/OL123W`, when the record names one — the key Teil B1's own
    /// work-level description lookup is chained from.
    public var workKey: String?

    /// A standalone candidate, for when there is no `/search.json` answer to
    /// fold this into (`EditionMerge.folding`) — or the whole of what Teil B3
    /// ever offers, since an ASIN search has no work-level record of its own
    /// to fold into.
    public func asCandidate(extraIdentifiers: [String: String] = [:]) -> MetadataCandidate {
        var identifiers = extraIdentifiers
        if let isbn { identifiers["isbn"] = isbn }
        return MetadataCandidate(
            id: "openlibrary-edition:\(isbn ?? title)",
            source: .openLibrary,
            title: title,
            publisher: publisher,
            published: published,
            publishedText: publishedText,
            language: language,
            identifiers: identifiers,
            describesOneEdition: true)
    }
}

/// Folding an edition-level record into the candidates a normal lookup
/// already found.
public enum EditionMerge {
    /// Replaces the **Open Library** candidate's publisher, date and
    /// language with the edition's own — never the reverse, and never a
    /// half-merge: a field the edition record does not carry is left empty
    /// rather than inheriting the `/search.json` candidate's untrustworthy
    /// work-level guess under a now-`true` trust flag. Adds a standalone
    /// candidate instead when there is no Open Library candidate to fold
    /// into (the search found nothing, or answered something else first).
    public static func folding(
        _ edition: OpenLibraryEdition, into candidates: [MetadataCandidate]
    ) -> [MetadataCandidate] {
        guard let index = candidates.firstIndex(where: { $0.source == .openLibrary }) else {
            return candidates + [edition.asCandidate()]
        }
        var updated = candidates
        var candidate = updated[index]
        candidate.publisher = edition.publisher
        candidate.published = edition.published
        candidate.publishedText = edition.publishedText
        candidate.language = edition.language
        candidate.describesOneEdition = true
        if let isbn = edition.isbn { candidate.identifiers["isbn"] = isbn }
        updated[index] = candidate
        return updated
    }
}
