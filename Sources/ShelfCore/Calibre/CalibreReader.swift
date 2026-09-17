import Foundation
import GRDB

/// Reads a Calibre library's `metadata.db` — **through a copy, never the file
/// itself** (CLAUDE.md, [ADR 0009](../../../docs/adr/0009-calibre-is-read-through-a-copy-of-metadata-db.md)).
///
/// Calibre's database is the one thing in a Calibre library that cannot be
/// reconstructed from the folders, and a user who is importing has not stopped
/// using Calibre yet. Opening it in place — even read-only — takes SQLite locks
/// on somebody else's live database and, with a WAL, can leave files behind it
/// did not have before. So the first thing this does is copy.
///
/// Everything else here follows one rule: **a library that is odd must still
/// import.** A datatype this version has never heard of, a missing table, a
/// book whose files are gone — each is a line in the report and none of them
/// stops the read. The only errors thrown are the ones that make the whole
/// exercise pointless: there is no database, or it cannot be copied or opened.
public struct CalibreReader: Sendable {

    public enum Failure: Error, Equatable {
        /// The chosen folder holds no `metadata.db`.
        case noDatabase(folder: String)
        case cannotCopy(reason: String)
        /// The copy could not be opened. The reason is carried: "cannot read
        /// the Calibre library" on its own tells nobody what to do.
        case cannotOpen(reason: String)
    }

    /// The file every Calibre library has at its root.
    public static let databaseName = "metadata.db"

    /// SQLite writes these beside a database in WAL mode, and Calibre uses WAL.
    /// They are copied with it: a `metadata.db` copied on its own is the
    /// database *as of the last checkpoint*, which can be hours old, and the
    /// import would then silently miss every recent book.
    static let sidecarSuffixes = ["-wal", "-shm"]

    /// `user_version` values this reader has been checked against.
    ///
    /// The range is generous and its upper end is deliberately open-ended in
    /// spirit: Calibre raises this for changes that mostly do not touch the
    /// dozen tables read here, and a reader that refused every new version
    /// would break for everybody on the day Calibre shipped one.
    public static let knownUserVersions: ClosedRange<Int> = 20...29

    public init() {}

    // MARK: Reading

    /// Copies `metadata.db` into `cacheDirectory` and reads it.
    ///
    /// - Parameters:
    ///   - folder: the Calibre library. Only ever read.
    ///   - cacheDirectory: where the copy goes. The app passes
    ///     `~/Library/Caches/Shelf`; the tests pass a temporary folder. It is a
    ///     parameter rather than a constant because `ShelfCore` builds on Linux,
    ///     where that path does not exist — and because a test that wrote into
    ///     the real cache would be a test that can ruin a measurement.
    public func read(folder: URL, cacheDirectory: URL) throws -> CalibreLibrary {
        let copy = try copyDatabase(from: folder, to: cacheDirectory)
        defer { removeCopy(copy) }
        return try readCopy(at: copy.database, originalFolder: folder)
    }

    /// Where a copy went, so it can be taken away again.
    struct DatabaseCopy {
        var directory: URL
        var database: URL
    }

