import Foundation
import Testing

@testable import ShelfCore

/// The index. Everything in here except the shelves can be rebuilt from the
/// folders, so these tests are about it being *right*, not about it being
/// durable – durability is `IndexRebuilderTests`' job.
@Suite("The SQLite index")
struct LibraryIndexTests {

    private func entry(
        title: String,
        authors: [String] = ["An Author"],
        series: SeriesRef? = nil,
        tags: [String] = [],
        rating: Int = 0,
        isRead: Bool = false,
        isbn: String? = nil,
        description: String? = nil,
        added: Date = Date(),
        number: Int = 1,
        formats: [BookFileFormat] = [.epub],
        digest: String = UUID().uuidString
    ) -> LibraryEntry {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        let book = Book(
            title: title, authors: authors, series: series, rating: rating, isRead: isRead,
            description: description, tags: tags, identifiers: identifiers, addedAt: added)
        return LibraryEntry(
            book: book, number: number, folder: "\(authors.first ?? "Unknown")/\(title) (\(number))",
            formats: formats.enumerated().map { position, format in
                BookFormat(
                    bookID: book.id, format: format, fileName: "\(title).\(format.rawValue)",
                    byteSize: Int64(1_000 + position), sha256: "\(digest)-\(format.rawValue)")
            })
    }

    @Test("a book written comes back whole")
    func saveAndRead() async throws {
        let index = try LibraryIndex(inMemory: "read")
        let written = entry(
            title: "The Fifth Season", authors: ["N. K. Jemisin"],
            series: SeriesRef(name: "Broken Earth", index: 1),
            tags: ["science fiction", "award winner"], rating: 5, isRead: true,
            description: "The world ends.", formats: [.epub, .azw3])
        try await index.save(written)

        #expect(try await index.count() == 1)
        guard let read = try await index.entry(id: written.id) else {
            Issue.record("the book was not found again")
            return
        }
        #expect(read.book.title == "The Fifth Season")
        #expect(read.book.authors == ["N. K. Jemisin"])
        #expect(read.book.series == SeriesRef(name: "Broken Earth", index: 1))
        #expect(read.book.tags == ["award winner", "science fiction"])
        #expect(read.book.rating == 5)
        #expect(read.book.isRead)
        #expect(read.book.description == "The world ends.")
        #expect(read.number == written.number)
        #expect(read.folder == written.folder)
        #expect(read.formats.count == 2)
        #expect(read.formatLine == "AZW3 · EPUB")
    }

    /// Author order is data – the first one decides the folder – so it has to
    /// survive a round trip through two tables.
    @Test("authors keep their order through the join table")
    func authorOrder() async throws {
        let index = try LibraryIndex(inMemory: "order")
        let written = entry(title: "Good Omens", authors: ["Terry Pratchett", "Neil Gaiman"])
        try await index.save(written)
        #expect(try await index.entry(id: written.id)?.book.authors == ["Terry Pratchett", "Neil Gaiman"])
    }

    /// The same call serves an import, an edit and a rebuild, and relations are
    /// replaced rather than merged – a book whose second author was removed
    /// must not keep them.
    @Test("saving the same book again replaces its relations")
    func upsertReplacesRelations() async throws {
        let index = try LibraryIndex(inMemory: "upsert")
        var written = entry(title: "A Book", authors: ["A", "B"], tags: ["x", "y"])
        try await index.save(written)

        written.book.authors = ["A"]
        written.book.tags = ["x"]
        written.book.title = "A Renamed Book"
        try await index.save(written)

        #expect(try await index.count() == 1)
        let read = try await index.entry(id: written.id)
        #expect(read?.book.authors == ["A"])
        #expect(read?.book.tags == ["x"])
        #expect(read?.book.title == "A Renamed Book")
    }

    @Test("many books written in one transaction all arrive")
    func batchSave() async throws {
        let index = try LibraryIndex(inMemory: "batch")
        let books = (1...200).map { entry(title: "Book \($0)", number: $0) }
        try await index.save(books)
        #expect(try await index.count() == 200)
    }

    // MARK: Sorting

