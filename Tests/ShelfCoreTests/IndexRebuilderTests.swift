import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// The proof behind ADR 0001. If a rebuild reconstructs the library from the
/// folders, then the index is a cache and may be deleted, vacuumed, replaced by
/// a newer schema or thrown away after a crash. If it does not, the index is
/// the user's data and none of that is allowed.
@Suite("Rebuilding the index from the folders")
struct IndexRebuilderTests {

    private func rebuilder() -> IndexRebuilder {
        IndexRebuilder(makeHasher: PortableSHA256Hasher.factory)
    }

    /// Builds a library on disk by importing, which is the only way a real one
    /// ever comes into being.
    private func importedLibrary(
        _ folder: TemporaryFolder, books: [Book], covers: Bool = true
    ) async throws -> (Library, [LibraryEntry]) {
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        var candidates: [ImportCandidate] = []
        for (index, book) in books.enumerated() {
            let cover = covers ? MinimalPNG.cover(width: 10, height: 15, seed: UInt8(index % 200)) : nil
            let epub = SyntheticEPUB(book: book, cover: cover).data()
            let url = try folder.write("source/\(index).epub", data: epub)
            let read = try EPUBMetadata.read(url: url)
            candidates.append(
                ImportCandidate(
                    source: url, byteSize: Int64(epub.count), format: .epub,
                    sha256: try FileDigest.sha256(of: url, makeHasher: PortableSHA256Hasher.factory),
                    book: read.book, cover: read.cover, coverName: read.coverName))
        }
        let plan = ImportPlanner.plan(candidates: candidates, startingNumber: 1)
        let outcome = try await ImportRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(ImportRunner.Options(library: library, plan: plan, sourceDescription: "test"))
        return (library, outcome.entries)
    }

