import Foundation

/// Open Library's search answer, turned into candidates.
///
/// **One endpoint for both questions**, which is not what CONCEPT §9 planned.
/// `/api/books?bibkeys=ISBN:…` — the endpoint the concept names for an ISBN —
/// answered **HTTP 404 with an empty body** to every ISBN tried on 18 September
/// 2026, including ISBNs whose books Open Library's own search finds
/// ([ADR 0015](../../../docs/adr/0015-online-metadata-two-sources-field-by-field.md)).
/// `/search.json?q=isbn:…` answers the same book in the same `docs` shape the
/// title search uses, so an ISBN and a title are one reader and one shape here.
///
/// Read tolerantly: a field that is missing is missing, never an error. A
/// service that renames one field must not cost the other eleven — the same
/// rule the EPUB reader follows (docs/ARCHITECTURE.md, "Reading a format").
public enum OpenLibraryReader {
    public static func candidates(from data: Data, answering query: MetadataQuery) throws -> [MetadataCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataReadFailure.notAnObject(.openLibrary)
        }
        guard let docs = root["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { candidate($0, answering: query) }
    }

    static func candidate(_ doc: [String: Any], answering query: MetadataQuery) -> MetadataCandidate? {
        guard let title = string(doc["title"]), let key = string(doc["key"]) else { return nil }

        var identifiers: [String: String] = [:]
        if let ol = key.split(separator: "/").last { identifiers["openlibrary"] = String(ol) }
        if let isbn = isbn(of: doc, answering: query) { identifiers["isbn"] = isbn }

        let year = doc["first_publish_year"] as? Int
        return MetadataCandidate(
            id: "openlibrary:" + key,
            source: .openLibrary,
            title: string(doc["subtitle"]).map { "\(title): \($0)" } ?? title,
            authors: (doc["author_name"] as? [String]) ?? [],
            publisher: (doc["publisher"] as? [String])?.first,
            published: year.flatMap { OPFDate.parse(String($0)) },
            publishedText: year.map(String.init),
            language: (doc["language"] as? [String])?.first.map(LanguageCode.normalised),
            subjects: Array(((doc["subject"] as? [String]) ?? []).prefix(maximumSubjects)),
            // The search carries no description at all. Said out loud rather
            // than left to be noticed: for a description, Google Books is the
            // service that answers, which is half of why both are asked.
            summary: nil,
            identifiers: identifiers,
            coverURL: (doc["cover_i"] as? Int).flatMap {
                URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg")
            },
            pageCount: doc["number_of_pages_median"] as? Int,
            // A *work*, not an edition: the publisher, the language and the
            // year below are one of the work's editions picked at the service's
            // discretion. See `MetadataCandidate.describesOneEdition`.
            describesOneEdition: false
        )
    }

    /// Which of a work's ISBNs to offer.
    ///
    /// A search answers **every** ISBN of every edition — 41 of them for
    /// *Fantastic Mr Fox*, in no order worth trusting. Offering the first would
    /// propose a Chinese paperback's number for a book somebody holds in
    /// English.
    ///
    /// So: when the question *was* an ISBN and the work carries it, that is the
    /// one — the person already knows which edition they have. Otherwise the
    /// first 13-digit one, because a 13 is what the duplicate check and the
    /// next lookup want; and only if there is no 13 at all, whatever there is.
    static func isbn(of doc: [String: Any], answering query: MetadataQuery) -> String? {
        guard let isbns = doc["isbn"] as? [String], !isbns.isEmpty else { return nil }
        if case .isbn(let wanted) = query, isbns.contains(where: { ISBN.normalised($0) == wanted }) {
            return wanted
        }
        return isbns.first { ISBN.normalised($0).count == 13 } ?? isbns.first
    }

    /// A work on Open Library can carry several hundred subjects, most of them
    /// library-catalogue vocabulary. The list is the *offer*; a person still
    /// ticks it or does not, and a hundred tags behind one tick is not an offer.
    static let maximumSubjects = 12

    // MARK: Reading loosely

    static func string(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What can go wrong reading an answer, in words the status bar can show.
public enum MetadataReadFailure: Error, Equatable, Sendable {
    case notAnObject(MetadataSource)

    public var message: String {
        switch self {
        case .notAnObject(let source):
            return "\(source.name) answered something that is not a record. Nothing was changed."
        }
    }
}
