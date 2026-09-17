import Foundation
import GRDB

/// Builds a Calibre library that nobody wrote, so the reader can be tested
/// against one.
///
/// No borrowed book goes into this repository (CLAUDE.md), and a Calibre
/// library is not something one can check in anyway. So the tests build one:
/// the folder layout Calibre uses, a `metadata.db` with Calibre's own tables,
/// and — deliberately — the four things that go wrong in a real library, since
/// those are the paths worth testing:
///
/// * a book whose file the database lists and the disk does not have,
/// * a book that claims no cover,
/// * a `metadata.opf` that will not parse,
/// * a file on the disk that the database has never heard of.
///
/// It lives beside `ZipWriter`, `SyntheticEPUB` and `MinimalPNG`, which exist
/// for the same reason and have the same problem: they are production surface
/// that production never calls. `docs/BACKLOG.md` carries the move, and it is
/// not the free one it looks like — `OPFDocument.escaped` is internal, so the
/// move is an API decision and not a drag-and-drop.
public enum SyntheticCalibreLibrary {

    public struct Options: Sendable {
        public var count: Int
        /// The missing file, the coverless book, the unreadable OPF and the
        /// orphan on disk. On for the fixture, off for a big measuring run
        /// where they would only be noise.
        public var includeQuirks: Bool
        /// What the database claims to be. Used to make an *unknown* version.
        public var userVersion: Int

        public init(count: Int = 5, includeQuirks: Bool = true, userVersion: Int = 26) {
            self.count = count
            self.includeQuirks = includeQuirks
            self.userVersion = userVersion
        }
    }

    /// What was written, so a test can compare the reader's answer with the
    /// truth rather than with itself.
    public struct Summary: Equatable, Sendable {
        public var books: Int
        public var authors: Int
        public var series: Int
        public var tags: Int
        public var files: Int
        public var totalBytes: Int64
        /// Listed in the database, absent from the disk.
        public var missingFiles: Int
        /// On the disk, absent from the database.
        public var orphanFiles: Int
        public var booksWithoutCover: Int
        public var unreadableOPFs: Int
    }

    // The five kinds a fixture needs: the four v1.0 shows, plus one this Shelf
    // has never heard of, because "an unknown datatype is a line in the report"
    // is a claim and not a hope.
    static let columns: [(number: Int, label: String, name: String, datatype: String, normalized: Bool)] = [
        (1, "read_date", "Date read", "datetime", false),
        (2, "owned", "Owned", "bool", false),
        (3, "shelf_note", "Note", "text", true),
        (4, "pages", "Pages", "int", false),
        (5, "mood", "Mood", "unknowable", false),
    ]

    static let authorNames = ["Le Guin, Ursula K.", "Jemisin, N. K.", "Clarke, Susanna"]
    static let seriesNames = ["Hainish Cycle", "The Broken Earth"]
    static let tagNames = ["science fiction", "fantasy", "award winner"]

    @discardableResult
    public static func write(to folder: URL, options: Options = Options()) throws -> Summary {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        var summary = Summary(
            books: 0, authors: 0, series: 0, tags: 0, files: 0, totalBytes: 0,
            missingFiles: 0, orphanFiles: 0, booksWithoutCover: 0, unreadableOPFs: 0)

        let database = try DatabaseQueue(path: folder.appending(path: "metadata.db").path)
        try database.write { db in
            try createSchema(db, userVersion: options.userVersion)
            try fill(db, folder: folder, options: options, summary: &summary)
        }
        // Closed before anyone reads it, so the reader sees a checkpointed file
        // rather than one this process still holds open.
        try database.close()
        return summary
    }

    // MARK: The schema

