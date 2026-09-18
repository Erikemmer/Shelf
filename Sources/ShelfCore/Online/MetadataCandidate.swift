import Foundation

/// One suggestion from one service, already in Shelf's own words.
///
/// The readers turn two quite different JSON shapes into this, so everything
/// downstream — the scoring, the comparison, the sheet — sees one thing. A
/// candidate is *never* written anywhere on its own: it becomes a change to a
/// `Book` only through `MetadataMerge`, field by field, with a person agreeing
/// to each one (CONCEPT §9).
public struct MetadataCandidate: Identifiable, Equatable, Sendable {
    /// The service's own id, prefixed with the service — two services can and
    /// do use the same number.
    public let id: String
    public let source: MetadataSource
    public var title: String
    public var authors: [String]
    public var series: SeriesRef?
    public var publisher: String?
    public var published: Date?
    /// As the service printed it: "2019", "2019-04", "2019-04-23". Kept beside
    /// the parsed date because the comparison shows what the service said, not
    /// what Shelf made of it.
    public var publishedText: String?
    public var language: String?
    public var subjects: [String]
    public var summary: String?
    public var identifiers: [String: String]
    public var coverURL: URL?
    /// Not a field of a book. Kept because it is the one number that tells an
    /// abridgement from the book it was cut out of, and the list shows it.
    public var pageCount: Int?

    /// Whether this record is about **one edition** or about a *work*.
    ///
    /// Google Books answers a volume: one printing, one publisher, one
    /// language, one date. Open Library's search answers a **work** — every
    /// edition of it rolled together — and then hands out one publisher, one
    /// language and one year from among them, with no guarantee they belong to
    /// the same printing or to the book on the disk.
    ///
    /// The Sprint 6 screenshot of *Fantastic Mr Fox* is what this field is for:
    /// the work record offered `Caedmon Audio Cassette` as the publisher, `ja`
    /// as the language and **1917** as the year, for a Puffin paperback. All
    /// three were drawn correctly as what the service said; the year, being the
    /// only one that filled an empty field, was ticked for the person. It is
    /// not any more (`MetadataMerge`).
    public var describesOneEdition: Bool

    public init(
        id: String,
        source: MetadataSource,
        title: String,
        authors: [String] = [],
        series: SeriesRef? = nil,
        publisher: String? = nil,
        published: Date? = nil,
        publishedText: String? = nil,
        language: String? = nil,
        subjects: [String] = [],
        summary: String? = nil,
        identifiers: [String: String] = [:],
        coverURL: URL? = nil,
        pageCount: Int? = nil,
        describesOneEdition: Bool = true
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.authors = authors
        self.series = series
        self.publisher = publisher
        self.published = published
        self.publishedText = publishedText
        self.language = language
        self.subjects = subjects
        self.summary = summary
        self.identifiers = identifiers
        self.coverURL = coverURL
        self.pageCount = pageCount
        self.describesOneEdition = describesOneEdition
    }

    /// The line under the title in the candidate list.
    public var subtitle: String {
        var parts: [String] = []
        if !authors.isEmpty { parts.append(authors.joined(separator: " & ")) }
        if let publisher { parts.append(publisher) }
        if let year = publishedText ?? published.map({ String(MetadataScore.year(of: $0)) }) {
            parts.append(year)
        }
        if let isbn = identifiers["isbn"] { parts.append("ISBN \(isbn)") }
        return parts.joined(separator: " · ")
    }
}

/// How well a candidate answers the question that was asked.
///
/// A rule, in the core, with a test — because "which of these nine is the book
/// on my disk" is the decision the whole feature turns on, and a list in the
/// wrong order is a list that invites the wrong answer. The number is shown in
/// the sheet as well as sorted on, so a weak best match looks weak rather than
/// looking like the answer.
public enum MetadataScore {
    /// 0…100.
    ///
    /// - An ISBN that matches the one asked for is the edition, and nothing
    ///   beats it: 100.
    /// - Otherwise the title carries most of it, the author the rest, and
    ///   agreeing on nothing at all scores nothing.
    public static func score(_ candidate: MetadataCandidate, against query: MetadataQuery) -> Int {
        switch query {
        case .isbn(let wanted):
            let matches = candidate.identifiers.values.contains { ISBN.normalised($0) == wanted }
            // A service asked by ISBN sometimes answers with a record that does
            // not repeat the ISBN back. That is still the record for that ISBN,
            // so it keeps a high score — but below one that says so.
            return matches ? 100 : 85
        case .titleAuthor(let title, let author):
            let titleScore = similarity(title, candidate.title) * 70
            guard let author, let best = candidate.authors.map({ similarity(author, $0) }).max() else {
                return Int((titleScore).rounded())
            }
            return Int((titleScore + best * 30).rounded())
        }
    }

