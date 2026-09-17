import Foundation
import Testing

@testable import ShelfCore

/// Editing metadata: the chain from "old book, new book" to a written
/// `metadata.opf` and an index that agrees with it.
///
/// The three claims worth testing are the three that can quietly be false: a
/// round trip through the file loses nothing, an undo restores the *previous
/// value* rather than something recomputed from it, and an edit keeps what the
/// file knew that Shelf does not model.
@Suite("Editing metadata")
struct MetadataEditorTests {

    /// A book with every field set, so "lossless" means every field and not
    /// the four the writer happens to remember.
    private func fullBook(id: UUID = UUID()) -> Book {
        Book(
            id: id,
            title: "The Dispossessed",
            authors: ["Ursula K. Le Guin", "A Second Author"],
            series: SeriesRef(name: "Hainish Cycle", index: 6.5),
            rating: 7,
            isRead: true,
            publisher: "Gollancz",
            published: Date(timeIntervalSince1970: 1_000_000_000),
            language: "en",
            description: "Two worlds, one wall.",
            tags: ["science fiction", "utopia"],
            identifiers: ["isbn": "9780061054884", "goodreads": "13651"],
            addedAt: Date(timeIntervalSince1970: 1_600_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: The round trip

    @Test("book → OPF → book loses nothing, including the modification date")
    func roundTripIsLossless() throws {
        let book = fullBook()
        let parsed = try OPFDocument.read(Data(OPFDocument.render(book).utf8), fallbackTitle: "x")

        for field in MetadataChange.Field.allCases {
            #expect(!field.differs(book, parsed.book), "\(field.label) did not survive the round trip")
        }
        #expect(parsed.book.id == book.id)
        #expect(parsed.book.addedAt == book.addedAt)
        // The one the writer forgot until Sprint 2: read since the beginning,
        // never written, so every rebuild dated every book to the rebuild.
        #expect(parsed.book.modifiedAt == book.modifiedAt)
    }

    @Test("a second round trip changes nothing – the written form is a fixed point")
    func roundTripIsStable() throws {
        let once = OPFDocument.render(fullBook())
        let parsed = try OPFDocument.read(Data(once.utf8), fallbackTitle: "x")
        #expect(OPFDocument.render(parsed.book) == once)
    }

    @Test("the five stars and Calibre's ten are the same rating")
    func starScale() {
        var book = Book(title: "x")
        for stars in 0...5 {
            book.stars = stars
            #expect(book.rating == stars * 2)
            #expect(book.stars == stars)
        }
        // Calibre's half stars round up rather than down: a 7 is four stars,
        // not three, because a reader who set three and a half meant more than
        // three.
        book.rating = 7
        #expect(book.stars == 4)
        book.rating = 0
        #expect(book.stars == 0)
    }

    // MARK: What a change knows about itself

    @Test("a change names only what actually changed")
    func changeNamesItsFields() {
        let book = fullBook()
        let change = MetadataChange.make(from: book) { $0.stars = 2 }
        #expect(change.fields == [.rating])
        #expect(change.actionName == "Rating")
        #expect(!change.isEmpty)

        let two = MetadataChange.make(from: book) {
            $0.isRead = false
            $0.tags = ["other"]
        }
        #expect(two.fields == [.isRead, .tags])
        #expect(two.actionName == "Metadata")
    }

    @Test("setting a field to what it already is is not a change")
    func noChangeIsEmpty() {
        let book = fullBook()
        let change = MetadataChange.make(from: book) { $0.rating = book.rating }
        #expect(change.isEmpty)
        #expect(change.actionName == "Metadata")
    }

    @Test("undo gives back exactly the previous state, timestamps and all")
    func inverseRestoresEverything() {
        let book = fullBook()
        let change = MetadataChange.make(from: book, at: Date(timeIntervalSince1970: 1_800_000_000)) {
            $0.stars = 1
            $0.isRead = false
        }
        #expect(change.after.modifiedAt == Date(timeIntervalSince1970: 1_800_000_000))

        let undone = change.inverse
        #expect(undone.after == book)
        #expect(undone.after.modifiedAt == book.modifiedAt)
        // Redo is the inverse of the undo, and it is the same change again.
        #expect(undone.inverse.after == change.after)
    }

    @Test("the modification date is stamped to whole seconds, as the file stores it")
    func stampMatchesTheFilesPrecision() throws {
        let change = MetadataChange.make(
            from: fullBook(), at: Date(timeIntervalSince1970: 1_800_000_000.987)
        ) { $0.stars = 5 }
        let parsed = try OPFDocument.read(
            Data(OPFDocument.render(change.after).utf8), fallbackTitle: "x")
        #expect(parsed.book.modifiedAt == change.after.modifiedAt)
    }

    // MARK: Writing

    /// Everything below shares this: a library folder with one book in it,
    /// whose `metadata.opf` carries a Calibre custom column and two shelves
    /// that the index knows nothing about.
    private func libraryWithOneBook() throws -> (
        folder: TemporaryFolder, entry: LibraryEntry, editor: MetadataEditor
    ) {
        let temporary = try TemporaryFolder()
        let book = fullBook()
        let relative = "Le Guin, Ursula K./The Dispossessed (1)"
        try FileManager.default.createDirectory(
            at: temporary.url.appendingPathComponent(relative, isDirectory: true),
            withIntermediateDirectories: true)
        var shelved = book
        shelved.shelves = ["Fiction/Science Fiction", "To Read"]
        try OPFDocument.write(
            shelved, to: temporary.url.appendingPathComponent(relative, isDirectory: true),
            unmappedMetas: ["calibre_custom:#shelf_location": "top left", "some:other": "kept"])

        let entry = LibraryEntry(book: book, number: 1, folder: relative)
        return (temporary, entry, MetadataEditor(root: temporary.url))
    }

    @Test("an edit keeps what the file knew and Shelf does not model")
    func editKeepsUnknownMetasAndShelves() async throws {
        let (temporary, entry, editor) = try libraryWithOneBook()
        let index = try LibraryIndex(inMemory: #function)
        try await index.save(entry)

        // The entry as the *index* hands it back – which is what the window
        // holds, and what an edit is built from.
        let fromIndex = try #require(try await index.entry(id: entry.id))
        let change = MetadataChange.make(from: fromIndex.book) { $0.stars = 5 }
        _ = try await editor.apply(change, to: fromIndex, in: index)

        let written = try OPFDocument.read(
            Data(
                contentsOf: temporary.url.appendingPathComponent(entry.folder)
                    .appendingPathComponent(OPFDocument.fileName)),
            fallbackTitle: "x")

        #expect(written.book.rating == 10)
        // The index this entry came back from knows nothing about these
        // shelves – no tree was saved into it – and the edit still must not
        // drop them, because the *file* is what a rebuild reads.
        #expect(written.book.shelves == ["Fiction/Science Fiction", "To Read"])
        #expect(written.unmappedMetas["calibre_custom:#shelf_location"] == "top left")
        #expect(written.unmappedMetas["some:other"] == "kept")
        // The rest of the book is untouched by a rating change.
        #expect(written.book.title == "The Dispossessed")
        #expect(written.book.identifiers["isbn"] == "9780061054884")
        #expect(written.book.addedAt == entry.book.addedAt)
    }

    @Test("the index carries identifiers back, so an edit cannot lose the ISBN")
    func indexKeepsIdentifiers() async throws {
        let (_, entry, _) = try libraryWithOneBook()
        let index = try LibraryIndex(inMemory: #function)
        try await index.save(entry)

        let fromIndex = try #require(try await index.entry(id: entry.id))
        #expect(fromIndex.book.identifiers["isbn"] == "9780061054884")
        #expect(fromIndex.book.identifiers["goodreads"] == "13651")
        // The duplicate check's own derived row is not a claim the book makes.
        #expect(fromIndex.book.identifiers["isbn_normalised"] == nil)

        // Saving it again must not empty the table it was read from.
        try await index.save(fromIndex)
        let again = try #require(try await index.entry(id: entry.id))
        #expect(again.book.identifiers["isbn"] == "9780061054884")
        #expect(try await index.bookIDs(isbn: "9780061054884") == [entry.id])
    }

    @Test("the index follows the file: rating, read status and search")
    func indexFollows() async throws {
        let (_, entry, editor) = try libraryWithOneBook()
        let index = try LibraryIndex(inMemory: #function)
        try await index.save(entry)

        let change = MetadataChange.make(from: entry.book) {
            $0.stars = 2
            $0.isRead = false
            $0.title = "The Dispossessed, Revised"
        }
        let updated = try await editor.apply(change, to: entry, in: index)
        #expect(updated.book.rating == 4)

        let stored = try #require(try await index.entry(id: entry.id))
        #expect(stored.book.rating == 4)
        #expect(stored.book.isRead == false)
        #expect(stored.book.title == "The Dispossessed, Revised")
        #expect(try await index.search("Revised").contains(entry.id))
    }

    @Test("undoing an edit puts the file back exactly as it was")
    func undoRestoresTheFile() async throws {
        let (temporary, entry, editor) = try libraryWithOneBook()
        let index = try LibraryIndex(inMemory: #function)
        try await index.save(entry)
        let opfURL = temporary.url.appendingPathComponent(entry.folder)
            .appendingPathComponent(OPFDocument.fileName)
        let before = try Data(contentsOf: opfURL)

        let change = MetadataChange.make(from: entry.book) { $0.stars = 5 }
        let edited = try await editor.apply(change, to: entry, in: index)
        #expect(try Data(contentsOf: opfURL) != before)

        _ = try await editor.apply(change.inverse, to: edited, in: index)
        #expect(try Data(contentsOf: opfURL) == before)

        let stored = try #require(try await index.entry(id: entry.id))
        #expect(stored.book == entry.book)
    }

    @Test("ten edits leave the book file untouched, byte for byte")
    func theBookFileIsNeverWritten() async throws {
        let (temporary, entry, editor) = try libraryWithOneBook()
        let index = try LibraryIndex(inMemory: #function)
        let bookURL = temporary.url.appendingPathComponent(entry.folder)
            .appendingPathComponent("The Dispossessed - Ursula K. Le Guin.epub")
        try Data("not really an EPUB, but bytes nobody may touch".utf8).write(to: bookURL)
        let digestBefore = try FileDigest.sha256(of: bookURL, makeHasher: PortableSHA256Hasher.factory)
        let modifiedBefore =
            try FileManager.default.attributesOfItem(atPath: bookURL.path)[.modificationDate]
            as? Date
        try await index.save(entry)

        var current = entry
        for round in 1...10 {
            let change = MetadataChange.make(from: current.book) {
                $0.stars = round % 6
                $0.isRead = round.isMultiple(of: 2)
            }
            current = try await editor.apply(change, to: current, in: index)
        }

        #expect(
            try FileDigest.sha256(of: bookURL, makeHasher: PortableSHA256Hasher.factory) == digestBefore)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: bookURL.path)[.modificationDate] as? Date)
                == modifiedBefore)
    }

    @Test("a write that cannot happen leaves no half-written file behind")
    func writeIsAtomic() async throws {
        let (temporary, entry, editor) = try libraryWithOneBook()
        let index = try LibraryIndex(inMemory: #function)
        try await index.save(entry)
        let folderURL = temporary.url.appendingPathComponent(entry.folder)
        let before = try Data(contentsOf: folderURL.appendingPathComponent(OPFDocument.fileName))

        // A file where the book's folder should be: the write cannot create the
        // directory and cannot create its temporary file either. Simulated this
        // way rather than with permissions, because a test that runs as root –
        // as a CI container does – would sail straight through a chmod.
        let blocked = LibraryEntry(book: entry.book, number: 2, folder: "blocked")
        try Data("in the way".utf8).write(to: temporary.url.appendingPathComponent("blocked"))

        let change = MetadataChange.make(from: entry.book) { $0.stars = 3 }
        await #expect(throws: OPFDocument.Failure.self) {
            try await editor.apply(change, to: blocked, in: index)
        }

        // Nothing left in the library root but the two folders and the file
        // that was put in the way – no `.part`, no temporary name.
        #expect(temporary.names(in: "") == ["Le Guin, Ursula K.", "blocked"])
        #expect(temporary.names(in: entry.folder) == [OPFDocument.fileName])
        #expect(try Data(contentsOf: folderURL.appendingPathComponent(OPFDocument.fileName)) == before)
    }

    @Test("an OPF belonging to a different book is not merged into this one")
    func aForeignOPFIsNotMerged() async throws {
        let (temporary, entry, editor) = try libraryWithOneBook()
        let index = try LibraryIndex(inMemory: #function)
        try await index.save(entry)

        // Someone else's metadata.opf, in this book's folder.
        try OPFDocument.write(
            Book(title: "A Different Book", identifiers: ["isbn": "0000000000000"]),
            to: temporary.url.appendingPathComponent(entry.folder, isDirectory: true))

        let change = MetadataChange.make(from: entry.book) { $0.stars = 4 }
        _ = try await editor.apply(change, to: entry, in: index)

        let written = try OPFDocument.read(
            Data(
                contentsOf: temporary.url.appendingPathComponent(entry.folder)
                    .appendingPathComponent(OPFDocument.fileName)),
            fallbackTitle: "x")
        #expect(written.book.id == entry.book.id)
        #expect(written.book.title == "The Dispossessed")
        #expect(written.book.identifiers["isbn"] == "9780061054884")
    }
}
