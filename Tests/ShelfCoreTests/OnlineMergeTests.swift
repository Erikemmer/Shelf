import Foundation
import Testing

@testable import ShelfCore

@Suite("Field by field, old against new")
struct MetadataMergeTests {
    private func candidate(
        title: String = "Dune",
        authors: [String] = ["Frank Herbert"],
        publisher: String? = "Ace",
        published: Date? = OPFDate.parse("1965-08-01"),
        language: String? = "en",
        subjects: [String] = ["science fiction", "Desert ecology"],
        summary: String? = "A boy becomes a messiah on a desert planet.",
        isbn: String? = "9780441013593",
        describesOneEdition: Bool = true
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: "openlibrary:/works/OL893415W", source: .openLibrary, title: title, authors: authors,
            publisher: publisher, published: published, language: language, subjects: subjects,
            summary: summary, identifiers: isbn.map { ["isbn": $0] } ?? [:],
            describesOneEdition: describesOneEdition)
    }

    /// By the **field**, not by the line's id: with two services one field can
    /// have two lines, so the id carries who said it as well.
    private func line(_ lines: [FieldProposal], _ id: String) throws -> FieldProposal {
        try #require(lines.first { $0.targetID == id })
    }

    /// A book that knows only its title: every line is something new, and every
    /// line is ticked.
    @Test("what fills a gap is an addition and starts ticked")
    func additions() throws {
        let book = Book(title: "Dune")
        let lines = MetadataMerge.proposals(for: book, from: candidate())

        #expect(try line(lines, "title").kind == .same)
        #expect(try line(lines, "authors").kind == .add)
        #expect(try line(lines, "publisher").kind == .add)
        #expect(try line(lines, "identifier:isbn").kind == .add)
        #expect(try line(lines, "tags").kind == .add)
        // Tags are the exception, even on a book with none: a catalogue's
        // subjects are not a person's vocabulary, so they are offered and not
        // chosen for them.
        #expect(try !line(lines, "tags").isTickedByDefault)
        #expect(lines.filter(\.isTickedByDefault).allSatisfy { $0.kind == .add })
        // The titles agree, so the line is drawn and cannot be ticked. A list
        // that showed only the differences would hide how good the match was.
        #expect(try !line(lines, "title").isTickedByDefault)
    }

    /// What the Sprint 6 screenshot of *Fantastic Mr Fox* showed: Open
    /// Library's search answers a **work**, and hands out one of its editions'
    /// publisher, language and year. For a Puffin paperback it offered
    /// "Caedmon Audio Cassette", `ja` and **1917** — and the year, being the
    /// one that filled an empty field, arrived ticked.
    @Test("a work record never pre-ticks a publisher, a language or a year")
    func workLevelFieldsAreNotTicked() throws {
        let book = Book(title: "Fantastic Mr Fox")
        let work = candidate(title: "Fantastic Mr Fox", describesOneEdition: false)
        let lines = MetadataMerge.proposals(for: book, from: work)

        for id in ["publisher", "published", "language"] {
            let line = try line(lines, id)
            #expect(line.kind == .add, "\(id) is still drawn, and still says what the service said")
            #expect(!line.isTickedByDefault, "\(id) came from a work, not from this edition")
        }
        // What is about the book rather than about a printing is unaffected.
        #expect(try line(lines, "authors").isTickedByDefault)
        #expect(try line(lines, "identifier:isbn").isTickedByDefault)
    }

    /// The rule the whole sheet turns on: what would **replace** something is
    /// never ticked for somebody. Taking over a field a person filled in is a
    /// decision about their library (ADR 0015).
    @Test("what would replace an answer the book already has starts unticked")
    func replacementsAreNotTicked() throws {
        var book = Book(title: "Dune", authors: ["F. Herbert"])
        book.publisher = "Gollancz"
        let lines = MetadataMerge.proposals(for: book, from: candidate())

        let publisher = try line(lines, "publisher")
        #expect(publisher.kind == .replace)
        #expect(publisher.current == "Gollancz")
        #expect(publisher.proposed == "Ace")
        #expect(!publisher.isTickedByDefault)
        #expect(try !line(lines, "authors").isTickedByDefault)
    }

    @Test("a field the service says nothing about is not a line at all")
    func silenceIsNotALine() {
        let lines = MetadataMerge.proposals(
            for: Book(title: "Dune"),
            from: candidate(publisher: nil, published: nil, language: nil, subjects: [], summary: nil, isbn: nil))
        #expect(!lines.contains { $0.targetID == "publisher" })
        #expect(!lines.contains { $0.targetID == "published" })
        #expect(!lines.contains { $0.targetID == "tags" })
    }

    @Test("ticking some lines changes those fields and leaves the rest alone")
    func applyingSome() throws {
        var book = Book(title: "Dune", authors: ["F. Herbert"])
        book.publisher = "Gollancz"
        let lines = MetadataMerge.proposals(for: book, from: candidate())

        let chosen = [try line(lines, "identifier:isbn"), try line(lines, "published")]
        let applied = MetadataMerge.apply(chosen, to: book)

        #expect(applied.book.identifiers["isbn"] == "9780441013593")
        #expect(applied.book.published != nil)
        // Untouched, because they were not ticked.
        #expect(applied.book.publisher == "Gollancz")
        #expect(applied.book.authors == ["F. Herbert"])
        #expect(applied.refused.isEmpty)
    }

    /// Nothing a person put on a book comes off it because a service has not
    /// heard of it.
    @Test("tags are added, never replaced")
    func tagsAreAdded() throws {
        var book = Book(title: "Dune", tags: ["favourites"])
        let lines = MetadataMerge.proposals(for: book, from: candidate())
        // Not `.replace`: applying takes nothing off the book, and the first
        // screenshot of the sheet had "would replace" written over a line that
        // replaces nothing.
        #expect(try line(lines, "tags").kind == .append)
        // And not ticked for somebody: a catalogue's subjects are not a
        // person's own vocabulary.
        #expect(try !line(lines, "tags").isTickedByDefault)
        let applied = MetadataMerge.apply([try line(lines, "tags")], to: book)

        #expect(applied.book.tags.contains("favourites"))
        #expect(applied.book.tags.contains("science fiction"))
        #expect(applied.book.tags.count == 3)

        // And a tag the book already carries in another case is not offered a
        // second time — `TagEdit`'s rule, asked before anything is drawn.
        book.tags = ["Science Fiction"]
        let again = MetadataMerge.proposals(for: book, from: candidate())
        #expect(try !line(again, "tags").proposed.lowercased().contains("science fiction"))
    }

    /// A value from the net goes through the same rule a typed one does. An
    /// ISBN with a wrong check digit is a key that matches the wrong book,
    /// whoever offered it.
    @Test("a value the field rules refuse is left out and named")
    func refusedValuesAreNamed() {
        let book = Book(title: "Dune")
        let bad = FieldProposal(
            target: .identifier("isbn"), label: "ISBN", current: "", proposed: "9780441013594",
            sources: [.openLibrary], kind: .add, isTickedByDefault: true)
        let applied = MetadataMerge.apply([bad], to: book)

        #expect(applied.book.identifiers["isbn"] == nil)
        #expect(applied.refused.count == 1)
        #expect(applied.refused.first?.message.contains("check digit") == true)
    }

    /// And one refused line does not cost the others.
    @Test("one bad value does not stop the other ten fields")
    func oneBadValueIsNotFatal() throws {
        let book = Book(title: "Dune")
        let lines = MetadataMerge.proposals(for: book, from: candidate())
        let bad = FieldProposal(
            target: .field(.title), label: "Title", current: "Dune", proposed: "",
            sources: [.googleBooks], kind: .replace, isTickedByDefault: false)
        let applied = MetadataMerge.apply([bad, try line(lines, "authors")], to: book)

        #expect(applied.book.title == "Dune")
        #expect(applied.book.authors == ["Frank Herbert"])
        #expect(applied.refused.count == 1)
    }

    /// The comparison shows what would be *stored*, not what the service
    /// printed. A date nobody could parse offers nothing rather than offering
    /// the first of January.
    @Test("a date that cannot be parsed is not offered as a date")
    func unparsableDate() {
        var loose = candidate(published: nil)
        loose.publishedText = "sometime in the sixties"
        let lines = MetadataMerge.proposals(for: Book(title: "Dune"), from: loose)
        #expect(!lines.contains { $0.targetID == "published" })
    }
}

