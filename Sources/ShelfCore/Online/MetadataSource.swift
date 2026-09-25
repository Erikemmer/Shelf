import Foundation

/// Where a metadata suggestion came from.
///
/// Two services, both free and both without an API key (CONCEPT §9). A key
/// would be a secret in a shipped app, which is a secret everybody has.
///
/// They are asked in this order and both are always asked: they disagree often
/// enough to be worth both. Open Library has the better subjects and the better
/// series; Google Books has a description for far more books and is the only one
/// of the two that answers for most German titles.
public enum MetadataSource: String, CaseIterable, Sendable, Codable, Hashable {
    case openLibrary
    case googleBooks

    /// What the candidate list calls it.
    public var name: String {
        switch self {
        case .openLibrary: return "Open Library"
        case .googleBooks: return "Google Books"
        }
    }

    /// Used as a folder name in the response cache and as a fixture prefix, so
    /// it must stay a plain lower-case word.
    public var slug: String {
        switch self {
        case .openLibrary: return "openlibrary"
        case .googleBooks: return "googlebooks"
        }
    }
}

/// What is being asked, and it is one of exactly two questions.
///
/// **ISBN first, and title + author only when there is no ISBN** (CONCEPT §9).
/// An ISBN names one edition; a title and an author name a book, of which there
/// may be nine editions and a translation. Asking by title when an ISBN is
/// there would throw away the only exact key the book has.
public enum MetadataQuery: Equatable, Sendable, Hashable {
    case isbn(String)
    case titleAuthor(title: String, author: String?)

    /// The question to ask about this book, or `nil` when there is nothing to
    /// ask with — a book with no ISBN and no title cannot be looked up, and
    /// asking anyway would fetch somebody else's book.
    public static func about(_ book: Book) -> MetadataQuery? {
        if let isbn = book.identifiers["isbn"], ISBN.isValid(isbn) {
            return .isbn(ISBN.normalised(isbn))
        }
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let author = book.authors.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .titleAuthor(title: title, author: (author?.isEmpty ?? true) ? nil : author)
    }

    /// What the sheet says it is looking for.
    public var description: String {
        switch self {
        case .isbn(let value): return "ISBN \(value)"
        case .titleAuthor(let title, let author):
            return author.map { "“\(title)” by \($0)" } ?? "“\(title)”"
        }
    }

    /// The part of the cache key that is the question. Folded, so that two
    /// spellings of one title are one question and the same answer is not
    /// fetched twice.
    var cacheToken: String {
        switch self {
        case .isbn(let value): return "isbn-\(value)"
        case .titleAuthor(let title, let author):
            return "ta-\(DuplicateKey.fold(title))-\(DuplicateKey.fold(author ?? ""))"
        }
    }
}

/// One HTTP request, built but not made.
///
/// Built in the core so the URL is a thing a test can look at, and made in the
/// app, which owns `URLSession` (docs/ARCHITECTURE.md). Everything that can be
/// wrong about an online lookup — which URL, how often, what to do with a 503,
/// whether this was asked before — is a rule and lives here; the socket does
/// not.
public struct MetadataRequest: Equatable, Sendable {
    public let source: MetadataSource
    public let url: URL
    /// Where the answer is kept, so the same ISBN is not asked twice
    /// (CONCEPT §9). A file name, hence folded and hashed rather than the raw
    /// title.
    public let cacheKey: String

    public init(source: MetadataSource, url: URL, cacheKey: String) {
        self.source = source
        self.url = url
        self.cacheKey = cacheKey
    }
}

/// The two services' URLs, as a rule rather than as string interpolation spread
/// through a view.
public enum MetadataEndpoint {
    /// How many candidates a title search asks for. Ten is what fits a list a
    /// person reads before choosing; more is a scroll through guesses.
    public static let searchLimit = 10

    public static func requests(for query: MetadataQuery) -> [MetadataRequest] {
        MetadataSource.allCases.compactMap { request(for: query, from: $0) }
    }

    public static func request(for query: MetadataQuery, from source: MetadataSource) -> MetadataRequest? {
        guard let url = url(for: query, from: source) else { return nil }
        return MetadataRequest(source: source, url: url, cacheKey: cacheKey(query, source))
    }

    /// A stable, short file name for the pair. The question is hashed because a
    /// title can hold a slash and a file name cannot.
    static func cacheKey(_ query: MetadataQuery, _ source: MetadataSource) -> String {
        let token = "\(source.slug)/\(query.cacheToken)"
        let hasher = PortableSHA256Hasher()
        hasher.update(Data(token.utf8))
        return "\(source.slug)-\(hasher.finish().prefix(32))"
    }

