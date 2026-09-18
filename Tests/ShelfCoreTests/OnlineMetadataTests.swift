import Foundation
import Testing

@testable import ShelfCore

/// The stored answers, and the one rule about them: nothing here goes to the
/// network.
///
/// `Scripts/online-proof.sh` is what talks to Open Library and Google Books,
/// once, by hand. What it leaves behind is read here. A reader tested against a
/// live service fails when somebody else's server is having a bad afternoon and
/// passes for reasons it cannot name.
enum OnlineFixture {
    static func data(_ name: String) throws -> Data {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/online")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }
}

@Suite("Reading what the metadata services answer")
struct OnlineReaderTests {
    @Test("an Open Library answer becomes a candidate with the asked-for ISBN on it")
    func openLibraryByISBN() throws {
        let data = try OnlineFixture.data("openlibrary-isbn-9780441013593.json")
        let found = try OpenLibraryReader.candidates(from: data, answering: .isbn("9780441013593"))

        #expect(found.count == 1)
        let dune = try #require(found.first)
        #expect(dune.title == "Dune")
        #expect(dune.authors == ["Frank Herbert"])
        #expect(dune.source == .openLibrary)
        // The work carries about two hundred ISBNs and the search answers them
        // in no order worth trusting. The one on the book in somebody's hand is
        // the one that was asked for.
        #expect(dune.identifiers["isbn"] == "9780441013593")
        #expect(dune.coverURL?.absoluteString.hasPrefix("https://covers.openlibrary.org/b/id/") == true)
        #expect(!dune.subjects.isEmpty)
        // The search endpoint carries no description at all — which is half of
        // why both services are asked.
        #expect(dune.summary == nil)
    }

    @Test("a work Open Library does not have is no candidates, not an error")
    func openLibraryKnowsNothing() throws {
        let data = try OnlineFixture.data("openlibrary-isbn-9783453319950.json")
        #expect(try OpenLibraryReader.candidates(from: data, answering: .isbn("9783453319950")).isEmpty)
    }

    @Test("a title search answers several candidates, in the order the service gave them")
    func openLibraryByTitle() throws {
        let data = try OnlineFixture.data("openlibrary-title-left-hand-of-darkness.json")
        let query = MetadataQuery.titleAuthor(title: "The Left Hand of Darkness", author: "Ursula K. Le Guin")
        let found = try OpenLibraryReader.candidates(from: data, answering: query)

        #expect(found.count > 1)
        #expect(found.first?.title == "The Left Hand of Darkness")
        #expect(found.first?.authors.first == "Ursula K. Le Guin")
        // No ISBN was asked for, so the 13-digit one is preferred — that is the
        // number the duplicate check and the next lookup both want.
        if let isbn = found.first?.identifiers["isbn"] {
            #expect(ISBN.normalised(isbn).count == 13)
        }
    }

    @Test("the subjects a work carries are capped, because twelve is an offer and a hundred is not")
    func subjectsAreCapped() throws {
        let data = try OnlineFixture.data("openlibrary-isbn-9780451524935.json")
        let found = try OpenLibraryReader.candidates(from: data, answering: .isbn("9780451524935"))
        #expect(found.first?.subjects.count ?? 0 <= OpenLibraryReader.maximumSubjects)
    }

    @Test("a German title Open Library knows is read with its own spelling")
    func openLibraryGerman() throws {
        let data = try OnlineFixture.data("openlibrary-isbn-9783442267743.json")
        let found = try OpenLibraryReader.candidates(from: data, answering: .isbn("9783442267743"))
        #expect(found.first?.title == "Die Herren von Winterfell")
    }

    @Test("a Google Books volume becomes a candidate with its description and a usable cover URL")
    func googleBooksVolume() throws {
        let data = try OnlineFixture.data("googlebooks-volume-reconstructed.json")
        let found = try GoogleBooksReader.candidates(from: data)

        let book = try #require(found.first)
        // The subtitle is joined on, because a book called "Clean Code" and a
        // book called "Clean Code: A Handbook…" are the same book and the
        // longer name is the one on the cover.
        #expect(book.title == "Clean Code: A Handbook of Agile Software Craftsmanship")
        #expect(book.authors == ["Robert C. Martin"])
        #expect(book.publisher == "Prentice Hall")
        // 13 wins over 10: one book, and the 13 is what everything else here
        // compares.
        #expect(book.identifiers["isbn"] == "9780132350884")
        #expect(book.identifiers["google"] == "hjEFCAAAQBAJ")
        #expect(book.summary?.hasPrefix("Even bad code") == true)
        #expect(book.language == "en")
        #expect(book.pageCount == 464)
        // http would be refused by App Transport Security and the cover would
        // silently never load; `edge=curl` draws a folded page corner over it.
        let cover = try #require(book.coverURL?.absoluteString)
        #expect(cover.hasPrefix("https://"))
        #expect(!cover.contains("edge=curl"))
    }