@Suite("Dates and language codes as the services print them")
struct OnlineValueTests {
    @Test(
        "a publication date is read in every shape the two services use",
        arguments: [
            "1988-10-01", "1988-10", "1988",
            "October 1, 1988", "Oct 1, 1988", "October 1988", "1 October 1988",
        ])
    func dates(text: String) {
        #expect(OnlineDate.parse(text) != nil, "could not read “\(text)”")
    }

    @Test("what is not a date at all stays not a date")
    func notADate() {
        #expect(OnlineDate.parse("sometime in the sixties") == nil)
        #expect(OnlineDate.parse("") == nil)
    }

    /// Open Library answers `eng`, Google answers `en`, and a file says
    /// whichever its maker felt like. Without this, one service offers a
    /// difference that is not a difference.
    @Test(
        "three-letter language codes become the two-letter ones a library holds",
        arguments: [("eng", "en"), ("ger", "de"), ("deu", "de"), ("fre", "fr"), ("en", "en"), ("de", "de")])
    func languages(raw: String, expected: String) {
        #expect(LanguageCode.normalised(raw) == expected)
    }

    @Test("a code Shelf has never seen is still what the service said")
    func unknownLanguage() {
        #expect(LanguageCode.normalised("xyz") == "xyz")
    }
}

/// With two services, "what the service says" stops being a sentence. Every
/// line names who said it, and where the two say different things there are two
/// lines rather than one.
@Suite("Two services on one comparison")
struct TwoSourceComparisonTests {
    private func openLibrary(
        title: String = "Dune", publisher: String? = "Ace", subjects: [String] = ["science fiction"],
        isbn: String? = "9780441013593"
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: "openlibrary:/works/OL893415W", source: .openLibrary, title: title,
            authors: ["Frank Herbert"], publisher: publisher, subjects: subjects,
            identifiers: isbn.map { ["isbn": $0] } ?? [:])
    }

    private func googleBooks(
        title: String = "Dune", publisher: String? = "Ace", subjects: [String] = [],
        isbn: String? = "9780441013593"
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: "googlebooks:B1PxDwAAQBAJ", source: .googleBooks, title: title,
            authors: ["Frank Herbert"], publisher: publisher, subjects: subjects,
            identifiers: isbn.map { ["isbn": $0] } ?? [:])
    }

    private func lines(_ all: [FieldProposal], _ field: String) -> [FieldProposal] {
        all.filter { $0.targetID == field }
    }

    @Test("both services saying the same thing is one line that names both")
    func agreementIsOneLine() throws {
        let all = MetadataMerge.proposals(
            for: Book(title: "Dune"), from: [openLibrary(), googleBooks()])
        let publisher = lines(all, "publisher")

        #expect(publisher.count == 1)
        #expect(publisher[0].sources == [.openLibrary, .googleBooks])
        #expect(publisher[0].sourceLabel == "Open Library · Google Books")
        // Two catalogues agreeing still only fills a gap, and filling a gap is
        // what is ticked.
        #expect(publisher[0].isTickedByDefault)
    }

    @Test("two services that disagree are two lines, and neither is ticked")
    func disagreementIsTwoLines() throws {
        let all = MetadataMerge.proposals(
            for: Book(title: "Dune"),
            from: [openLibrary(publisher: "Ace"), googleBooks(publisher: "Gollancz")])
        let publisher = lines(all, "publisher")

        #expect(publisher.count == 2)
        #expect(publisher.map(\.proposed) == ["Ace", "Gollancz"])
        #expect(publisher.map(\.sourceLabel) == ["Open Library", "Google Books"])
        // The field is empty on the book, so each line on its own would fill a
        // gap. Together they are a question, and a question is not answered by
        // ticking one of them for somebody.
        #expect(publisher.allSatisfy { !$0.isTickedByDefault })
        // Two lines, two ids — a set of ticks could not tell them apart
        // otherwise.
        #expect(Set(publisher.map(\.id)).count == 2)
    }

    @Test("ticking one of two answers unticks the other")
    func rivalsAreExclusive() throws {
        let all = MetadataMerge.proposals(
            for: Book(title: "Dune"),
            from: [openLibrary(publisher: "Ace"), googleBooks(publisher: "Gollancz")])
        let publisher = lines(all, "publisher")
        let ace = try #require(publisher.first)
        let gollancz = try #require(publisher.last)

        var ticked = MetadataMerge.ticking(ace, in: all, ticked: [])
        #expect(ticked == [ace.id])

        ticked = MetadataMerge.ticking(gollancz, in: all, ticked: ticked)
        #expect(ticked == [gollancz.id], "a field holds one value, so the first tick has to go")

        ticked = MetadataMerge.ticking(gollancz, in: all, ticked: ticked)
        #expect(ticked.isEmpty, "ticking the same line again unticks it")
    }

    /// Tags are the exception, because applying them adds and removes nothing:
    /// both catalogues' subjects can be wanted at once.
    @Test("two services' tags are not exclusive")
    func tagsFromBothCanBeTaken() throws {
        let all = MetadataMerge.proposals(
            for: Book(title: "Dune"),
            from: [
                openLibrary(subjects: ["science fiction"]), googleBooks(subjects: ["desert ecology"]),
            ])
        let tags = lines(all, "tags")
        #expect(tags.count == 2)

        var ticked = MetadataMerge.ticking(tags[0], in: all, ticked: [])
        ticked = MetadataMerge.ticking(tags[1], in: all, ticked: ticked)
        #expect(ticked.count == 2)

        let applied = MetadataMerge.apply(all.filter { ticked.contains($0.id) }, to: Book(title: "Dune"))
        #expect(applied.book.tags.sorted() == ["desert ecology", "science fiction"])
    }

    @Test("a line the two already agree about cannot be ticked at all")
    func agreedLinesStayUnticked() throws {
        let book = Book(title: "Dune", authors: ["Frank Herbert"])
        let all = MetadataMerge.proposals(for: book, from: [openLibrary(), googleBooks()])
        let authors = try #require(lines(all, "authors").first)

        #expect(authors.kind == .same)
        #expect(MetadataMerge.ticking(authors, in: all, ticked: []).isEmpty)
    }
}