    /// The copy, with its WAL beside it.
    ///
    /// Into a folder of its own, named for this read, so two imports at once
    /// cannot read each other's copy, and so removing it afterwards removes
    /// exactly what was made — the rule about this cache folder is that a
    /// session deletes only what it created (CLAUDE.md).
    func copyDatabase(from folder: URL, to cacheDirectory: URL) throws -> DatabaseCopy {
        let manager = FileManager.default
        let source = folder.appending(path: Self.databaseName)
        guard manager.fileExists(atPath: source.path) else {
            throw Failure.noDatabase(folder: folder.path)
        }
        let directory = cacheDirectory.appending(path: "calibre-read-\(UUID().uuidString)")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: Self.databaseName)
            try manager.copyItem(at: source, to: destination)
            for suffix in Self.sidecarSuffixes {
                let sidecar = folder.appending(path: Self.databaseName + suffix)
                guard manager.fileExists(atPath: sidecar.path) else { continue }
                try manager.copyItem(at: sidecar, to: directory.appending(path: Self.databaseName + suffix))
            }
            return DatabaseCopy(directory: directory, database: destination)
        } catch {
            try? manager.removeItem(at: directory)
            throw Failure.cannotCopy(reason: error.localizedDescription)
        }
    }

    func removeCopy(_ copy: DatabaseCopy) {
        try? FileManager.default.removeItem(at: copy.directory)
    }

    /// Reads a copy that is already on disk. Split out so a test can hand it a
    /// fixture without going through the copying.
    func readCopy(at database: URL, originalFolder: URL) throws -> CalibreLibrary {
        let queue: DatabaseQueue
        do {
            var configuration = Configuration()
            // The copy is ours and in our own folder, and it is still opened
            // read-only: nothing here has any business writing to a Calibre
            // database, copy or not, and a reader that cannot write cannot
            // write by accident.
            configuration.readonly = true
            queue = try DatabaseQueue(path: database.path, configuration: configuration)
        } catch {
            throw Failure.cannotOpen(reason: error.localizedDescription)
        }
        do {
            return try queue.read { db in
                try Self.readEverything(db, originalFolder: originalFolder)
            }
        } catch {
            throw Failure.cannotOpen(reason: error.localizedDescription)
        }
    }

    // MARK: The reading itself

    static func readEverything(_ db: Database, originalFolder: URL) throws -> CalibreLibrary {
        var warnings: [String] = []
        let schema = try readSchema(db, warnings: &warnings)
        let (columns, unknown) = try readCustomColumns(db, warnings: &warnings)

        var books = try readBooks(db, warnings: &warnings)
        try attachAuthors(db, to: &books, warnings: &warnings)
        try attachSeries(db, to: &books, warnings: &warnings)
        try attachTags(db, to: &books, warnings: &warnings)
        try attachRatings(db, to: &books, warnings: &warnings)
        try attachComments(db, to: &books, warnings: &warnings)
        try attachIdentifiers(db, to: &books, warnings: &warnings)
        try attachPublishers(db, to: &books, warnings: &warnings)
        try attachLanguages(db, to: &books, warnings: &warnings)
        try attachFiles(db, to: &books, warnings: &warnings)
        try attachCustomValues(db, columns: columns, to: &books, warnings: &warnings)

        return CalibreLibrary(
            folder: originalFolder,
            schema: schema,
            books: books.values.sorted { $0.number < $1.number },
            customColumns: columns,
            unknownColumns: unknown,
            warnings: warnings)
    }

    static func readSchema(_ db: Database, warnings: inout [String]) throws -> CalibreSchema {
        let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        var libraryID: String?
        if try db.tableExists("library_id") {
            libraryID = try String.fetchOne(db, sql: "SELECT uuid FROM library_id LIMIT 1")
        }
        let isKnown = knownUserVersions.contains(userVersion)
        var warning: String?
        if !isKnown {
            // A warning and not a refusal. Written as a sentence a person can
            // act on: what was found, what is known, and what it means for the
            // import they are about to start.
            warning =
                "This library's schema version is \(userVersion); Shelf has been checked against "
                + "\(knownUserVersions.lowerBound)–\(knownUserVersions.upperBound). "
                + "The import will go ahead and report anything it could not read."
            warnings.append(warning!)
        }
        return CalibreSchema(
            userVersion: userVersion, libraryID: libraryID, isKnown: isKnown, warning: warning)
    }

    // MARK: Books

    static func readBooks(_ db: Database, warnings: inout [String]) throws -> [Int: CalibreBook] {
        guard try db.tableExists("books") else {
            warnings.append("The database has no `books` table – it is not a Calibre library.")
            return [:]
        }
        var books: [Int: CalibreBook] = [:]
        let rows = try Row.fetchCursor(db, sql: "SELECT * FROM books ORDER BY id")
        while let row = try rows.next() {
            guard let number: Int = row["id"] else { continue }
            let title = (row["title"] as String?) ?? "Untitled"
            var bookWarnings: [String] = []

            // Calibre's UUID is Shelf's identity (CONCEPT §5.3). A book whose
            // uuid is missing or unreadable gets a new one and says so: two
            // imports of such a book would otherwise be two books, and that is
            // worth a line in the report rather than a silent guess.
            var id = UUID()
            if let text = row["uuid"] as String?, let parsed = UUID(uuidString: text) {
                id = parsed
            } else {
                bookWarnings.append("no usable Calibre UUID; a new one was minted")
            }

            var book = Book(id: id, title: title)
            book.titleSort = (row["sort"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? TitleSort.of(title)
            if let stamp = row["timestamp"] as String?, let date = OPFDate.parse(stamp) {
                book.addedAt = date
            }
            if let stamp = row["last_modified"] as String?, let date = OPFDate.parse(stamp) {
                book.modifiedAt = date
            }
            if let stamp = row["pubdate"] as String? {
                book.published = OPFDate.parse(stamp)
            }
            // `books.isbn` is Calibre's legacy column; the `identifiers` table
            // is the modern home and wins where both have something.
            if let isbn = row["isbn"] as String?, !isbn.isEmpty {
                book.identifiers["isbn"] = isbn
            }

            let folder = (row["path"] as String?) ?? ""
            if folder.isEmpty {
                bookWarnings.append("no folder recorded in the database")
            }
            books[number] = CalibreBook(
                number: number,
                book: book,
                folder: folder,
                claimsCover: (row["has_cover"] as Int?).map { $0 != 0 } ?? false,
                warnings: bookWarnings)
        }
        return books
    }

    // MARK: The link tables

    /// Runs a query that joins a link table, and turns a missing table into a
    /// warning rather than a failure.
    ///
    /// Every one of Calibre's optional tables goes through this, which is why
    /// a trimmed or ancient database imports what it has instead of throwing
    /// on the first table nobody made.
    static func eachRow(
        _ db: Database, tables: [String], sql: String, warnings: inout [String],
        missingNote: String, handle: (Row) throws -> Void
    ) throws {
        for table in tables where try !db.tableExists(table) {
            warnings.append("No `\(table)` table – \(missingNote)")
            return
        }
        let rows = try Row.fetchCursor(db, sql: sql)
        while let row = try rows.next() { try handle(row) }
    }

    static func attachAuthors(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        // `ORDER BY link.id`, because the order authors are printed in is data:
        // the first one names the folder (DATA-MODEL §1).
        try eachRow(
            db, tables: ["books_authors_link", "authors"],
            sql: """
                SELECT link.book AS book, a.name AS name
                FROM books_authors_link link JOIN authors a ON a.id = link.author
                ORDER BY link.book, link.id
                """,
            warnings: &warnings, missingNote: "the books come in without authors"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            // Calibre stores "Le Guin, Ursula K." with a `|` where a real
            // comma belongs. Undone here rather than later: a `|` in a name
            // reaches the folder name otherwise.
            let name = ((row["name"] as String?) ?? "").replacingOccurrences(of: "|", with: ",")
            guard !name.isEmpty else { return }
            entry.book.authors.append(name)
            books[number] = entry
        }
    }

    static func attachSeries(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        // The index lives on `books.series_index`, not on the link table, which
        // is why it is read here rather than with the books: a series without
        // a name has no index worth keeping.
        try eachRow(
            db, tables: ["books_series_link", "series"],
            sql: """
                SELECT link.book AS book, s.name AS name, b.series_index AS position
                FROM books_series_link link
                JOIN series s ON s.id = link.series
                JOIN books b ON b.id = link.book
                """,
            warnings: &warnings, missingNote: "the books come in without series"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            guard let name = row["name"] as String?, !name.isEmpty else { return }
            entry.book.series = SeriesRef(name: name, index: row["position"] as Double?)
            books[number] = entry
        }
    }

    static func attachTags(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        try eachRow(
            db, tables: ["books_tags_link", "tags"],
            sql: """
                SELECT link.book AS book, t.name AS name
                FROM books_tags_link link JOIN tags t ON t.id = link.tag
                """,
            warnings: &warnings, missingNote: "the books come in without tags"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            guard let name = row["name"] as String?, !name.isEmpty else { return }
            entry.book.tags.append(name)
            books[number] = entry
        }
        // Sorted once at the end, because `Book` promises sorted tags and three
        // places read them back in that order (DATA-MODEL §3).
        for (number, var entry) in books {
            entry.book.tags = entry.book.tags.sorted { $0.lowercased() < $1.lowercased() }
            books[number] = entry
        }
    }

    static func attachRatings(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        // Calibre's 0…10 is kept as it is: `Book.rating` is the same scale and
        // `Book.stars` is the conversion, so a half star set in Calibre
        // survives a round trip (DATA-MODEL §3).
        try eachRow(
            db, tables: ["books_ratings_link", "ratings"],
            sql: """
                SELECT link.book AS book, r.rating AS rating
                FROM books_ratings_link link JOIN ratings r ON r.id = link.rating
                """,
            warnings: &warnings, missingNote: "the books come in unrated"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            entry.book.rating = min(10, max(0, (row["rating"] as Int?) ?? 0))
            books[number] = entry
        }
    }

    static func attachComments(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        try eachRow(
            db, tables: ["comments"], sql: "SELECT book, text FROM comments",
            warnings: &warnings, missingNote: "the books come in without descriptions"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            guard let text = row["text"] as String?, !text.isEmpty else { return }
            entry.book.description = text
            books[number] = entry
        }
    }

    static func attachIdentifiers(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        try eachRow(
            db, tables: ["identifiers"], sql: "SELECT book, type, val FROM identifiers",
            warnings: &warnings, missingNote: "the books come in without ISBNs"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            guard let scheme = row["type"] as String?, let value = row["val"] as String?,
                !scheme.isEmpty, !value.isEmpty
            else { return }
            entry.book.identifiers[scheme.lowercased()] = value
            books[number] = entry
        }
    }

    static func attachPublishers(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        // Not in CONCEPT §7's list of tables, and read anyway: `Book` has a
        // publisher and a `dc:publisher` goes into every OPF, so leaving it
        // behind would make a "lossless" import lose a field it models.
        try eachRow(
            db, tables: ["books_publishers_link", "publishers"],
            sql: """
                SELECT link.book AS book, p.name AS name
                FROM books_publishers_link link JOIN publishers p ON p.id = link.publisher
                """,
            warnings: &warnings, missingNote: "the books come in without publishers"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            guard let name = row["name"] as String?, !name.isEmpty else { return }
            entry.book.publisher = name
            books[number] = entry
        }
    }

    static func attachLanguages(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        // The first language only: `Book.language` is one field, and Calibre's
        // `item_order` says which one the user put first.
        try eachRow(
            db, tables: ["books_languages_link", "languages"],
            sql: """
                SELECT link.book AS book, l.lang_code AS code
                FROM books_languages_link link JOIN languages l ON l.id = link.lang_code
                ORDER BY link.book, link.item_order
                """,
            warnings: &warnings, missingNote: "the books come in without a language"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            guard entry.book.language == nil else { return }
            guard let code = row["code"] as String?, !code.isEmpty else { return }
            entry.book.language = code
            books[number] = entry
        }
    }

    static func attachFiles(
        _ db: Database, to books: inout [Int: CalibreBook], warnings: inout [String]
    ) throws {
        try eachRow(
            db, tables: ["data"],
            sql: "SELECT book, format, uncompressed_size, name FROM data ORDER BY book, format",
            warnings: &warnings, missingNote: "no book files are listed at all"
        ) { row in
            guard let number: Int = row["book"], var entry = books[number] else { return }
            guard let format = row["format"] as String?, let name = row["name"] as String? else { return }
            let relative =
                entry.folder.isEmpty
                ? "\(name).\(format.lowercased())"
                : "\(entry.folder)/\(name).\(format.lowercased())"
            entry.files.append(
                CalibreFile(
                    name: name, calibreFormat: format,
                    claimedSize: (row["uncompressed_size"] as Int64?) ?? 0,
                    relativePath: relative))
            books[number] = entry
        }
    }

    // MARK: Custom columns

    static func readCustomColumns(
        _ db: Database, warnings: inout [String]
    ) throws -> ([CalibreCustomColumn], [CalibreUnknownColumn]) {
        guard try db.tableExists("custom_columns") else { return ([], []) }
        var known: [CalibreCustomColumn] = []
        var unknown: [CalibreUnknownColumn] = []
        let rows = try Row.fetchCursor(db, sql: "SELECT * FROM custom_columns ORDER BY id")
        while let row = try rows.next() {
            // A column marked for deletion is one Calibre is about to drop.
            if let marked = row["mark_for_delete"] as Int?, marked != 0 { continue }
            guard let number: Int = row["id"], let label = row["label"] as String? else { continue }
            let name = (row["name"] as String?) ?? label
            let datatype = (row["datatype"] as String?) ?? ""
            guard let kind = CalibreCustomColumn.Kind(rawValue: datatype) else {
                unknown.append(CalibreUnknownColumn(label: label, name: name, datatype: datatype))
                continue
            }
            known.append(
                CalibreCustomColumn(
                    number: number, label: label, name: name, kind: kind,
                    isMultiple: (row["is_multiple"] as Int?).map { $0 != 0 } ?? false,
                    isNormalized: (row["normalized"] as Int?).map { $0 != 0 } ?? false))
        }
        if !unknown.isEmpty {
            warnings.append(
                "\(unknown.count) custom column\(unknown.count == 1 ? "" : "s") of a kind this Shelf "
                    + "does not know: " + unknown.map { "\($0.name) (\($0.datatype))" }.joined(separator: ", ")
                    + ". Everything else is imported.")
        }
        return (known, unknown)
    }

    static func attachCustomValues(
        _ db: Database, columns: [CalibreCustomColumn], to books: inout [Int: CalibreBook],
        warnings: inout [String]
    ) throws {
        for column in columns {
            // A composite column is computed by Calibre from a template; there
            // is no stored value anywhere to read.
            guard column.kind != .composite else { continue }
            let table = "custom_column_\(column.number)"
            let link = "books_custom_column_\(column.number)_link"
            // Two shapes, and which one a column has is Calibre's decision, not
            // the datatype's: a *normalized* column keeps its values in their
            // own table with a link table beside it (that is how one value is
            // shared by many books), and a plain one keeps the value in the row.
            let sql: String
            if column.isNormalized {
                guard try db.tableExists(table), try db.tableExists(link) else {
                    warnings.append("The custom column “\(column.name)” has no table – it is skipped.")
                    continue
                }
                sql = """
                    SELECT link.book AS book, c.value AS value
                    FROM \(link) link JOIN \(table) c ON c.id = link.value
                    ORDER BY link.book, link.id
                    """
            } else {
                guard try db.tableExists(table) else {
                    warnings.append("The custom column “\(column.name)” has no table – it is skipped.")
                    continue
                }
                sql = "SELECT book, value FROM \(table) ORDER BY book"
            }
            let rows = try Row.fetchCursor(db, sql: sql)
            while let row = try rows.next() {
                guard let number: Int = row["book"], var entry = books[number] else { continue }
                guard let text = text(of: row["value"], kind: column.kind) else { continue }
                // A column that holds several values per book joins them, in
                // the order Calibre kept them.
                if let existing = entry.customValues[column.label], column.isMultiple {
                    entry.customValues[column.label] = existing + ", " + text
                } else {
                    entry.customValues[column.label] = text
                }
                books[number] = entry
            }
        }
    }

    /// One custom value as the inspector will show it.
    ///
    /// Read-only in v1.0, so this is a one-way rendering and not a type: what
    /// matters is that a date reads as a date and a yes/no reads as yes or no,
    /// rather than as `1`.
    static func text(of value: DatabaseValue?, kind: CalibreCustomColumn.Kind) -> String? {
        guard let value, !value.isNull else { return nil }
        switch kind {
        case .bool:
            guard let number = whole(value) else { return nil }
            return number != 0 ? "Yes" : "No"
        case .datetime:
            guard let text = String.fromDatabaseValue(value) else { return nil }
            guard let date = OPFDate.parse(text) else { return nil }
            return OPFDate.render(date)
        case .int, .rating:
            guard let number = whole(value) else { return nil }
            return String(number)
        case .float:
            guard let number = fractional(value) else { return nil }
            // Trimmed, so 2.0 is "2" and 2.5 stays "2.5" – the same reading
            // `BookField` gives a series index.
            return number == number.rounded() ? String(Int(number)) : String(number)
        case .text, .comments, .series, .enumeration:
            guard let text = String.fromDatabaseValue(value), !text.isEmpty else { return nil }
            return text
        case .composite:
            return nil
        }
    }

    /// A whole number, however the column happens to store it.
    ///
    /// GRDB reads strictly and is right to: a `String` is not an `Int`. But a
    /// custom column's *declared* type is Calibre's choice and SQLite's
    /// affinity rules do the rest, so a library where somebody changed a
    /// column's kind can hold `101` as the text "101". Refusing that would
    /// drop a value that is plainly there, for a library Shelf only ever reads.
    static func whole(_ value: DatabaseValue) -> Int? {
        if let number = Int.fromDatabaseValue(value) { return number }
        if let text = String.fromDatabaseValue(value) { return Int(text) ?? Double(text).map(Int.init) }
        return nil
    }

    static func fractional(_ value: DatabaseValue) -> Double? {
        if let number = Double.fromDatabaseValue(value) { return number }
        if let text = String.fromDatabaseValue(value) { return Double(text) }
        return nil
    }
}
