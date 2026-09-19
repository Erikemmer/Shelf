import Foundation
import GRDB
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// The reader against a Calibre library the tests build themselves.
///
/// No borrowed book goes into this repository, and a Calibre library cannot be
/// checked in anyway — so `SyntheticCalibreLibrary` writes one, with Calibre's
/// own table shapes written out by hand rather than derived from the reader.
/// A fixture generated from the reader would agree with it by construction.
@Suite("Reading a Calibre library")
struct CalibreReaderTests {

    /// Builds a fixture, reads it, and takes both away again.
    private func withLibrary(
        options: SyntheticCalibreLibrary.Options = .init(),
        _ body: (CalibreLibrary, URL, SyntheticCalibreLibrary.Summary) throws -> Void
    ) throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let summary = try SyntheticCalibreLibrary.write(to: folder, options: options)
        let library = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        try body(library, folder, summary)
    }

    // MARK: The copy

    /// The rule the whole reader is built around (CLAUDE.md, ADR 0009).
    @Test("the Calibre folder is not touched, and nothing is left behind in it")
    func readsThroughACopy() throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SyntheticCalibreLibrary.write(to: folder, options: .init(count: 3))

        let before = try fileFacts(in: folder)
        _ = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        let after = try fileFacts(in: folder)

        #expect(before == after, "the Calibre folder changed during a read")
        // No -wal or -shm that the read created, and no copy left sitting in
        // the source folder.
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "metadata.db-wal").path))
    }

    @Test("the copy is taken away again when the read is over")
    func removesItsCopy() throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SyntheticCalibreLibrary.write(to: folder, options: .init(count: 2))
        _ = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        let left = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        #expect(left.isEmpty, "the cache still holds \(left)")
    }

    /// Calibre uses WAL, and a user who is importing has not stopped using
    /// Calibre. While Calibre holds the database open, the newest rows are in
    /// `metadata.db-wal` and not yet in `metadata.db`, so a copy of the one
    /// file is the library *as of the last checkpoint* — which is how an import
    /// silently misses the newest books rather than failing.
    ///
    /// The open connection here is the point of the test, not an accident: it
    /// is Calibre, still running.
    @Test("a book that is still only in the write-ahead log is read")
    func copiesTheWriteAheadLog() throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SyntheticCalibreLibrary.write(to: folder, options: .init(count: 2))

        let database = folder.appending(path: "metadata.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        let calibre = try DatabaseQueue(path: database.path, configuration: configuration)
        try calibre.write { db in
            try db.execute(
                sql: """
                    INSERT INTO books (id, title, sort, path, uuid, has_cover)
                    VALUES (99, 'Only in the WAL', 'Only in the WAL', 'W/Only (99)', ?, 0)
                    """,
                arguments: [UUID().uuidString])
        }
        // Still open, exactly as Calibre would have it, so the row is in the
        // -wal and not in metadata.db.
        #expect(
            FileManager.default.fileExists(atPath: database.path + "-wal"),
            "the fixture did not produce a write-ahead log, so this proves nothing")

        let library = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        try calibre.close()
        #expect(library.books.map(\.book.title).contains("Only in the WAL"))
    }

    // MARK: What it read

    @Test("every book comes back, in Calibre's own order")
    func readsEveryBook() throws {
        try withLibrary(options: .init(count: 5)) { library, _, _ in
            #expect(library.books.count == 5)
            #expect(library.books.map(\.number) == [1, 2, 3, 4, 5])
            #expect(library.books.first?.book.title == "Synthetic Book 1")
        }
    }

    /// The identity rule (CONCEPT §5.3): a second import of the same library
    /// must recognise the same books, and only the UUID can say so.
    @Test("Calibre's UUID becomes the book's identity")
    func takesOverTheUUID() throws {
        try withLibrary { library, folder, _ in
            let fromDatabase = try uuidsInDatabase(at: folder.appending(path: "metadata.db"))
            #expect(library.books.map { $0.book.id.uuidString.lowercased() }.sorted() == fromDatabase.sorted())
        }
    }

    @Test("authors, tags, series, rating, publisher, language and description arrive")
    func readsTheFields() throws {
        try withLibrary { library, _, _ in
            let first = try #require(library.books.first)
            #expect(first.book.authors == ["Le Guin, Ursula K."])
            #expect(first.book.tags == ["science fiction"])
            #expect(first.book.publisher == "Gollancz")
            #expect(first.book.language == "eng")
            #expect(first.book.description?.hasPrefix("Two worlds") == true)
            #expect(first.book.series?.name == "Hainish Cycle")
            #expect(first.book.identifiers["isbn"] != nil)
            // Calibre's ten-point scale is kept, so a half star survives a
            // round trip (DATA-MODEL §3).
            #expect(library.books.contains { $0.book.rating > 0 })
        }
    }

    @Test("a book without a series has none, rather than an empty one")
    func noSeriesIsNoSeries() throws {
        try withLibrary { library, _, _ in
            #expect(library.books.contains { $0.book.series == nil })
        }
    }

    /// Calibre writes a real comma in a name as a `|`. Left alone it reaches
    /// the folder name.
    @Test("a pipe in an author's name comes back as the comma it stands for")
    func unpipesAuthors() throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SyntheticCalibreLibrary.write(to: folder, options: .init(count: 1))
        try renameFirstAuthor(at: folder.appending(path: "metadata.db"), to: "Smith|Jones, Alex")
        let library = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        #expect(library.books.first?.book.authors == ["Smith,Jones, Alex"])
    }

    @Test("the files Calibre lists come back with their paths")
    func readsTheFiles() throws {
        try withLibrary { library, _, _ in
            let first = try #require(library.books.first)
            let file = try #require(first.files.first)
            #expect(file.calibreFormat == "EPUB")
            #expect(file.format == .epub)
            #expect(file.relativePath.hasPrefix("Le Guin, Ursula K./Synthetic Book 1 (1)/"))
            #expect(file.relativePath.hasSuffix(".epub"))
            #expect(file.claimedSize > 0)
        }
    }

    // MARK: Custom columns

    @Test("the four kinds v1.0 shows come back as text a person can read")
    func readsCustomColumns() throws {
        try withLibrary { library, _, _ in
            let labels = library.customColumns.map(\.label).sorted()
            #expect(labels == ["owned", "pages", "read_date", "shelf_note"])
            let kinds = Dictionary(
                uniqueKeysWithValues: library.customColumns.map { ($0.label, $0.kind.label) })
            #expect(kinds["read_date"] == "Date")
            #expect(kinds["owned"] == "Yes/No")
            #expect(kinds["shelf_note"] == "Text")
            #expect(kinds["pages"] == "Number")

            let first = try #require(library.books.first)
            // A bool reads as a word, not as a 1: the inspector shows this.
            #expect(first.customValues["owned"] == "Yes" || first.customValues["owned"] == "No")
            #expect(first.customValues["pages"] == "101")
            #expect(first.customValues["shelf_note"] == "A note about book 1")
            #expect(first.customValues["read_date"]?.hasPrefix("2023-1") == true)
        }
    }

    /// A normalized column keeps its values in their own table with a link
    /// table beside it, and a plain one keeps them in the row. Which shape a
    /// column has is Calibre's decision, not the datatype's, so both are read.
    @Test("both shapes of custom column are read")
    func readsBothColumnShapes() throws {
        try withLibrary { library, _, _ in
            let normalized = try #require(library.customColumns.first { $0.label == "shelf_note" })
            let plain = try #require(library.customColumns.first { $0.label == "pages" })
            #expect(normalized.isNormalized)
            #expect(!plain.isNormalized)
            #expect(library.books.allSatisfy { $0.customValues["shelf_note"] != nil })
            #expect(library.books.allSatisfy { $0.customValues["pages"] != nil })
        }
    }

    /// The claim in CONCEPT §13: an unknown column type is a line in the
    /// report, never an abort.
    @Test("a datatype this Shelf never heard of is reported, not thrown")
    func unknownColumnIsReported() throws {
        try withLibrary { library, _, _ in
            #expect(library.unknownColumns.map(\.label) == ["mood"])
            #expect(library.unknownColumns.first?.datatype == "unknowable")
            #expect(library.warnings.contains { $0.contains("Mood") && $0.contains("unknowable") })
            // And the rest of the library came in regardless.
            #expect(library.books.count == 5)
        }
    }

    /// GRDB reads strictly, and is right to. But a custom column's declared
    /// type is Calibre's choice and SQLite's affinity rules do the rest, so a
    /// library where somebody changed a column's kind can hold `101` as the
    /// text "101". For a library Shelf only ever reads, refusing a value that
    /// is plainly there would be the wrong kind of correctness.
    @Test("a number a column happens to hold as text is still a number")
    func numberStoredAsText() throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SyntheticCalibreLibrary.write(to: folder, options: .init(count: 1))

        let queue = try DatabaseQueue(path: folder.appending(path: "metadata.db").path)
        try queue.write { db in
            // `pages` is the INTEGER column; this puts a string into it, which
            // SQLite allows and a re-typed column really does produce.
            try db.execute(sql: "UPDATE custom_column_4 SET value = '242' WHERE book = 1")
            try db.execute(sql: "UPDATE custom_column_2 SET value = 'true' WHERE book = 1")
        }
        try queue.close()

        let library = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        let first = try #require(library.books.first)
        #expect(first.customValues["pages"] == "242")
        // "true" is not a number in any reading, so it is left out rather than
        // guessed at: a value nobody can interpret is not a value.
        #expect(first.customValues["owned"] == nil)
    }

    // MARK: The schema version

    @Test("a known schema version says nothing")
    func knownSchema() throws {
        try withLibrary { library, _, _ in
            #expect(library.schema.isKnown)
            #expect(library.schema.warning == nil)
            #expect(library.schema.libraryID != nil)
        }
    }

    @Test("an unknown schema version is a warning and the books still arrive")
    func unknownSchema() throws {
        try withLibrary(options: .init(count: 3, userVersion: 99)) { library, _, _ in
            #expect(!library.schema.isKnown)
            #expect(library.schema.userVersion == 99)
            #expect(library.schema.warning?.contains("99") == true)
            #expect(library.books.count == 3, "an unknown version must not cost the books")
        }
    }

    // MARK: When there is nothing to read

    @Test("a folder with no metadata.db says so by name")
    func noDatabase() throws {
        let root = try TemporaryFolder()
        let empty = root.url.appending(path: "Not A Library")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: CalibreReader.Failure.noDatabase(folder: empty.path)) {
            try CalibreReader().read(folder: empty, cacheDirectory: root.url)
        }
    }

    /// Erik's own `Calibre Library Erik` in ~/Downloads is exactly this: a
    /// database with no book folders beside it. It has to read as a library
    /// with books whose files are missing, not as a failure.
    @Test("a database without its book folders reads as books with missing files")
    func databaseWithoutFolders() throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SyntheticCalibreLibrary.write(to: folder, options: .init(count: 3, includeQuirks: false))
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path)
        where !name.hasPrefix("metadata.db") {
            try FileManager.default.removeItem(at: folder.appending(path: name))
        }
        let library = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        #expect(library.books.count == 3)
        #expect(library.books.allSatisfy { !$0.files.isEmpty })
    }

    // MARK: Helpers

    private func uuidsInDatabase(at database: URL) throws -> [String] {
        let queue = try DatabaseQueue(path: database.path)
        defer { try? queue.close() }
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT uuid FROM books ORDER BY id").map { $0.lowercased() }
        }
    }

    private func renameFirstAuthor(at database: URL, to name: String) throws {
        let queue = try DatabaseQueue(path: database.path)
        defer { try? queue.close() }
        try queue.write { db in
            try db.execute(sql: "UPDATE authors SET name = ? WHERE id = 1", arguments: [name])
        }
    }

    private func fileFacts(in folder: URL) throws -> [String] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: folder.path) else { return [] }
        var facts: [String] = []
        for case let path as String in walker {
            let full = folder.appending(path: path)
            let attributes = try manager.attributesOfItem(atPath: full.path)
            let size = (attributes[.size] as? Int64) ?? 0
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            facts.append("\(path)|\(size)|\(modified)")
        }
        return facts.sorted()
    }
}