    /// Calibre's tables, as far as `CalibreReader` reads them.
    ///
    /// Written out rather than generated: the point of the fixture is to be
    /// the *shape Calibre has*, and a shape derived from the reader would agree
    /// with the reader by construction and prove nothing.
    static func createSchema(_ db: Database, userVersion: Int) throws {
        for statement in [
            "CREATE TABLE library_id (id INTEGER PRIMARY KEY, uuid TEXT NOT NULL)",
            """
            CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT 'Unknown',
              sort TEXT, timestamp TIMESTAMP, pubdate TIMESTAMP, series_index REAL NOT NULL DEFAULT 1.0,
              author_sort TEXT, isbn TEXT DEFAULT '', lccn TEXT DEFAULT '', path TEXT NOT NULL DEFAULT '',
              flags INTEGER NOT NULL DEFAULT 1, uuid TEXT, has_cover BOOL DEFAULT 0,
              last_modified TIMESTAMP NOT NULL DEFAULT '2000-01-01 00:00:00+00:00')
            """,
            "CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort TEXT, link TEXT NOT NULL DEFAULT '')",
            "CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, author INTEGER NOT NULL)",
            "CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort TEXT)",
            "CREATE TABLE books_series_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, series INTEGER NOT NULL)",
            "CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
            "CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, tag INTEGER NOT NULL)",
            "CREATE TABLE ratings (id INTEGER PRIMARY KEY, rating INTEGER)",
            "CREATE TABLE books_ratings_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, rating INTEGER NOT NULL)",
            "CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, text TEXT NOT NULL)",
            "CREATE TABLE identifiers (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, type TEXT NOT NULL DEFAULT 'isbn', val TEXT NOT NULL)",
            """
            CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, format TEXT NOT NULL,
              uncompressed_size INTEGER NOT NULL, name TEXT NOT NULL)
            """,
            "CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, sort TEXT)",
            "CREATE TABLE books_publishers_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, publisher INTEGER NOT NULL)",
            "CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT NOT NULL)",
            """
            CREATE TABLE books_languages_link (id INTEGER PRIMARY KEY, book INTEGER NOT NULL,
              lang_code INTEGER NOT NULL, item_order INTEGER NOT NULL DEFAULT 0)
            """,
            """
            CREATE TABLE custom_columns (id INTEGER PRIMARY KEY, label TEXT NOT NULL, name TEXT NOT NULL,
              datatype TEXT NOT NULL, mark_for_delete BOOL DEFAULT 0, editable BOOL DEFAULT 1,
              display TEXT DEFAULT '{}', is_multiple BOOL DEFAULT 0, normalized BOOL NOT NULL)
            """,
            // Read by nobody here, and present on purpose: CONCEPT §7 says it
            // is ignored, and a table that is ignored has to exist for that to
            // be worth saying.
            "CREATE TABLE books_plugin_data (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, name TEXT NOT NULL, val TEXT NOT NULL)",
        ] {
            try db.execute(sql: statement)
        }
        try db.execute(sql: "PRAGMA user_version = \(userVersion)")
        try db.execute(sql: "INSERT INTO library_id (id, uuid) VALUES (1, ?)", arguments: [UUID().uuidString])

        for column in columns {
            try db.execute(
                sql: """
                    INSERT INTO custom_columns (id, label, name, datatype, normalized, is_multiple)
                    VALUES (?, ?, ?, ?, ?, 0)
                    """,
                arguments: [column.number, column.label, column.name, column.datatype, column.normalized])
            if column.normalized {
                try db.execute(
                    sql:
                        "CREATE TABLE custom_column_\(column.number) (id INTEGER PRIMARY KEY, value TEXT NOT NULL UNIQUE)"
                )
                try db.execute(
                    sql: """
                        CREATE TABLE books_custom_column_\(column.number)_link
                          (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, value INTEGER NOT NULL)
                        """)
            } else {
                // Calibre declares the value column with the type its datatype
                // calls for — `BOOL`, `INTEGER`, `REAL`, `TIMESTAMP`, `TEXT` —
                // and SQLite's affinity then decides what is actually stored.
                // Declaring everything `TEXT` here would have made the fixture
                // a shape Calibre never writes, and the first version did:
                // `101` went in as the string "101" and the reader, reading
                // strictly, found nothing.
                let type = Self.sqliteType(for: column.datatype)
                try db.execute(
                    sql:
                        "CREATE TABLE custom_column_\(column.number) (id INTEGER PRIMARY KEY, book INTEGER NOT NULL, value \(type))"
                )
            }
        }
    }

    // MARK: The rows and the files