    @Test("`totalItems: 0` has no `items` key at all, and that is an answer")
    func googleBooksKnowsNothing() throws {
        let data = try OnlineFixture.data("googlebooks-empty.json")
        #expect(try GoogleBooksReader.candidates(from: data).isEmpty)
    }

    @Test("something that is not a record at all is a failure with a sentence in it")
    func notARecord() {
        #expect(throws: MetadataReadFailure.notAnObject(.openLibrary)) {
            try OpenLibraryReader.candidates(from: Data("[1, 2, 3]".utf8), answering: .isbn("1"))
        }
        #expect(MetadataReadFailure.notAnObject(.googleBooks).message.contains("Google Books"))
    }
}

@Suite("What to ask, and whom")
struct MetadataQueryTests {
    @Test("a book with a valid ISBN is asked for by ISBN, and nothing else")
    func isbnFirst() {
        var book = Book(title: "Dune", authors: ["Frank Herbert"])
        book.identifiers["isbn"] = "978-0-441-01359-3"
        #expect(MetadataQuery.about(book) == .isbn("9780441013593"))
    }

    /// An ISBN that cannot be one is not a key, it is a typo. Asking with it
    /// would answer nothing and look like "the services do not have this book".
    @Test("an ISBN that fails its check digit is not used as the question")
    func brokenISBNFallsBack() {
        var book = Book(title: "Dune", authors: ["Frank Herbert"])
        book.identifiers["isbn"] = "9780441013594"
        #expect(MetadataQuery.about(book) == .titleAuthor(title: "Dune", author: "Frank Herbert"))
    }

    @Test("a book with no title cannot be asked about at all")
    func nothingToAskWith() {
        #expect(MetadataQuery.about(Book(title: "   ")) == nil)
    }

    @Test("an author-less book is asked about by title alone")
    func titleOnly() {
        #expect(MetadataQuery.about(Book(title: "Emma")) == .titleAuthor(title: "Emma", author: nil))
    }

    @Test("both services are asked, and the ISBN goes into the URL where it belongs")
    func urls() throws {
        let requests = MetadataEndpoint.requests(for: .isbn("9780441013593"))
        #expect(requests.count == 2)

        let openLibrary = try #require(requests.first { $0.source == .openLibrary }).url.absoluteString
        // `/search.json`, not `/api/books` — see ADR 0015.
        #expect(openLibrary.hasPrefix("https://openlibrary.org/search.json?"))
        #expect(openLibrary.contains("isbn:9780441013593"))
        #expect(!openLibrary.contains("/api/books"))

        let google = try #require(requests.first { $0.source == .googleBooks }).url.absoluteString
        #expect(google.hasPrefix("https://www.googleapis.com/books/v1/volumes?"))
        #expect(google.contains("isbn:9780441013593"))
        // No API key anywhere, in the URL or out of it (CONCEPT §9).
        #expect(!google.lowercased().contains("key="))
    }

    @Test("a title question carries the title and the author, and asks for ten")
    func titleURLs() throws {
        let query = MetadataQuery.titleAuthor(title: "The Left Hand of Darkness", author: "Le Guin")
        let google = try #require(MetadataEndpoint.request(for: query, from: .googleBooks)).url.absoluteString
        #expect(google.contains("intitle:"))
        #expect(google.contains("inauthor:"))
        #expect(google.contains("maxResults=10"))
    }

