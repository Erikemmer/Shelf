import Foundation
import GRDB
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
        let titles = try await index.allEntries(sortedBy: BookOrder(.title)).map(\.book.title)
        #expect(titles == ["apples", "The Hobbit", "Zebra"])
        // And the other way round, which is the half that used not to exist:
        // three of the six orders were reversible and three were not.
        let backwards = try await index.allEntries(sortedBy: BookOrder(.title).reversed).map(\.book.title)
        #expect(backwards == ["Zebra", "The Hobbit", "apples"])
    }

    @Test("by author uses the surname")
    func sortByAuthor() async throws {
        let index = try LibraryIndex(inMemory: "sort-author")
        try await index.save([
            entry(title: "A", authors: ["Jane Austen"], number: 1),
            entry(title: "B", authors: ["Ursula K. Le Guin"], number: 2),
            entry(title: "C", authors: ["Iain Banks"], number: 3),
        ])
        let authors = try await index.allEntries(sortedBy: BookOrder(.author)).map(\.book.authors[0])
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
        let titles = try await index.allEntries(sortedBy: BookOrder(.series)).map(\.book.title)
        #expect(titles == ["First", "Second", "No Series"])
        // Reversed, the series turns round and the book with none stays last.
        // A NULL sorts before everything in SQLite, so an ordinary DESC would
        // have moved it to the front.
        let backwards = try await index.allEntries(sortedBy: BookOrder(.series).reversed).map(\.book.title)
        #expect(backwards == ["Second", "First", "No Series"])
    }

    @Test("by date added is newest first")
    func sortByAdded() async throws {
        let index = try LibraryIndex(inMemory: "sort-added")
        let now = Date()
        try await index.save([
            entry(title: "Older", added: now.addingTimeInterval(-1_000), number: 1),
            entry(title: "Newer", added: now, number: 2),
        ])
        // `BookOrder(.added)` is newest first without being asked: a date is
        // usually wanted that way round, and the field says so itself.
        #expect(try await index.allEntries(sortedBy: BookOrder(.added)).map(\.book.title) == ["Newer", "Older"])
        #expect(
            try await index.allEntries(sortedBy: BookOrder(.added).reversed).map(\.book.title)
                == ["Older", "Newer"])
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

    /// The sixth thing CONCEPT §4 asks search to cover, and the one that was
    /// missing until Sprint 2b: an ISBN. Both spellings are indexed, because
    /// `978-0-306-40615-7` tokenises into five short numbers and
    /// `9780306406157` into one, and neither prefix-matches the other.
    @Test("search finds a book by its ISBN, hyphens or no hyphens")
    func searchByISBN() async throws {
        let index = try LibraryIndex(inMemory: "search-isbn")
        let hyphenated = entry(title: "One", isbn: "978-0-306-40615-7", number: 1)
        let plain = entry(title: "Two", isbn: "9780061054884", number: 2)
        try await index.save([hyphenated, plain])

        #expect(try await index.search("9780306406157") == [hyphenated.id])
        #expect(try await index.search("978-0-306-40615-7") == [hyphenated.id])
        #expect(try await index.search("9780061054884") == [plain.id])
        #expect(try await index.search("9780061054000").isEmpty)
    }

    /// The claim the sprint brief asks to be proved: an edit reaches the search
    /// index in the *same* write, not on the next reload.
    @Test("a changed description is findable at once, and an old one is not")
    func searchAfterDescriptionChange() async throws {
        let index = try LibraryIndex(inMemory: "search-description")
        var book = entry(title: "Anything", description: "An ambassador arrives.", number: 1)
        try await index.save(book)
        #expect(try await index.search("ambassador") == [book.id])

        book.book.description = "A librarian departs."
        try await index.save(book)
        #expect(try await index.search("ambassador").isEmpty)
        #expect(try await index.search("librarian") == [book.id])
    }

    @Test("a removed tag stops being findable")
    func searchAfterTagRemoval() async throws {
        let index = try LibraryIndex(inMemory: "search-tags")
        var book = entry(title: "Anything", tags: ["space opera", "classics"], number: 1)
        try await index.save(book)
        #expect(try await index.search("opera") == [book.id])

        guard case .changed(let edited) = TagEdit.remove("Space Opera", from: book.book) else {
            Issue.record("the tag was not removed")
            return
        }
        book.book = edited
        try await index.save(book)
        #expect(try await index.search("opera").isEmpty)
        // The tag that stayed is still found, so the row was rewritten and not
        // merely emptied.
        #expect(try await index.search("classics") == [book.id])
        #expect(try await index.tagFacets() == [LibraryIndex.Facet(name: "classics", count: 1)])
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

    // MARK: Duplicates

    /// The collection has to use the importer's three rules and say which one
    /// matched, because they are not equally trustworthy: identical bytes is a
    /// fact, an identical ISBN is nearly one, and an identical title and author
    /// is a guess that fits two editions and a translation too.
    @Test("each of the three rules finds its own kind of duplicate, and says so")
    func duplicatesByEachRule() async throws {
        let index = try LibraryIndex(inMemory: "duplicates")

        // Same bytes, different titles and no ISBN: only the content rule.
        var one = entry(title: "Alpha", number: 1)
        var two = entry(title: "Beta", number: 2)
        one.formats = [
            BookFormat(bookID: one.id, format: .epub, fileName: "a.epub", byteSize: 10, sha256: "same-bytes")
        ]
        two.formats = [
            BookFormat(bookID: two.id, format: .epub, fileName: "b.epub", byteSize: 10, sha256: "same-bytes")
        ]

        // Same ISBN, different files and different titles.
        var three = entry(title: "Gamma", number: 3)
        var four = entry(title: "Delta", number: 4)
        three.book.identifiers = ["isbn": "9780306406157"]
        four.book.identifiers = ["isbn": "978-0-306-40615-7"]

        // Same title and first author, spelt differently – the guess.
        var five = entry(title: "The Left-Hand of Darkness", number: 5)
        var six = entry(title: "the  left hand of darkness!", number: 6)
        five.book.authors = ["Ursula K. Le Guin"]
        six.book.authors = ["Ursula K. Lé Guin"]

        for entry in [one, two, three, four, five, six] { try await index.save(entry) }

        let found = try await index.duplicates()
        #expect(found[one.id] == [.content])
        #expect(found[two.id] == [.content])
        // Both spellings of one ISBN are one book – that is what
        // `isbn_normalised` is for.
        #expect(found[three.id] == [.isbn])
        #expect(found[four.id] == [.isbn])
        #expect(found[five.id] == [.titleAuthor])
        #expect(found[six.id] == [.titleAuthor])
        #expect(found.count == 6)
        #expect(try await index.totals().duplicates == 0, "totals does not count duplicates itself")
    }

    /// A book that holds the same file twice under two names is not a copy of
    /// itself, and a library with nothing wrong with it must report nothing.
    @Test("a book is not a duplicate of itself")
    func noFalseDuplicates() async throws {
        let index = try LibraryIndex(inMemory: "no-duplicates")
        var alone = entry(title: "Alone", number: 1)
        alone.book.identifiers = ["isbn": "9780306406157"]
        alone.formats = [
            BookFormat(bookID: alone.id, format: .epub, fileName: "a.epub", byteSize: 1, sha256: "d"),
            BookFormat(bookID: alone.id, format: .pdf, fileName: "a.pdf", byteSize: 1, sha256: "d"),
        ]
        try await index.save(alone)
        #expect(try await index.duplicates().isEmpty)
    }

    /// The strongest reason is what one line in the inspector says.
    @Test("a book matched by two rules is described by the better one")
    func strongestReason() {
        #expect(DuplicateReason.strongest(of: [.titleAuthor, .content]) == .content)
        #expect(DuplicateReason.strongest(of: [.titleAuthor, .isbn]) == .isbn)
        #expect(DuplicateReason.strongest(of: []) == nil)
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

        // The book carries the *path*; the index resolves it against the tree
        // it has just been given. Nothing hands it an id.
        var book = entry(title: "A Book", number: 1)
        book.book.shelves = ["Fiction/Science Fiction"]
        try await index.save(book)
        #expect(try await index.shelfFacets()[scifi.id] == 1)

        let totals = try await index.totals()
        #expect(totals.notOnAnyShelf == 0)
    }

    /// The path has to survive the round trip, or the grid filters on nothing
    /// and "Not on any Shelf" swallows the whole library.
    @Test("a book comes back out of the index standing on the same shelf")
    func shelfPathsComeBack() async throws {
        let index = try LibraryIndex(inMemory: "shelf-paths")
        let fiction = Shelf(name: "Fiction")
        let scifi = Shelf(name: "Science Fiction", parentID: fiction.id)
        try await index.saveShelves([fiction, scifi])

        var book = entry(title: "A Book", number: 1)
        book.book.shelves = ["Fiction/Science Fiction", "Fiction"]
        try await index.save(book)

        let back = try #require(try await index.entry(id: book.id))
        #expect(back.book.shelves == ["Fiction", "Fiction/Science Fiction"])
    }

    /// A path with no shelf behind it is skipped rather than invented: the tree
    /// belongs to `library.json`, and a shelf conjured up in the index would be
    /// one the file never hears about.
    @Test("a shelf the index does not know is skipped, not invented")
    func unknownShelfPath() async throws {
        let index = try LibraryIndex(inMemory: "unknown-shelf")
        var book = entry(title: "A Book", number: 1)
        book.book.shelves = ["Nowhere/At All"]
        try await index.save(book)

        let back = try #require(try await index.entry(id: book.id))
        #expect(back.book.shelves.isEmpty)
        #expect(try await index.totals().notOnAnyShelf == 1)
    }

    /// Removing a shelf from `library.json` has to remove it here too, or the
    /// sidebar keeps drawing a shelf that no longer exists.
    @Test("saving the tree removes the shelves that are no longer in it")
    func shelvesAreReplaced() async throws {
        let index = try LibraryIndex(inMemory: "shelves-replaced")
        let keep = Shelf(name: "Keep")
        let drop = Shelf(name: "Drop")
        try await index.saveShelves([keep, drop])
        try await index.saveShelves([keep])
        #expect(try await index.shelfIDs() == [keep.id])
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

/// The migration that gives an existing library ISBN search.
///
/// Its own suite because it does not go through `LibraryIndex`: the point is a
/// database that was written by the *previous* version of the schema, which is
/// the only state in which migration 2 ever runs. An index is rebuildable, but
/// "just rebuild it" is not an answer for somebody with a library open — and a
/// migration that has never been run against a v1 database is a migration
/// nobody has tested (Leitlinie: "Schema-Änderungen nur per versionierter
/// Migration").
@Suite("Migrating an index that already exists")
struct IndexMigrationTests {

    @Test("a library indexed before Sprint 2b becomes searchable by ISBN without a rebuild")
    func searchTableIsRefilled() throws {
        let queue = try DatabaseQueue()
        try IndexSchema.migrator.migrate(queue, upTo: "v1-books")

        // A book as the old schema held it, written by hand: this is what is on
        // somebody's disk, not what the current code would produce.
        let id = UUID().uuidString
        let seriesID = UUID().uuidString
        let tagID = UUID().uuidString
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO series (id, name, name_sort) VALUES (?, ?, ?)",
                arguments: [seriesID, "Hainish Cycle", "Hainish Cycle"])
            try database.execute(
                sql: """
                    INSERT INTO books
                        (id, number, folder, title, title_sort, series_id, series_index,
                         description, added_at, modified_at)
                    VALUES (?, 1, 'Le Guin, Ursula/The Dispossessed (1)', 'The Dispossessed',
                            'Dispossessed, The', ?, 6, 'Two worlds, one wall.', ?, ?)
                    """,
                arguments: [id, seriesID, Date(), Date()])
            try database.execute(sql: "INSERT INTO tags (id, name) VALUES (?, 'utopia')", arguments: [tagID])
            try database.execute(
                sql: "INSERT INTO book_tags (book_id, tag_id) VALUES (?, ?)", arguments: [id, tagID])
            try database.execute(
                sql: "INSERT INTO identifiers (book_id, scheme, value) VALUES (?, 'isbn', ?)",
                arguments: [id, "978-0-06-105488-4"])
            try database.execute(
                sql: "INSERT INTO identifiers (book_id, scheme, value) VALUES (?, 'isbn_normalised', ?)",
                arguments: [id, "9780061054884"])
            // The old search row, without an isbn column.
            try database.execute(
                sql: """
                    INSERT INTO search (title, authors, series, tags, description, book_id)
                    VALUES ('The Dispossessed', '', 'Hainish Cycle', 'utopia',
                            'Two worlds, one wall.', ?)
                    """,
                arguments: [id])
        }

        try IndexSchema.migrator.migrate(queue)

        // Read out first, asserted after: `try` inside an `#expect` in a
        // closure is not a context the macro can expand into.
        let hits = try queue.read { database -> [String: [String]] in
            var result: [String: [String]] = [:]
            for term in ["9780061054884", "978-0-06-105488-4", "dispossessed", "hainish", "utopia", "wall"] {
                result[term] = try String.fetchAll(
                    database, sql: "SELECT book_id FROM search WHERE search MATCH ?",
                    arguments: [LibraryIndex.ftsPattern(for: term)])
            }
            return result
        }
        let rows = try queue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM search") ?? 0
        }

        // The new column answers.
        #expect(hits["9780061054884"] == [id])
        #expect(hits["978-0-06-105488-4"] == [id])
        // And nothing the old row could already answer was lost.
        #expect(hits["dispossessed"] == [id])
        #expect(hits["hainish"] == [id])
        #expect(hits["utopia"] == [id])
        #expect(hits["wall"] == [id])
        // One row per book, not two: the old table was dropped, not added to.
        #expect(rows == 1)
    }
}