    @Test("a walk of the folders finds every book the import wrote")
    func findsEverything() async throws {
        let folder = try TemporaryFolder()
        let books = [
            Book(title: "Emma", authors: ["Jane Austen"]),
            Book(
                title: "The Fifth Season", authors: ["N. K. Jemisin"],
                series: SeriesRef(name: "Broken Earth", index: 1), tags: ["science fiction"]),
            Book(title: "Blindness", authors: ["José Saramago"], identifiers: ["isbn": "9780156007757"]),
        ]
        let (library, imported) = try await importedLibrary(folder, books: books)

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.count == 3)
        #expect(result.unreadableFolders.isEmpty)
        #expect(result.withoutOPF.isEmpty)
        #expect(Set(result.entries.map(\.id)) == Set(imported.map(\.id)))
    }

    /// The UUID is what makes a rebuild *reconstruct* rather than reinvent: the
    /// same books come back with the same identities, so shelves and reading
    /// status still point at them.
    @Test("identities survive, so nothing that pointed at a book is orphaned")
    func identitiesSurvive() async throws {
        let folder = try TemporaryFolder()
        let id = UUID()
        let (library, _) = try await importedLibrary(
            folder, books: [Book(id: id, title: "Kept", authors: ["An Author"])])

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.first?.book.id == id)
    }

    @Test("the metadata comes back from the OPF, not from the folder name")
    func metadataFromOPF() async throws {
        let folder = try TemporaryFolder()
        let book = Book(
            title: "A Memory Called Empire", authors: ["Arkady Martine"],
            series: SeriesRef(name: "Teixcalaan", index: 1), rating: 5, isRead: true,
            publisher: "Tor", description: "An ambassador arrives.",
            tags: ["space opera", "award winner"], identifiers: ["isbn": "9781529001594"])
        let (library, _) = try await importedLibrary(folder, books: [book])

        guard let rebuilt = try rebuilder().rebuild(library).entries.first else {
            Issue.record("nothing rebuilt")
            return
        }
        #expect(rebuilt.book.title == "A Memory Called Empire")
        #expect(rebuilt.book.authors == ["Arkady Martine"])
        #expect(rebuilt.book.series == SeriesRef(name: "Teixcalaan", index: 1))
        #expect(rebuilt.book.tags.sorted() == ["award winner", "space opera"])
        #expect(rebuilt.book.identifiers["isbn"] == "9781529001594")
    }

    @Test("the folder number comes back, so the counter can be repaired")
    func folderNumbers() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try await importedLibrary(
            folder,
            books: (1...5).map { Book(title: "Book \($0)", authors: ["A"]) })

        let result = try rebuilder().rebuild(library)
        #expect(result.highestNumber == 5)
        #expect(Set(result.entries.map(\.number)) == Set(1...5))
    }

    /// The shelves are the one part of the index the folders could not
    /// otherwise hold, which is why they are mirrored into every OPF.
    @Test("the shelves a book was on come back out of its OPF")
    func shelvesSurvive() async throws {
        let folder = try TemporaryFolder()
        let (library, entries) = try await importedLibrary(
            folder, books: [Book(title: "Shelved", authors: ["A"])])
        guard let entry = entries.first else {
            Issue.record("nothing imported")
            return
        }
        // What the editor does: the shelves go into the book's own OPF.
        var shelved = entry.book
        shelved.shelves = ["Fiction/Science Fiction"]
        let bookFolder = library.root.appendingPathComponent(entry.folder)
        try OPFDocument.write(shelved, to: bookFolder)

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.first?.book.shelves == ["Fiction/Science Fiction"])
        // And the walk reports the path, so the caller can make sure
        // `library.json` holds a shelf to file it under.
        #expect(result.shelfPathsSeen == ["Fiction/Science Fiction"])
    }

    /// The whole claim of ADR 0008, end to end: throw the index away, walk the
    /// folders, and every book is back on its shelf — including a shelf
    /// `library.json` had never heard of, and an *empty* shelf, which no book
    /// can remember and only the file can.
    @Test("erasing the index and rebuilding puts every book back on its shelf")
    func shelvesSurviveARebuild() async throws {
        let folder = try TemporaryFolder()
        let (library, entries) = try await importedLibrary(
            folder,
            books: [
                Book(title: "One", authors: ["A"]),
                Book(title: "Two", authors: ["B"]),
                Book(title: "Three", authors: ["C"]),
            ])
        #expect(entries.count == 3)

        // The tree, as the sidebar would build it.
        var tree = ShelfTree()
        guard case .success(let fiction) = ShelfEdit.add(name: "Fiction", to: tree),
            case .success(let scifi) = ShelfEdit.add(name: "Sci-Fi", under: fiction.id, to: fiction.tree),
            case .success(let empty) = ShelfEdit.add(name: "Someday", to: scifi.tree)
        else {
            Issue.record("a shelf was refused")
            return
        }
        tree = empty.tree

        // Two books on shelves, one on none. Written into each book's own OPF,
        // which is the only place a rebuild can read them from.
        for (position, entry) in entries.sorted(by: { $0.number < $1.number }).enumerated() {
            var book = entry.book
            switch position {
            case 0: book.shelves = ["Fiction"]
            case 1: book.shelves = ["Fiction/Sci-Fi"]
            default: break
            }
            try OPFDocument.write(book, to: library.root.appendingPathComponent(entry.folder))
        }

        // `library.json` keeps the shape – including the shelf nobody is on.
        var descriptor = try library.readDescriptor()
        descriptor.shelves = tree.shelves
        try library.write(descriptor)

        // Now the part that is being proved: nothing but the folders and
        // `library.json` survives.
        let index = try LibraryIndex(inMemory: "rebuild-shelves")
        let result = try rebuilder().rebuild(library)
        var rebuilt = ShelfTree(try library.readDescriptor().shelves)
        for path in result.shelfPathsSeen.sorted() { _ = rebuilt.ensure(path: path) }
        try await index.saveShelves(rebuilt.shelves)
        try await index.save(result.entries)

        let back = try await index.allEntries().sorted { $0.number < $1.number }
        #expect(back.map(\.book.shelves) == [["Fiction"], ["Fiction/Sci-Fi"], []])
        // The empty shelf is still there: no book remembers it, `library.json`
        // does, and that is exactly why the shape is kept in the file.
        #expect(rebuilt.shelf(atPath: "Someday") != nil)
        #expect(try await index.totals().notOnAnyShelf == 1)
    }

    /// A library restored from a backup without its `.shelf` folder: the books
    /// remember their shelves and nothing else does. Inventing the shelf is
    /// right — the book said where it stands, and the folder is the truth.
    @Test("a shelf only the books remember is created rather than dropped")
    func shelfLostFromLibraryJSON() async throws {
        let folder = try TemporaryFolder()
        let (library, entries) = try await importedLibrary(
            folder, books: [Book(title: "Orphan", authors: ["A"])])
        guard let entry = entries.first else {
            Issue.record("nothing imported")
            return
        }
        var book = entry.book
        book.shelves = ["Fiction/Sci-Fi"]
        try OPFDocument.write(book, to: library.root.appendingPathComponent(entry.folder))
        // `library.json` says there are no shelves at all.
        var descriptor = try library.readDescriptor()
        descriptor.shelves = []
        try library.write(descriptor)

        let result = try rebuilder().rebuild(library)
        var tree = ShelfTree()
        for path in result.shelfPathsSeen.sorted() { _ = tree.ensure(path: path) }
        #expect(tree.shelves.count == 2)
        #expect(tree.shelf(atPath: "Fiction/Sci-Fi") != nil)

        let index = try LibraryIndex(inMemory: "rebuild-orphan-shelf")
        try await index.saveShelves(tree.shelves)
        try await index.save(result.entries)
        #expect(try await index.allEntries().first?.book.shelves == ["Fiction/Sci-Fi"])
    }

    // MARK: When the folder is not as expected

    /// Deleting is never the rebuilder's job. A folder it cannot make sense of
    /// is reported so the user can look.
    @Test("a folder with no book file is reported, never tidied away")
    func folderWithoutABook() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try await importedLibrary(folder, books: [Book(title: "Real", authors: ["A"])])
        try folder.write("Lib/B/Not A Book (99)/notes.txt", text: "just a note")

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.count == 1)
        #expect(result.unreadableFolders == ["B/Not A Book (99)"])
        #expect(folder.exists("Lib/B/Not A Book (99)/notes.txt"))
    }

    /// A book whose OPF was lost is still a book: the EPUB itself is read, and
    /// the report says the metadata came from the file.
    @Test("without its OPF a book's metadata comes from the EPUB, with a note")
    func opfMissing() async throws {
        let folder = try TemporaryFolder()
        let (library, entries) = try await importedLibrary(
            folder, books: [Book(title: "No OPF Here", authors: ["An Author"])])
        guard let entry = entries.first else {
            Issue.record("nothing imported")
            return
        }
        try FileManager.default.removeItem(
            at: library.root.appendingPathComponent(entry.folder).appendingPathComponent("metadata.opf"))

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.book.title == "No OPF Here")
        #expect(result.withoutOPF.count == 1)
    }

    @Test("an unreadable OPF falls through to the book file rather than failing")
    func opfCorrupt() async throws {
        let folder = try TemporaryFolder()
        let (library, entries) = try await importedLibrary(
            folder, books: [Book(title: "Broken OPF", authors: ["An Author"])])
        guard let entry = entries.first else {
            Issue.record("nothing imported")
            return
        }
        try Data("<package><unclosed".utf8).write(
            to: library.root.appendingPathComponent(entry.folder).appendingPathComponent("metadata.opf"))

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.first?.book.title == "Broken OPF")
        #expect(result.withoutOPF.count == 1)
    }

    /// Last resort: the folder names themselves. Still a book, and still
    /// findable.
    @Test("with neither an OPF nor a readable book the folder names are used")
    func fromFolderNamesOnly() throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        // A PDF, which Sprint 1 cannot read metadata out of, and no OPF.
        try folder.write("Lib/Austen, Jane/Emma (7)/Emma - Jane Austen.pdf", data: Data([1, 2, 3]))

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.book.title == "Emma")
        #expect(result.entries.first?.book.authors == ["Austen, Jane"])
        #expect(result.entries.first?.number == 7)
        #expect(result.entries.first?.formats.first?.format == .pdf)
    }

    @Test("Shelf's own .shelf folder is not mistaken for an author")
    func privateFolderSkipped() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try await importedLibrary(folder, books: [Book(title: "A", authors: ["B"])])
        let result = try rebuilder().rebuild(library)
        #expect(!result.unreadableFolders.contains { $0.contains(Library.privateFolderName) })
        #expect(result.entries.count == 1)
    }

    @Test("every format in a book's folder is found")
    func severalFormats() throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        try folder.write("Lib/A/Book (1)/Book - A.epub", data: Data([1]))
        try folder.write("Lib/A/Book (1)/Book - A.azw3", data: Data([2]))
        try folder.write("Lib/A/Book (1)/Book - A.pdf", data: Data([3]))
        try folder.write("Lib/A/Book (1)/cover.png", data: Data([4]))

        let result = try rebuilder().rebuild(library)
        #expect(result.entries.first?.formats.map(\.format).sorted() == [.epub, .azw3, .pdf])
    }

    // MARK: Digests

    /// Hashing 8 000 files is minutes of disk. A digest may be reused when the
    /// file's size and modification date are unchanged, and the key carries
    /// both so a file replaced under the same name misses and is hashed again.
    @Test("a stored digest is reused when the file has not changed")
    func digestsReused() async throws {
        let folder = try TemporaryFolder()
        let (library, entries) = try await importedLibrary(
            folder, books: [Book(title: "Hashed", authors: ["A"])])
        guard let entry = entries.first, let format = entry.formats.first else {
            Issue.record("nothing imported")
            return
        }

        let key = IndexRebuilder.digestKey(
            folder: entry.folder, fileName: format.fileName, byteSize: format.byteSize,
            modifiedAt: format.modifiedAt)
        let result = try rebuilder().rebuild(library, knownDigests: [key: "a-remembered-digest"])
        #expect(result.entries.first?.formats.first?.sha256 == "a-remembered-digest")
    }

    @Test("a file whose size changed is hashed again rather than trusted")
    func digestsNotReusedWhenChanged() async throws {
        let folder = try TemporaryFolder()
        let (library, entries) = try await importedLibrary(
            folder, books: [Book(title: "Hashed", authors: ["A"])])
        guard let entry = entries.first, let format = entry.formats.first else {
            Issue.record("nothing imported")
            return
        }
        // The same file name and date, a different size: the key misses.
        let key = IndexRebuilder.digestKey(
            folder: entry.folder, fileName: format.fileName, byteSize: format.byteSize + 1,
            modifiedAt: format.modifiedAt)
        let result = try rebuilder().rebuild(library, knownDigests: [key: "a-remembered-digest"])
        #expect(result.entries.first?.formats.first?.sha256 == format.sha256)
    }

    // MARK: The whole claim, end to end

    /// "The folder is the truth" is a claim about numbers, so it is checked as
    /// one: erase the index, rebuild from the folders, compare.
    @Test("erasing the index and rebuilding gives back the same library")
    func eraseAndRebuild() async throws {
        let folder = try TemporaryFolder()
        var books: [Book] = []
        for number in 1...25 {
            let series: SeriesRef? = number % 3 == 0 ? SeriesRef(name: "A Series", index: Double(number)) : nil
            let tags: [String] = number % 2 == 0 ? ["even"] : ["odd"]
            let isbn = "978" + String(format: "%010d", number)
            books.append(
                Book(
                    title: "Book \(number)",
                    authors: ["Author \(number % 5)"],
                    series: series,
                    tags: tags,
                    identifiers: ["isbn": isbn]))
        }
        let (library, imported) = try await importedLibrary(folder, books: books)

        let index = try LibraryIndex(library: library)
        try await index.save(imported)
        let before = try await index.count()
        let entriesBefore = try await index.allEntries()
        let titlesBefore: [String] = entriesBefore.map(\.book.title)
        let tagsBefore = try await index.tagFacets()

        try await index.eraseAll()
        #expect(try await index.count() == 0)

        let result = try rebuilder().rebuild(library)
        try await index.save(result.entries)

        let entriesAfter = try await index.allEntries()
        let titlesAfter: [String] = entriesAfter.map(\.book.title)
        #expect(try await index.count() == before)
        #expect(titlesAfter == titlesBefore)
        #expect(try await index.tagFacets() == tagsBefore)
        #expect(try await index.allISBNs().count == 25)
    }

    @Test("the folder name is read back into a title and a number")
    func folderNameParsing() {
        #expect(IndexRebuilder.number(in: "Pride and Prejudice (17)") == 17)
        #expect(IndexRebuilder.title(in: "Pride and Prejudice (17)") == "Pride and Prejudice")
        // A folder somebody renamed by hand: no number, and none invented.
        #expect(IndexRebuilder.number(in: "Pride and Prejudice") == 0)
        #expect(IndexRebuilder.title(in: "Pride and Prejudice") == "Pride and Prejudice")
        // Brackets that are part of the title, not a number.
        #expect(IndexRebuilder.number(in: "Emma (Annotated)") == 0)
        #expect(IndexRebuilder.title(in: "Emma (Annotated)") == "Emma (Annotated)")
    }
}