/// Which two records may stand on one comparison at all. Getting this wrong
/// would offer one book's publisher under another book's name.
@Suite("The same edition, or two different books")
struct EditionMatchTests {
    private func candidate(_ source: MetadataSource, title: String, isbn: String?) -> MetadataCandidate {
        MetadataCandidate(
            id: "\(source.slug):1", source: source, title: title, authors: ["Frank Herbert"],
            identifiers: isbn.map { ["isbn": $0] } ?? [:])
    }

    @Test("two records carrying the same ISBN are the same edition")
    func sameISBN() {
        let ours = candidate(.openLibrary, title: "Dune", isbn: "9780441013593")
        let theirs = candidate(.googleBooks, title: "Dune: 50th Anniversary", isbn: "9780441013593")
        #expect(EditionMatch.sameEdition(ours, theirs, asked: .titleAuthor(title: "Dune", author: nil)))
    }

    @Test("two records carrying different ISBNs are two editions, ISBN question or not")
    func differentISBN() {
        let ours = candidate(.openLibrary, title: "Dune", isbn: "9780441013593")
        let theirs = candidate(.googleBooks, title: "Dune Messiah", isbn: "9780441172696")
        #expect(!EditionMatch.sameEdition(ours, theirs, asked: .isbn("9780441013593")))
    }