    /// The cache key is what stops the same ISBN being asked twice, so two
    /// spellings of one question have to be one key — and two different
    /// questions must never share one.
    @Test("one question is one cache key, however it is spelt")
    func cacheKeys() {
        let plain = MetadataEndpoint.cacheKey(.titleAuthor(title: "The Hobbit", author: "Tolkien"), .openLibrary)
        let shouted = MetadataEndpoint.cacheKey(.titleAuthor(title: "THE  HOBBIT!", author: "tolkien"), .openLibrary)
        #expect(plain == shouted)

        let other = MetadataEndpoint.cacheKey(.titleAuthor(title: "The Hobbit", author: "Someone"), .openLibrary)
        #expect(plain != other)
        // And the two services do not share an answer.
        #expect(plain != MetadataEndpoint.cacheKey(.titleAuthor(title: "The Hobbit", author: "Tolkien"), .googleBooks))
    }
}

@Suite("Which candidate is the book")
struct MetadataScoreTests {
    private func candidate(_ title: String, _ authors: [String], isbn: String? = nil) -> MetadataCandidate {
        MetadataCandidate(
            id: title, source: .openLibrary, title: title, authors: authors,
            identifiers: isbn.map { ["isbn": $0] } ?? [:])
    }

    @Test("an answer that repeats the ISBN back is the edition, and scores everything")
    func isbnWins() {
        let exact = candidate("Dune", ["Frank Herbert"], isbn: "9780441013593")
        #expect(MetadataScore.score(exact, against: .isbn("9780441013593")) == 100)
        // Asked by ISBN and answering without one is still that ISBN's record —
        // high, but below one that says so.
        let quiet = candidate("Dune", ["Frank Herbert"])
        #expect(MetadataScore.score(quiet, against: .isbn("9780441013593")) == 85)
    }

    @Test("a title that agrees and an author who agrees score full marks")
    func titleAndAuthor() {
        let query = MetadataQuery.titleAuthor(title: "The Left Hand of Darkness", author: "Ursula K. Le Guin")
        #expect(
            MetadataScore.score(candidate("The Left Hand of Darkness", ["Ursula K. Le Guin"]), against: query) == 100)
    }

    /// A subtitle the book on disk does not carry must not cost the match:
    /// "Clean Code" and "Clean Code: A Handbook of Agile Software
    /// Craftsmanship" are one book.
    @Test("a longer title with the same words in it is still the same book")
    func subtitleCostsNothing() {
        let query = MetadataQuery.titleAuthor(title: "Clean Code", author: "Robert C. Martin")
        let long = candidate("Clean Code: A Handbook of Agile Software Craftsmanship", ["Robert C. Martin"])
        #expect(MetadataScore.score(long, against: query) >= 80)
    }

    /// The sequel is the case the first version of the score got wrong: every
    /// word of "Dune" is in "Dune Messiah", so counting shared words alone put
    /// the two level and the candidate list had no first place.
    @Test("a sequel scores below the book itself, and visibly so")
    func sequelIsNotTheBook() {
        let query = MetadataQuery.titleAuthor(title: "Dune", author: "Frank Herbert")
        let book = MetadataScore.score(candidate("Dune", ["Frank Herbert"]), against: query)
        let sequel = MetadataScore.score(candidate("Dune Messiah", ["Frank Herbert"]), against: query)
        #expect(book == 100)
        #expect(sequel < book)
    }

    @Test("a different book by the same author scores the author and not the title")
    func wrongBook() {
        let query = MetadataQuery.titleAuthor(title: "The Left Hand of Darkness", author: "Ursula K. Le Guin")
        let other = candidate("The Dispossessed", ["Ursula K. Le Guin"])
        #expect(MetadataScore.score(other, against: query) < 50)
    }

    @Test("the list is best first, and the same list on every run")
    func ranking() {
        let query = MetadataQuery.titleAuthor(title: "Dune", author: "Frank Herbert")
        let right = candidate("Dune", ["Frank Herbert"])
        let wrong = candidate("Dune Messiah", ["Frank Herbert"])
        let ranked = MetadataScore.ranked([wrong, right], for: query)
        #expect(ranked.first?.candidate.id == right.id)
        #expect(ranked.first?.score ?? 0 > ranked.last?.score ?? 0)
        // Twice, to say that nothing about it is a dictionary's order.
        #expect(
            MetadataScore.ranked([wrong, right], for: query).map(\.candidate.id)
                == MetadataScore.ranked([right, wrong], for: query).map(\.candidate.id))
    }
}