/// Two folders carrying the same number. A library gets into this state when an
/// import is killed: the files it had already copied stay, the counter it never
/// stored starts again, and the next run hands the same numbers out a second
/// time. It is also one Finder duplication away.
///
/// A rebuild is the operation the whole project rests on — the index is a cache
/// precisely because it can always be built again (ADR 0001). A rebuild that
/// *dies* on a library somebody actually has is the one failure that claim
/// cannot survive, and this is what it looked like:
///
///     Fatal error: SQLite error 19: UNIQUE constraint failed: books.number
@Suite("A library whose folder numbers collide")
struct DuplicateFolderNumberTests {
    private func entry(_ title: String, number: Int, folder: String) -> LibraryEntry {
        LibraryEntry(
            book: Book(title: title), number: number, folder: folder,
            formats: [])
    }

    @Test("two books with one number can both be indexed, and the rebuild says so")
    func twoBooksOneNumber() async throws {
        let index = try LibraryIndex(inMemory: UUID().uuidString)
        let first = entry("Emma", number: 7, folder: "Austen, Jane/Emma (7)")
        let second = entry("Persuasion", number: 7, folder: "Austen, Jane/Persuasion (7)")

        try await index.save([first, second])

        let back = try await index.allEntries()
        #expect(back.count == 2, "a rebuild must not lose a book to a number clash")
        #expect(Set(back.map(\.folder)) == [first.folder, second.folder])
        // The folders on disk are untouched, so the *number* is what gives:
        // one of them keeps 7 and the other takes a free one. Which is which is
        // not worth promising; that they are different is.
        #expect(Set(back.map(\.number)).count == 2)
    }

    @Test("a number already taken does not stop the books that follow")
    func laterBooksStillArrive() async throws {
        let index = try LibraryIndex(inMemory: UUID().uuidString)
        try await index.save([
            entry("One", number: 1, folder: "A/One (1)"),
            entry("Two", number: 1, folder: "A/Two (1)"),
            entry("Three", number: 3, folder: "A/Three (3)"),
        ])
        #expect(try await index.count() == 3)
    }
}