    static func fill(
        _ db: Database, folder: URL, options: Options, summary: inout Summary
    ) throws {
        for (index, name) in authorNames.enumerated() {
            try db.execute(
                sql: "INSERT INTO authors (id, name, sort) VALUES (?, ?, ?)",
                arguments: [index + 1, name, name])
        }
        for (index, name) in seriesNames.enumerated() {
            try db.execute(
                sql: "INSERT INTO series (id, name, sort) VALUES (?, ?, ?)", arguments: [index + 1, name, name])
        }
        for (index, name) in tagNames.enumerated() {
            try db.execute(sql: "INSERT INTO tags (id, name) VALUES (?, ?)", arguments: [index + 1, name])
        }
        try db.execute(sql: "INSERT INTO publishers (id, name, sort) VALUES (1, 'Gollancz', 'Gollancz')")
        try db.execute(sql: "INSERT INTO languages (id, lang_code) VALUES (1, 'eng')")
        // Calibre's `ratings` table holds each distinct value once, 0…10.
        for value in stride(from: 0, through: 10, by: 2) {
            try db.execute(
                sql: "INSERT INTO ratings (id, rating) VALUES (?, ?)", arguments: [value / 2 + 1, value])
        }
        summary.authors = authorNames.count
        summary.series = seriesNames.count
        summary.tags = tagNames.count

        for number in 1...options.count {
            try writeBook(db, number: number, folder: folder, options: options, summary: &summary)
            summary.books += 1
        }

        if options.includeQuirks {
            // A file on the disk that the database has never heard of. Calibre
            // leaves these behind when a format is removed from the library but
            // not from the folder, and the census has to see it.
            let orphanFolder = folder.appending(path: "\(authorNames[0])/An Orphan (999)")
            try FileManager.default.createDirectory(at: orphanFolder, withIntermediateDirectories: true)
            try Data("not in the database".utf8).write(to: orphanFolder.appending(path: "orphan.epub"))
            summary.orphanFiles = 1
        }
    }