    @Test("by title ignores a leading article and ignores case")
    func sortByTitle() async throws {
        let index = try LibraryIndex(inMemory: "sort-title")
        try await index.save([
            entry(title: "The Hobbit", number: 1),
            entry(title: "apples", number: 2),
            entry(title: "Zebra", number: 3),
        ])
        let titles = try await index.allEntries(sortedBy: .titleSort).map(\.book.title)
        #expect(titles == ["apples", "The Hobbit", "Zebra"])
    }

    @Test("by author uses the surname")
    func sortByAuthor() async throws {
        let index = try LibraryIndex(inMemory: "sort-author")
        try await index.save([
            entry(title: "A", authors: ["Jane Austen"], number: 1),
            entry(title: "B", authors: ["Ursula K. Le Guin"], number: 2),
            entry(title: "C", authors: ["Iain Banks"], number: 3),
        ])
        let authors = try await index.allEntries(sortedBy: .authorSort).map(\.book.authors[0])
        #expect(authors == ["Jane Austen", "Iain Banks", "Ursula K. Le Guin"])
    }

    /// A NULL sorts before everything in SQLite, which would bury every series
    /// behind the books that have none.
    @Test("by series puts books without a series last, and orders by index")
    func sortBySeries() async throws {
        let index = try LibraryIndex(inMemory: "sort-series")
        try await index.save([
            entry(title: "No Series", number: 1),
            entry(title: "Second", series: SeriesRef(name: "Culture", index: 2), number: 2),
            entry(title: "First", series: SeriesRef(name: "Culture", index: 1), number: 3),
        ])
        let titles = try await index.allEntries(sortedBy: .seriesOrder).map(\.book.title)
        #expect(titles == ["First", "Second", "No Series"])
    }

    @Test("by date added is newest first")
    func sortByAdded() async throws {
        let index = try LibraryIndex(inMemory: "sort-added")
        let now = Date()
        try await index.save([
            entry(title: "Older", added: now.addingTimeInterval(-1_000), number: 1),
            entry(title: "Newer", added: now, number: 2),
        ])
        #expect(try await index.allEntries(sortedBy: .addedNewest).map(\.book.title) == ["Newer", "Older"])
    }

    // MARK: Search

    @Test("search finds a book by a prefix of its title, author, series or tag")
    func search() async throws {
        let index = try LibraryIndex(inMemory: "search")
        let target = entry(
            title: "A Memory Called Empire", authors: ["Arkady Martine"],
            series: SeriesRef(name: "Teixcalaan", index: 1), tags: ["space opera"],
            description: "An ambassador arrives.", number: 1)
        try await index.save([target, entry(title: "Something Else", authors: ["Nobody"], number: 2)])

        #expect(try await index.search("memory") == [target.id])
        #expect(try await index.search("mart") == [target.id])
        #expect(try await index.search("teixcalaan") == [target.id])
        #expect(try await index.search("space") == [target.id])
        #expect(try await index.search("ambassador") == [target.id])
        #expect(try await index.search("nothing here").isEmpty)
    }

    @Test("more words means fewer results, the way a search box should behave")
    func searchNarrows() async throws {
        let index = try LibraryIndex(inMemory: "search-and")
        let a = entry(title: "Ancillary Justice", authors: ["Ann Leckie"], number: 1)
        let b = entry(title: "Ancillary Sword", authors: ["Ann Leckie"], number: 2)
        try await index.save([a, b])

        #expect(try await index.search("ancillary").count == 2)
        #expect(try await index.search("ancillary sword") == [b.id])
    }

    /// A search for `AND` or a stray quote must be looked for, not parsed as
    /// FTS5 syntax and rejected.
    @Test("FTS5 syntax typed into the search box is treated as words")
    func searchIsQuoted() async throws {
        let index = try LibraryIndex(inMemory: "search-syntax")
        let book = entry(title: "NOT AND OR", number: 1)
        try await index.save(book)

        // `AND`, `NOT` and `OR` are FTS5 operators. Typed into the search box
        // they are words, and this book contains all three.
        #expect(try await index.search("AND") == [book.id])
        #expect(try await index.search("NOT OR") == [book.id])
        // An unbalanced quote or a bare operator would be a syntax error if the
        // text reached FTS5 unquoted. Here it simply finds nothing.
        #expect(try await index.search("\"quoted").isEmpty)
        #expect(try await index.search("* ( )").isEmpty)
        #expect(try await index.search("").isEmpty)
    }