    /// How alike two names are, 0…1.
    ///
    /// Shared **words**, weighed by how long they are, against the shorter of
    /// the two names — and then damped by how differently long the two names
    /// are.
    ///
    /// Three things had to be true at once, and each of them broke a simpler
    /// rule:
    ///
    /// - *"Clean Code" and "Clean Code: A Handbook of Agile Software
    ///   Craftsmanship" are one book.* An edit distance says they are barely
    ///   related; counting against the shorter name says they are identical.
    /// - *"Dune" and "Dune Messiah" are two books.* Counting against the
    ///   shorter name alone scores them identical too, which put the sequel
    ///   level with the book in the candidate list. The length damping is what
    ///   separates them: 100 against 87.
    /// - *"The Left Hand of Darkness" and "The Dispossessed" share only "the".*
    ///   Counting words, that is half of the shorter name and scores 65.
    ///   Counting **letters**, it is three of fifteen and scores 42 — because a
    ///   three-letter article is not evidence and a twelve-letter title is.
    ///
    /// The fold is `DuplicateKey`'s, the same one the duplicate collection
    /// uses, so "alike" means one thing in this program.
    static func similarity(_ left: String, _ right: String) -> Double {
        let ours = words(left)
        let theirs = words(right)
        guard !ours.isEmpty, !theirs.isEmpty else { return 0 }

        let shared = ours.intersection(theirs).reduce(0) { $0 + $1.count }
        let ourWeight = ours.reduce(0) { $0 + $1.count }
        let theirWeight = theirs.reduce(0) { $0 + $1.count }
        let smaller = Double(min(ourWeight, theirWeight))
        let larger = Double(max(ourWeight, theirWeight))
        return (Double(shared) / smaller) * (0.7 + 0.3 * (smaller / larger))
    }

    static func words(_ text: String) -> Set<String> {
        Set(DuplicateKey.fold(text).split(separator: " ").map(String.init))
    }

    /// The candidates of both services in one list, best first.
    ///
    /// Ties are broken by the service that answered, in `MetadataSource`'s own
    /// order, so the list is the same list on every run — a candidate list that
    /// shuffles between two equally good answers is a list nobody can point at
    /// in a bug report.
    public static func ranked(
        _ candidates: [MetadataCandidate], for query: MetadataQuery
    ) -> [(candidate: MetadataCandidate, score: Int)] {
        candidates
            .map { ($0, score($0, against: query)) }
            .sorted { left, right in
                if left.1 != right.1 { return left.1 > right.1 }
                let ours = MetadataSource.allCases.firstIndex(of: left.0.source) ?? 0
                let theirs = MetadataSource.allCases.firstIndex(of: right.0.source) ?? 0
                if ours != theirs { return ours < theirs }
                return left.0.id < right.0.id
            }
    }

    static func year(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.component(.year, from: date)
    }
}

/// Which records may stand side by side in **one** comparison.
///
/// The sheet shows a person one book's fields. Putting two services' answers on
/// it is only honest if both answers are about the same *edition* — otherwise a
/// row would offer the publisher of a different printing under the name of a
/// service that never claimed anything of the sort.
///
/// The test is an ISBN and nothing else. It was tempting to pair the two
/// services' best answers to a title search by how alike they look, and
/// `MetadataScore` cannot carry that weight: "Clean Code" against "Clean
/// Code: A Handbook of Agile Software Craftsmanship" scores **83**, and "Dune"
/// against "Dune Messiah" scores **87** — the sequel scores *higher* than the
/// subtitle, because the author agrees in both. Any threshold that paired the
/// first would pair the second, and a book's publisher would be offered from
/// its sequel's record. So a title search shows one service's answers, each
/// named, and that is the whole of it.
public enum EditionMatch {
    /// Whether two records describe the same edition.
    ///
    /// - Both carry an ISBN: they agree, or they do not.
    /// - The question *was* an ISBN and one of them is silent about it: both
    ///   services were asked that ISBN, so a record that contradicts nothing is
    ///   an answer to it.
    /// - Otherwise: no. Two title-search answers are two guesses.
    public static func sameEdition(
        _ one: MetadataCandidate, _ other: MetadataCandidate, asked query: MetadataQuery
    ) -> Bool {
        let ours = one.identifiers["isbn"].map(ISBN.normalised)
        let theirs = other.identifiers["isbn"].map(ISBN.normalised)
        if let ours, let theirs { return ours == theirs }
        guard case .isbn(let wanted) = query else { return false }
        return (ours ?? wanted) == wanted && (theirs ?? wanted) == wanted
    }

    /// The chosen record, plus each *other* service's best answer about the
    /// same edition — in `MetadataSource` order, one per service.
    ///
    /// Best, not all: a service that offered four editions of one book has one
    /// opinion about it as far as the comparison is concerned, and four lines
    /// per field would be a table rather than a decision.
    public static func comparison(
        of chosen: MetadataCandidate,
        among ranked: [(candidate: MetadataCandidate, score: Int)],
        asked query: MetadataQuery
    ) -> [MetadataCandidate] {
        var records = [chosen]
        for source in MetadataSource.allCases where source != chosen.source {
            let best = ranked.first {
                $0.candidate.source == source && sameEdition(chosen, $0.candidate, asked: query)
            }
            if let best { records.append(best.candidate) }
        }
        return records
    }
}
