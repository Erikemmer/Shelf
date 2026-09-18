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

    private func line(_ lines: [FieldProposal], _ id: String) throws -> FieldProposal {
        try #require(lines.first { $0.id == id })
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
        #expect(!lines.contains { $0.id == "publisher" })
        #expect(!lines.contains { $0.id == "published" })
        #expect(!lines.contains { $0.id == "tags" })
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
            kind: .add, isTickedByDefault: true)
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
            target: .field(.title), label: "Title", current: "Dune", proposed: "", kind: .replace,
            isTickedByDefault: false)
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
        #expect(!lines.contains { $0.id == "published" })
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