    static func writeBook(
        _ db: Database, number: Int, folder: URL, options: Options, summary: inout Summary
    ) throws {
        let manager = FileManager.default
        let author = authorNames[(number - 1) % authorNames.count]
        let title = "Synthetic Book \(number)"
        let relative = "\(author)/\(title) (\(number))"
        let bookFolder = folder.appending(path: relative)
        try manager.createDirectory(at: bookFolder, withIntermediateDirectories: true)

        // `truncatingIfNeeded`, because `UInt8(number)` traps above 255 and a
        // fixture is asked for two thousand books. It cost a proof run: the
        // tool wrote 255 folders, crashed with SIGTRAP, and left a metadata.db
        // of nought bytes behind a journal — which the census then read as a
        // library with no tables, correctly and uselessly.
        let quirky = options.includeQuirks
        let fileIsMissing = quirky && number == 3
        let hasCover = !(quirky && number == 4)
        let opfIsBroken = quirky && number == 5

        var book = Book(id: UUID(), title: title, authors: [author])
        book.publisher = "Gollancz"
        book.language = "eng"
        book.tags = [tagNames[(number - 1) % tagNames.count]]
        book.description = "Two worlds, one wall. Book \(number)."
        let fileName = "\(title) - \(author)"
        let cover = hasCover ? MinimalPNG.cover(width: 60, height: 90, seed: UInt8(truncatingIfNeeded: number)) : nil
        let synthetic = SyntheticEPUB(book: book, cover: cover)
        let epub = synthetic.data()

        // The one book whose file the database lists and the disk has not got.
        if !fileIsMissing {
            try epub.write(to: bookFolder.appending(path: "\(fileName).epub"))
            summary.files += 1
            summary.totalBytes += Int64(epub.count)
        } else {
            summary.missingFiles += 1
        }
        if let cover {
            // Calibre names it `cover.jpg` whatever the bytes are; Shelf's own
            // `CoverFile` names a file after what it actually holds, and the
            // difference is one of the things the import has to survive.
            try cover.write(to: bookFolder.appending(path: "cover.jpg"))
        } else {
            summary.booksWithoutCover += 1
        }
        // Calibre writes an OPF beside every book. The unreadable one is there
        // because Shelf falls back to the database for it, and "falls back"
        // has to be something a test has watched happen.
        let opf = opfIsBroken ? "<?xml version='1.0'?><package><metadata>" : synthetic.opf()
        try Data(opf.utf8).write(to: bookFolder.appending(path: "metadata.opf"))
        if opfIsBroken { summary.unreadableOPFs += 1 }

        try db.execute(
            sql: """
                INSERT INTO books (id, title, sort, timestamp, pubdate, series_index, author_sort,
                  isbn, path, uuid, has_cover, last_modified)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                number, title, TitleSort.of(title), "2024-01-0\(min(9, number)) 10:00:00+00:00",
                "2019-04-01 00:00:00+00:00", Double(number), author, "",
                relative, book.id.uuidString, hasCover ? 1 : 0, "2024-06-01 10:00:00+00:00",
            ])
        try db.execute(
            sql: "INSERT INTO books_authors_link (book, author) VALUES (?, ?)",
            arguments: [number, (number - 1) % authorNames.count + 1])
        try db.execute(
            sql: "INSERT INTO books_tags_link (book, tag) VALUES (?, ?)",
            arguments: [number, (number - 1) % tagNames.count + 1])
        try db.execute(
            sql: "INSERT INTO books_publishers_link (book, publisher) VALUES (?, 1)", arguments: [number])
        try db.execute(
            sql: "INSERT INTO books_languages_link (book, lang_code, item_order) VALUES (?, 1, 0)",
            arguments: [number])
        try db.execute(
            sql: "INSERT INTO comments (book, text) VALUES (?, ?)", arguments: [number, book.description ?? ""])
        try db.execute(
            sql: "INSERT INTO identifiers (book, type, val) VALUES (?, 'isbn', ?)",
            arguments: [number, isbn(for: number)])
        try db.execute(
            sql: "INSERT INTO data (book, format, uncompressed_size, name) VALUES (?, 'EPUB', ?, ?)",
            arguments: [number, epub.count, fileName])
        // A rating on every second book, so "unrated" is a case the fixture has.
        if number % 2 == 1 {
            try db.execute(
                sql: "INSERT INTO books_ratings_link (book, rating) VALUES (?, ?)",
                arguments: [number, number % 5 + 1])
        }
        // Two series over the whole fixture, so a book without one is a case too.
        if number <= seriesNames.count * 2, number % 2 == 1 || number == 2 {
            try db.execute(
                sql: "INSERT INTO books_series_link (book, series) VALUES (?, ?)",
                arguments: [number, (number - 1) % seriesNames.count + 1])
        }
        try writeCustomValues(db, book: number)
        try db.execute(
            sql: "INSERT INTO books_plugin_data (book, name, val) VALUES (?, 'ignored', '{}')",
            arguments: [number])
    }

    static func writeCustomValues(_ db: Database, book: Int) throws {
        try db.execute(
            sql: "INSERT INTO custom_column_1 (book, value) VALUES (?, ?)",
            arguments: [book, "2023-1\(book % 2) -01 00:00:00+00:00".replacingOccurrences(of: " -", with: "-")])
        try db.execute(
            sql: "INSERT INTO custom_column_2 (book, value) VALUES (?, ?)", arguments: [book, book % 2])
        try db.execute(
            sql: "INSERT INTO custom_column_3 (id, value) VALUES (?, ?)",
            arguments: [book, "A note about book \(book)"])
        try db.execute(
            sql: "INSERT INTO books_custom_column_3_link (book, value) VALUES (?, ?)", arguments: [book, book])
        try db.execute(
            sql: "INSERT INTO custom_column_4 (book, value) VALUES (?, ?)", arguments: [book, 100 + book])
        // Nothing is written for column 5: its datatype is one the reader does
        // not know, so there is no table shape to write into.
    }

    /// The declared type Calibre gives a custom column's value, per datatype.
    static func sqliteType(for datatype: String) -> String {
        switch datatype {
        case "bool": return "BOOL"
        case "int", "rating": return "INTEGER"
        case "float": return "REAL"
        case "datetime": return "TIMESTAMP"
        default: return "TEXT"
        }
    }

    /// A valid ISBN-13, so the importer's ISBN duplicate rule has real input.
    static func isbn(for number: Int) -> String {
        let body = String(format: "978030640%03d", number)
        var sum = 0
        for (index, digit) in body.compactMap({ Int(String($0)) }).enumerated() {
            sum += digit * (index % 2 == 0 ? 1 : 3)
        }
        return body + String((10 - sum % 10) % 10)
    }
}