    @Test("the search pattern is built as quoted prefix terms")
    func ftsPattern() {
        #expect(LibraryIndex.ftsPattern(for: "tolk") == "\"tolk\"*")
        #expect(LibraryIndex.ftsPattern(for: "le guin") == "\"le\"* \"guin\"*")
        #expect(LibraryIndex.ftsPattern(for: "  ") == "")
        #expect(LibraryIndex.ftsPattern(for: "a\"b") == "\"a\"* \"b\"*")
    }

    /// Search after a rename must not find the old name.
    @Test("renaming a book updates what search finds")
    func searchAfterRename() async throws {
        let index = try LibraryIndex(inMemory: "search-rename")
        var book = entry(title: "Original Title", number: 1)
        try await index.save(book)
        #expect(try await index.search("original") == [book.id])

        book.book.title = "Changed Title"
        try await index.save(book)
        #expect(try await index.search("original").isEmpty)
        #expect(try await index.search("changed") == [book.id])
    }

    // MARK: Facets

    @Test("the sidebar's counts come from one query per kind")
    func facets() async throws {
        let index = try LibraryIndex(inMemory: "facets")
        try await index.save([
            entry(
                title: "A", authors: ["Jane Austen"], series: SeriesRef(name: "S1"),
                tags: ["classics", "shared"], number: 1, formats: [.epub]),
            entry(title: "B", authors: ["Jane Austen"], tags: ["shared"], number: 2, formats: [.epub, .pdf]),
        ])

        #expect(
            try await index.tagFacets() == [
                LibraryIndex.Facet(name: "classics", count: 1),
                LibraryIndex.Facet(name: "shared", count: 2),
            ])
        #expect(try await index.authorFacets() == [LibraryIndex.Facet(name: "Jane Austen", count: 2)])
        #expect(try await index.seriesFacets() == [LibraryIndex.Facet(name: "S1", count: 1)])
        #expect(
            try await index.formatFacets() == [
                LibraryIndex.Facet(name: "epub", count: 2),
                LibraryIndex.Facet(name: "pdf", count: 1),
            ])
    }

    @Test("the smart collections' totals are counted, not guessed")
    func totals() async throws {
        let index = try LibraryIndex(inMemory: "totals")
        let now = Date()
        let withCover = entry(title: "Read", isRead: true, added: now, number: 1)
        try await index.save([
            withCover,
            entry(title: "Unread Recent", isRead: false, added: now, number: 2),
            entry(title: "Unread Old", isRead: false, added: now.addingTimeInterval(-90 * 86_400), number: 3),
        ])

        let totals = try await index.totals(coversOnDisk: [withCover.id])
        #expect(totals.all == 3)
        #expect(totals.unread == 2)
        #expect(totals.recentlyAdded == 2)
        #expect(totals.notOnAnyShelf == 3)
        #expect(totals.missingCover == 2)
    }

    // MARK: Duplicate detection

    @Test("a book is found again by its normalised ISBN")
    func findByISBN() async throws {
        let index = try LibraryIndex(inMemory: "isbn")
        let book = entry(title: "Dune", isbn: "978-0-441-01359-3", number: 1)
        try await index.save(book)
        // The stored form is normalised, so the hyphens do not matter.
        #expect(try await index.bookIDs(isbn: "9780441013593") == [book.id])
        #expect(try await index.allISBNs()["9780441013593"] == book.id)
    }

    @Test("a file is found again by its content")
    func findByDigest() async throws {
        let index = try LibraryIndex(inMemory: "digest")
        let book = entry(title: "A Book", number: 1, digest: "abc")
        try await index.save(book)
        #expect(try await index.bookID(sha256: "abc-epub") == book.id)
        #expect(try await index.bookID(sha256: "not-there") == nil)
        #expect(try await index.allFormatDigests()["abc-epub"] == book.id)
    }

    /// Case, accents and punctuation differ between two copies of one book, and
    /// none of those differences make it a different book.
    @Test("title and author are compared folded")
    func findByTitleAndAuthor() async throws {
        let index = try LibraryIndex(inMemory: "titlekey")
        let book = entry(title: "Blindness", authors: ["José Saramago"], number: 1)
        try await index.save(book)

        let key = DuplicateKey.titleAuthor(title: "BLINDNESS!", author: "Jose  Saramago")
        #expect(try await index.bookIDs(titleKey: key) == [book.id])
        #expect(try await index.allTitleKeys()[key] == [book.id])
    }

    @Test("two books with the same title and author both come back, and neither is picked")
    func ambiguousTitleKey() async throws {
        let index = try LibraryIndex(inMemory: "ambiguous")
        let first = entry(title: "Dune", authors: ["Frank Herbert"], number: 1)
        let second = entry(title: "Dune", authors: ["Frank Herbert"], number: 2)
        try await index.save([first, second])

        let key = DuplicateKey.titleAuthor(title: "Dune", author: "Frank Herbert")
        #expect(try await index.allTitleKeys()[key]?.count == 2)
    }

    @Test("the folded key ignores case, accents, punctuation and extra spaces")
    func folding() {
        #expect(DuplicateKey.fold("Blindness!") == "blindness")
        #expect(DuplicateKey.fold("José  Saramago") == "jose saramago")
        #expect(DuplicateKey.fold("The  Left-Hand   of Darkness") == "the left hand of darkness")
    }

    // MARK: Shelves

    @Test("shelves are written parents first, and counted")
    func shelves() async throws {
        let index = try LibraryIndex(inMemory: "shelves")
        let fiction = Shelf(name: "Fiction")
        let scifi = Shelf(name: "Science Fiction", parentID: fiction.id)
        // Deliberately child first: the index has to sort them, or the foreign
        // key fails.
        try await index.saveShelves([scifi, fiction])

        let book = entry(title: "A Book", number: 1)
        try await index.save(book, shelfIDs: [scifi.id])
        #expect(try await index.shelfFacets()[scifi.id] == 1)

        let totals = try await index.totals()
        #expect(totals.notOnAnyShelf == 0)
    }

    // MARK: Erasing

    /// A rebuild that merged into what was there could not remove a book
    /// somebody deleted in the Finder.
    @Test("erasing empties every table, so a rebuild starts from nothing")
    func erase() async throws {
        let index = try LibraryIndex(inMemory: "erase")
        try await index.save([entry(title: "A", number: 1), entry(title: "B", number: 2)])
        #expect(try await index.count() == 2)

        try await index.eraseAll()
        #expect(try await index.count() == 0)
        #expect(try await index.tagFacets().isEmpty)
        #expect(try await index.authorFacets().isEmpty)
        #expect(try await index.search("a").isEmpty)
    }

    @Test("an index on disk survives being closed and opened again")
    func onDisk() async throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Lib")
        let (library, _) = try Library.create(at: root)

        let written = entry(title: "Persistent", number: 1)
        let first = try LibraryIndex(library: library)
        try await first.save(written)

        let second = try LibraryIndex(library: library)
        #expect(try await second.count() == 1)
        #expect(try await second.entry(id: written.id)?.book.title == "Persistent")
    }

    @Test("an index that cannot be opened says why, rather than only that it failed")
    func openFailureCarriesItsReason() {
        // A path inside a file, which cannot hold a database.
        let library = Library(root: URL(fileURLWithPath: "/dev/null/nowhere"))
        do {
            _ = try LibraryIndex(library: library)
            Issue.record("opening an index in an impossible place should fail")
        } catch let failure as LibraryIndex.Failure {
            guard case .cannotOpen(_, let reason) = failure else {
                Issue.record("unexpected failure: \(failure)")
                return
            }
            #expect(!reason.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