    /// Both services were asked that ISBN. A record that does not repeat it
    /// back contradicts nothing — and `MetadataScore` already keeps such a
    /// record at 85 rather than throwing it away.
    @Test("a record silent about the ISBN it was asked for is still an answer to it")
    func silentAboutTheISBN() {
        let ours = candidate(.openLibrary, title: "Dune", isbn: "9780441013593")
        let theirs = candidate(.googleBooks, title: "Dune", isbn: nil)
        #expect(EditionMatch.sameEdition(ours, theirs, asked: .isbn("9780441013593")))
    }

    /// The one this rule exists for. `MetadataScore` scores "Dune" against
    /// "Dune Messiah" at 87 and "Clean Code" against its own subtitle at 83, so
    /// no threshold can pair the second without pairing the first. Two title
    /// searches are two guesses, and two guesses do not go on one sheet.
    @Test("two title-search answers with no ISBN are not paired")
    func titleSearchesAreNotPaired() {
        let ours = candidate(.openLibrary, title: "Dune", isbn: nil)
        let theirs = candidate(.googleBooks, title: "Dune Messiah", isbn: nil)
        #expect(!EditionMatch.sameEdition(ours, theirs, asked: .titleAuthor(title: "Dune", author: nil)))
    }

    @Test("the comparison takes the chosen record and one best answer per other service")
    func comparisonPicksOnePerService() {
        let chosen = candidate(.openLibrary, title: "Dune", isbn: "9780441013593")
        let query = MetadataQuery.isbn("9780441013593")
        let ranked = MetadataScore.ranked(
            [
                chosen,
                candidate(.googleBooks, title: "Dune", isbn: "9780441013593"),
                candidate(.googleBooks, title: "Dune (Paperback)", isbn: "9780441013593"),
                candidate(.googleBooks, title: "Dune Messiah", isbn: "9780441172696"),
            ], for: query)

        let records = EditionMatch.comparison(of: chosen, among: ranked, asked: query)
        #expect(records.count == 2, "one per service, not one per edition on offer")
        #expect(records.map(\.source) == [.openLibrary, .googleBooks])
        #expect(records[1].title == "Dune", "the sequel is a different edition and is left out")
    }

    @Test("a service that answered nothing about this edition adds no lines")
    func nothingFromTheOtherService() {
        let chosen = candidate(.openLibrary, title: "Dune", isbn: "9780441013593")
        let query = MetadataQuery.isbn("9780441013593")
        let ranked = MetadataScore.ranked([chosen], for: query)
        #expect(EditionMatch.comparison(of: chosen, among: ranked, asked: query) == [chosen])
    }
}