    static func url(for query: MetadataQuery, from source: MetadataSource) -> URL? {
        switch (source, query) {
        case (.openLibrary, .isbn(let isbn)):
            // **`/search.json`, not `/api/books`.** The endpoint CONCEPT §9
            // names for an ISBN answered HTTP 404 with an empty body to every
            // ISBN tried, including ones Open Library's own search finds
            // (ADR 0015). The search answers the same book in the same shape
            // the title question gets, so there is one reader rather than two.
            return url(
                "https://openlibrary.org/search.json",
                [("q", "isbn:\(isbn)"), ("limit", "1"), ("fields", openLibraryFields)])
        case (.openLibrary, .titleAuthor(let title, let author)):
            var items = [("title", title), ("limit", String(searchLimit))]
            if let author { items.append(("author", author)) }
            // Named fields, because the default answer carries every edition of
            // every work and is megabytes for a common title.
            items.append(("fields", openLibraryFields))
            return url("https://openlibrary.org/search.json", items)
        case (.googleBooks, .isbn(let isbn)):
            return url("https://www.googleapis.com/books/v1/volumes", [("q", "isbn:\(isbn)")])
        case (.googleBooks, .titleAuthor(let title, let author)):
            var terms = ["intitle:\(title)"]
            if let author { terms.append("inauthor:\(author)") }
            return url(
                "https://www.googleapis.com/books/v1/volumes",
                [("q", terms.joined(separator: " ")), ("maxResults", String(searchLimit))])
        }
    }

    /// Exactly the fields the reader reads. Asking for the default answer
    /// instead costs megabytes for a common title, all of it thrown away.
    static let openLibraryFields =
        "key,title,subtitle,author_name,first_publish_year,publisher,language,isbn,cover_i,subject,"
        + "number_of_pages_median"

    /// Only the fields Teil B3's own edition-key check reads: whether the
    /// ASIN named exactly one work and, inside it, exactly one edition.
    static let asinSearchFields = "key,title,edition_key,isbn,id_amazon"

    // MARK: Teil B2/B3 — the edition-level endpoints, outside the ordinary
    // two-service loop above. `MetadataFetcher` calls these directly, only
    // from `FillMissingFields`' own ISBN/ASIN branches — never from
    // `requests(for:)`, so every existing caller of the ordinary lookup is
    // unaffected by their existence.

    /// Open Library's own per-ISBN edition endpoint. `/isbn/<ISBN>.json`
    /// redirects to `/books/<OLID>.json`; `URLSessionTransport` follows
    /// redirects the way any browser would, so this is the one URL to ask.
    public static func editionRequest(forISBN isbn: String) -> MetadataRequest? {
        guard let url = URL(string: "https://openlibrary.org/isbn/\(isbn).json") else { return nil }
        return MetadataRequest(source: .openLibrary, url: url, cacheKey: hashedKey("openlibrary-edition", isbn))
    }

    /// The same edition record, asked by the key Teil B3's own ASIN search
    /// already named — no redirect needed, because the key is exact.
    public static func editionByKeyRequest(_ editionKey: String) -> MetadataRequest? {
        guard let url = URL(string: "https://openlibrary.org/books/\(editionKey).json") else { return nil }
        return MetadataRequest(
            source: .openLibrary, url: url, cacheKey: hashedKey("openlibrary-edition-key", editionKey))
    }

    /// Teil B3's first hop: does Open Library carry this ASIN at all, and
    /// naming how many works and editions — the uniqueness check A2 asked
    /// for, before any edition-level field is ever trusted from it.
    public static func asinSearchRequest(asin: String) -> MetadataRequest? {
        guard
            let url = url(
                "https://openlibrary.org/search.json", [("q", "id_amazon:\(asin)"), ("fields", asinSearchFields)])
        else { return nil }
        return MetadataRequest(source: .openLibrary, url: url, cacheKey: hashedKey("openlibrary-asin-search", asin))
    }

    /// A work's own record — `/works/<key>.json` — Teil B1's own source for
    /// a description Open Library's search never carries.
    public static func workRequest(key: String) -> MetadataRequest? {
        guard let url = URL(string: "https://openlibrary.org\(key).json") else { return nil }
        return MetadataRequest(source: .openLibrary, url: url, cacheKey: hashedKey("openlibrary-work", key))
    }

    private static func hashedKey(_ namespace: String, _ token: String) -> String {
        let hasher = PortableSHA256Hasher()
        hasher.update(Data("\(namespace)/\(token)".utf8))
        return "\(namespace)-\(hasher.finish().prefix(32))"
    }

    private static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }
}
