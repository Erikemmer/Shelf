import Foundation
import GRDB

/// One book as the index holds it: the metadata, where it lives, and its files.
public struct LibraryEntry: Identifiable, Equatable, Sendable {
    public var book: Book
    /// The running number in the folder name, `Pride and Prejudice (17)`.
    public var number: Int
    /// The book's folder relative to the library root.
    public var folder: String
    public var formats: [BookFormat]

    public var id: UUID { book.id }

    public init(book: Book, number: Int, folder: String, formats: [BookFormat] = []) {
        self.book = book
        self.number = number
        self.folder = folder
        self.formats = formats
    }

    /// The format shown in the inspector and sent to a device first.
    public var preferredFormat: BookFormat? {
        formats.min { $0.format < $1.format }
    }

    /// "EPUB · AZW3" for the grid badge and the table column.
    public var formatLine: String {
        formats.map(\.format.label).sorted().joined(separator: " · ")
    }

    public var totalBytes: Int64 {
        formats.reduce(0) { $0 + $1.byteSize }
    }

    /// DRM on any of the files – what the badge in the grid reads.
    public var drm: DRMKind? {
        formats.compactMap(\.drm).first
    }
}

/// The SQLite index over a library folder.
///
/// It is a *cache*: everything in it except the shelves can be rebuilt from the
/// folders by `IndexRebuilder`, which is what lets it be opened in WAL mode,
/// erased after a crash and rebuilt without asking anyone
/// (`docs/adr/0001-folder-is-the-truth.md`). What it buys is the two things a
/// folder tree cannot do: answering "all science fiction, unread, by series"
/// without reading 8 000 files, and full-text search.
public final class LibraryIndex: Sendable {
    /// A pool on disk, or a queue in memory for tests. The protocol rather than
    /// the concrete type because GRDB's in-memory database is only available as
    /// a `DatabaseQueue`: `DatabasePool` needs a file, and a pool asked for
    /// `":memory:something"` quietly creates a *file* with that name in the
    /// working directory – which is what the first version of this did, leaving
    /// sixty stray databases in the repository and making the tests share state
    /// between runs.
    private let pool: any DatabaseWriter
    public let url: URL

    public enum Failure: Error, Equatable {
        /// The library's name and what SQLite or the migrator actually said.
        /// The reason is carried, not swallowed: "cannot open the index" alone
        /// tells whoever reads it nothing they can act on.
        case cannotOpen(String, reason: String)
    }

    /// Opens – or creates – the index of a library.
    public init(library: Library) throws {
        url = library.indexURL
        do {
            try FileManager.default.createDirectory(at: library.privateFolder, withIntermediateDirectories: true)
            var configuration = Configuration()
            // WAL is the default for a pool, and it is what makes a crash cost
            // nothing here: readers never block the writer, and a torn write
            // rolls back. The index being rebuildable is the second net.
            configuration.foreignKeysEnabled = true
            let onDisk = try DatabasePool(path: library.indexURL.path, configuration: configuration)
            try IndexSchema.migrator.migrate(onDisk)
            pool = onDisk
        } catch {
            throw Failure.cannotOpen(library.name, reason: "\(error)")
        }
    }

    /// An index in memory, for tests and for a dry run that must not write.
    ///
    /// `name` only distinguishes one in-memory database from another; nothing
    /// is written to disk, so two tests with the same name would share rows.
    public init(inMemory name: String = UUID().uuidString) throws {
        url = URL(fileURLWithPath: "/dev/null")
        do {
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            let queue = try DatabaseQueue(named: name, configuration: configuration)
            try IndexSchema.migrator.migrate(queue)
            pool = queue
        } catch {
            throw Failure.cannotOpen(name, reason: "\(error)")
        }
    }

    // MARK: Writing

    /// Writes one book and everything attached to it.
    ///
    /// An upsert, because the same call has to serve an import, an edit and a
    /// rebuild. The relations are replaced rather than merged: a book whose
    /// second author was removed must not keep them.
    public func save(_ entry: LibraryEntry) async throws {
        try await pool.write { database in
            try Self.write(entry, in: database)
        }
    }

    /// Writes many books in one transaction.
    ///
    /// The reason this exists next to `save`: importing 5 000 books one
    /// transaction at a time means 5 000 fsyncs, which is minutes of waiting
    /// for nothing. One transaction per batch is what makes an import
    /// I/O-bound on the books rather than on the index.
    public func save(_ entries: [LibraryEntry]) async throws {
        guard !entries.isEmpty else { return }
        try await pool.write { database in
            for entry in entries {
                try Self.write(entry, in: database)
            }
        }
    }

    private static func write(_ entry: LibraryEntry, in database: Database) throws {
        let book = entry.book
        let id = book.id.uuidString

        let seriesID = try book.series.map { try upsertSeries($0.name, in: database) }
        try database.execute(
            sql: """
                INSERT INTO books
                    (id, number, folder, title, title_sort, series_id, series_index, rating, is_read,
                     publisher, published, language, description, added_at, modified_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    number = excluded.number, folder = excluded.folder, title = excluded.title,
                    title_sort = excluded.title_sort, series_id = excluded.series_id,
                    series_index = excluded.series_index, rating = excluded.rating,
                    is_read = excluded.is_read, publisher = excluded.publisher,
                    published = excluded.published, language = excluded.language,
                    description = excluded.description, added_at = excluded.added_at,
                    modified_at = excluded.modified_at, last_seen_at = excluded.last_seen_at
                """,
            arguments: [
                id, entry.number, entry.folder, book.title, book.titleSort, seriesID, book.series?.index,
                book.rating, book.isRead, book.publisher, book.published, book.language, book.description,
                book.addedAt, book.modifiedAt, Date(),
            ])

        // MARK: Relations, replaced wholesale

        try database.execute(sql: "DELETE FROM book_authors WHERE book_id = ?", arguments: [id])
        for (position, name) in book.authors.enumerated() {
            let authorID = try upsertAuthor(name, in: database)
            try database.execute(
                sql: "INSERT OR REPLACE INTO book_authors (book_id, author_id, position) VALUES (?, ?, ?)",
                arguments: [id, authorID, position])
        }

        try database.execute(sql: "DELETE FROM book_tags WHERE book_id = ?", arguments: [id])
        for name in book.tags {
            let tagID = try upsertTag(name, in: database)
            try database.execute(
                sql: "INSERT OR REPLACE INTO book_tags (book_id, tag_id) VALUES (?, ?)",
                arguments: [id, tagID])
        }

        try database.execute(sql: "DELETE FROM identifiers WHERE book_id = ?", arguments: [id])
        for (scheme, value) in book.identifiers {
            try database.execute(
                sql: "INSERT OR REPLACE INTO identifiers (book_id, scheme, value) VALUES (?, ?, ?)",
                arguments: [id, scheme.lowercased(), value])
        }
        // The normalised ISBN gets its own row, because that is what the
        // duplicate check compares – two spellings of one ISBN are one book.
        if let isbn = book.isbn {
            try database.execute(
                sql: "INSERT OR REPLACE INTO identifiers (book_id, scheme, value) VALUES (?, 'isbn_normalised', ?)",
                arguments: [id, isbn])
        }

        try database.execute(sql: "DELETE FROM formats WHERE book_id = ?", arguments: [id])
        for format in entry.formats {
            try database.execute(
                sql: """
                    INSERT INTO formats (book_id, format, file_name, byte_size, sha256, modified_at, drm)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    id, format.format.rawValue, format.fileName, format.byteSize, format.sha256,
                    format.modifiedAt, format.drm?.rawValue,
                ])
        }

        // The shelves come out of the book, like everything else: the book's
        // `metadata.opf` is where membership lives (ADR 0008), so this table is
        // a cache of it and is replaced wholesale.
        //
        // A path this index does not know is *skipped, not invented*. The tree
        // belongs to `library.json` and is written before the books are, so a
        // path with no shelf behind it means the caller has not saved the tree
        // — and a shelf conjured up here would be one `library.json` never
        // hears about, which is how two authorities start disagreeing.
        try database.execute(sql: "DELETE FROM book_shelves WHERE book_id = ?", arguments: [id])
        for (position, path) in book.shelves.enumerated() {
            guard let shelfID = try shelfID(atPath: path, in: database) else { continue }
            try database.execute(
                sql: "INSERT OR REPLACE INTO book_shelves (book_id, shelf_id, position) VALUES (?, ?, ?)",
                arguments: [id, shelfID, position])
        }

        try writeSearchRow(entry, in: database)
    }

    /// `Fiction/Sci-Fi` → the id of the shelf at the end of it, walking the
    /// `shelves` table one level at a time.
    ///
    /// `NOCASE` so that a book filed under `fiction/sci-fi` by an OPF somebody
    /// edited by hand still lands on `Fiction/Sci-Fi` – the same leniency
    /// `ShelfTree.shelf(atPath:)` has, which is what keeps the index and the
    /// tree answering the same question the same way.
    private static func shelfID(atPath path: String, in database: Database) throws -> String? {
        let names = path.components(separatedBy: ShelfTree.pathSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        var parent: String?
        for name in names {
            let found: String? =
                try String.fetchOne(
                    database,
                    sql: parent == nil
                        ? "SELECT id FROM shelves WHERE parent_id IS NULL AND name = ? COLLATE NOCASE"
                        : "SELECT id FROM shelves WHERE parent_id = ? AND name = ? COLLATE NOCASE",
                    arguments: parent == nil ? [name] : [parent, name])
            guard let found else { return nil }
            parent = found
        }
        return parent
    }

    /// The book's row in the search table.
    ///
    /// Deleted and reinserted rather than updated: FTS5 has no useful UPDATE,
    /// and a stale search row is the kind of bug that only shows up as "I
    /// renamed it and search still finds the old name".
    private static func writeSearchRow(_ entry: LibraryEntry, in database: Database) throws {
        let id = entry.book.id.uuidString
        try database.execute(sql: "DELETE FROM search WHERE book_id = ?", arguments: [id])
        try database.execute(
            sql: """
                INSERT INTO search (title, authors, series, tags, description, isbn, book_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                entry.book.title,
                entry.book.authors.joined(separator: " "),
                entry.book.series?.name ?? "",
                entry.book.tags.joined(separator: " "),
                entry.book.description ?? "",
                Self.searchableISBNs(of: entry.book),
                id,
            ])
    }

    /// The ISBN as the file spells it *and* normalised, so a search finds the
    /// book whichever way it is typed: `978-0-306-40615-7` tokenises into five
    /// short numbers, `9780306406157` into one, and neither prefix-matches the
    /// other.
    private static func searchableISBNs(of book: Book) -> String {
        var spellings: [String] = []
        if let raw = book.identifiers["isbn"], !raw.isEmpty { spellings.append(raw) }
        if let normalised = book.isbn, !spellings.contains(normalised) { spellings.append(normalised) }
        return spellings.joined(separator: " ")
    }

    // MARK: Lookup tables
    //
    // One row per name, so renaming an author renames them everywhere and the
    // sidebar's counts are a `GROUP BY` rather than a scan of every book.

    private static func upsertAuthor(_ name: String, in database: Database) throws -> String {
        if let id = try String.fetchOne(database, sql: "SELECT id FROM authors WHERE name = ?", arguments: [name]) {
            return id
        }
        let id = UUID().uuidString
        try database.execute(
            sql: "INSERT INTO authors (id, name, name_sort) VALUES (?, ?, ?)",
            arguments: [id, name, AuthorSort.of(name)])
        return id
    }

    private static func upsertSeries(_ name: String, in database: Database) throws -> String {
        if let id = try String.fetchOne(database, sql: "SELECT id FROM series WHERE name = ?", arguments: [name]) {
            return id
        }
        let id = UUID().uuidString
        try database.execute(
            sql: "INSERT INTO series (id, name, name_sort) VALUES (?, ?, ?)",
            arguments: [id, name, TitleSort.of(name)])
        return id
    }

    private static func upsertTag(_ name: String, in database: Database) throws -> String {
        if let id = try String.fetchOne(database, sql: "SELECT id FROM tags WHERE name = ?", arguments: [name]) {
            return id
        }
        let id = UUID().uuidString
        try database.execute(sql: "INSERT INTO tags (id, name) VALUES (?, ?)", arguments: [id, name])
        return id
    }

    // MARK: Reading

    public func count() async throws -> Int {
        try await pool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM books") ?? 0
        }
    }

    /// Every book, with its authors, series, tags and files.
    ///
    /// One query per table and then a join in memory, rather than one query
    /// with five `LEFT JOIN`s: the joined version returns a row per
    /// author × tag × format and 8 000 books become 200 000 rows to de-duplicate.
    /// Four small queries are both faster and easier to read.
    public func allEntries(sortedBy sort: BookSort = .titleSort) async throws -> [LibraryEntry] {
        try await pool.read { database in
            try Self.entries(matching: nil, sortedBy: sort, in: database)
        }
    }

    public func entry(id: UUID) async throws -> LibraryEntry? {
        try await pool.read { database in
            try Self.entries(matching: [id], sortedBy: .titleSort, in: database).first
        }
    }

    public func entries(ids: [UUID], sortedBy sort: BookSort = .titleSort) async throws -> [LibraryEntry] {
        guard !ids.isEmpty else { return [] }
        return try await pool.read { database in
            try Self.entries(matching: ids, sortedBy: sort, in: database)
        }
    }

    private static func entries(
        matching ids: [UUID]?, sortedBy sort: BookSort, in database: Database
    ) throws -> [LibraryEntry] {
        var sql = """
            SELECT b.id, b.number, b.folder, b.title, b.title_sort, s.name AS series_name, b.series_index,
                   b.rating, b.is_read, b.publisher, b.published, b.language, b.description,
                   b.added_at, b.modified_at
            FROM books b
            LEFT JOIN series s ON s.id = b.series_id
            """
        var arguments = StatementArguments()
        if let ids {
            let placeholders = databaseQuestionMarks(count: ids.count)
            sql += " WHERE b.id IN (\(placeholders))"
            arguments += StatementArguments(ids.map(\.uuidString))
        }
        sql += " ORDER BY \(sort.sqlOrder)"

        let rows = try Row.fetchAll(database, sql: sql, arguments: arguments)
        guard !rows.isEmpty else { return [] }

        let bookIDs = rows.map { $0["id"] as String }
        let authors = try authorNames(for: bookIDs, in: database)
        let tags = try tagNames(for: bookIDs, in: database)
        let shelves = try shelfPaths(for: bookIDs, in: database)
        let formats = try formatRows(for: bookIDs, in: database)
        let identifiers = try identifierRows(for: bookIDs, in: database)

        return rows.map { row in
            let id: String = row["id"]
            let uuid = UUID(uuidString: id) ?? UUID()
            let seriesName: String? = row["series_name"]
            let book = Book(
                id: uuid,
                title: row["title"],
                titleSort: row["title_sort"],
                authors: authors[id] ?? [],
                series: seriesName.map { SeriesRef(name: $0, index: row["series_index"]) },
                rating: row["rating"],
                isRead: row["is_read"],
                publisher: row["publisher"],
                published: row["published"],
                language: row["language"],
                description: row["description"],
                tags: tags[id] ?? [],
                shelves: shelves[id] ?? [],
                identifiers: identifiers[id] ?? [:],
                addedAt: row["added_at"],
                modifiedAt: row["modified_at"])
            return LibraryEntry(
                book: book, number: row["number"], folder: row["folder"], formats: formats[id] ?? [])
        }
    }

    private static func authorNames(for bookIDs: [String], in database: Database) throws -> [String: [String]] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT ba.book_id, a.name FROM book_authors ba
                JOIN authors a ON a.id = ba.author_id
                WHERE ba.book_id IN (\(databaseQuestionMarks(count: bookIDs.count)))
                ORDER BY ba.position
                """,
            arguments: StatementArguments(bookIDs))
        return Dictionary(grouping: rows) { $0["book_id"] as String }
            .mapValues { $0.map { $0["name"] as String } }
    }

    private static func tagNames(for bookIDs: [String], in database: Database) throws -> [String: [String]] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT bt.book_id, t.name FROM book_tags bt
                JOIN tags t ON t.id = bt.tag_id
                WHERE bt.book_id IN (\(databaseQuestionMarks(count: bookIDs.count)))
                ORDER BY t.name
                """,
            arguments: StatementArguments(bookIDs))
        return Dictionary(grouping: rows) { $0["book_id"] as String }
            .mapValues { $0.map { $0["name"] as String } }
    }

    /// The stored path of every shelf each book stands on.
    ///
    /// Built back up from the tree in one query rather than one per level: a
    /// recursive CTE walks from each shelf to the root and glues the names
    /// together, so 5 000 books on 20 shelves cost one statement, not 5 000.
    ///
    /// It has to come back at all, and that is not a detail. `Book.shelves` is
    /// what the grid filters on and what "Not on any Shelf" is answered from —
    /// an index that returned books with no shelves would quietly file the
    /// whole library under "not on any shelf" while every `metadata.opf` said
    /// otherwise.
    private static func shelfPaths(for bookIDs: [String], in database: Database) throws -> [String: [String]] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                WITH RECURSIVE ancestry(id, path) AS (
                    SELECT id, name FROM shelves WHERE parent_id IS NULL
                    UNION ALL
                    SELECT s.id, ancestry.path || '\(ShelfTree.pathSeparator)' || s.name
                    FROM shelves s JOIN ancestry ON s.parent_id = ancestry.id
                )
                SELECT bs.book_id, ancestry.path AS path FROM book_shelves bs
                JOIN ancestry ON ancestry.id = bs.shelf_id
                WHERE bs.book_id IN (\(databaseQuestionMarks(count: bookIDs.count)))
                ORDER BY ancestry.path
                """,
            arguments: StatementArguments(bookIDs))
        return Dictionary(grouping: rows) { $0["book_id"] as String }
            .mapValues { $0.map { $0["path"] as String } }
    }

    /// The identifiers of each book: ISBN, ASIN, Goodreads…
    ///
    /// Left out until Sprint 2, which cost twice. The inspector has a row per
    /// identifier and never drew one, because the dictionary it read was always
    /// empty; and re-saving an entry that came from the index deleted the
    /// identifier rows and wrote none back, which would have taken the ISBN off
    /// every edited book and with it the duplicate check.
    ///
    /// `isbn_normalised` is skipped: it is the duplicate check's own derived
    /// row, not something a book claims about itself, and letting it back into
    /// the model would write `<dc:identifier opf:scheme="ISBN_NORMALISED">` into
    /// every OPF.
    private static func identifierRows(
        for bookIDs: [String], in database: Database
    ) throws -> [String: [String: String]] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT book_id, scheme, value FROM identifiers
                WHERE book_id IN (\(databaseQuestionMarks(count: bookIDs.count)))
                  AND scheme <> 'isbn_normalised'
                """,
            arguments: StatementArguments(bookIDs))
        return Dictionary(grouping: rows) { $0["book_id"] as String }
            .mapValues { group in
                Dictionary(group.map { ($0["scheme"] as String, $0["value"] as String) }) { _, last in last }
            }
    }

    private static func formatRows(for bookIDs: [String], in database: Database) throws -> [String: [BookFormat]] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT book_id, format, file_name, byte_size, sha256, modified_at, drm FROM formats
                WHERE book_id IN (\(databaseQuestionMarks(count: bookIDs.count)))
                ORDER BY file_name
                """,
            arguments: StatementArguments(bookIDs))
        return Dictionary(grouping: rows) { $0["book_id"] as String }
            .mapValues { group in
                group.compactMap { row -> BookFormat? in
                    let raw: String = row["format"]
                    guard let format = BookFileFormat(rawValue: raw),
                        let bookID = UUID(uuidString: row["book_id"] as String)
                    else { return nil }
                    return BookFormat(
                        bookID: bookID, format: format, fileName: row["file_name"],
                        byteSize: row["byte_size"], sha256: row["sha256"],
                        modifiedAt: row["modified_at"],
                        drm: (row["drm"] as String?).flatMap(DRMKind.init(rawValue:)))
                }
            }
    }

    // MARK: Search

    /// Full-text search over title, authors, series, tags, description and
    /// ISBN – the six CONCEPT §4 lists under "Must".
    ///
    /// The user's words are turned into a prefix query – "tolk" finds Tolkien –
    /// and quoted, so a search for `AND` or a stray `"` is looked for rather
    /// than parsed as FTS5 syntax and rejected.
    public func search(_ query: String) async throws -> [UUID] {
        let pattern = Self.ftsPattern(for: query)
        guard !pattern.isEmpty else { return [] }
        return try await pool.read { database in
            let ids = try String.fetchAll(
                database,
                sql: "SELECT book_id FROM search WHERE search MATCH ? ORDER BY rank",
                arguments: [pattern])
            return ids.compactMap(UUID.init(uuidString:))
        }
    }

    /// Turns what the user typed into an FTS5 query.
    ///
    /// Every word becomes a quoted prefix term and the terms are ANDed, which
    /// is what people expect from a search box: more words, fewer results.
    static func ftsPattern(for query: String) -> String {
        let words =
            query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: Facets for the sidebar

    /// A name and how many books carry it.
    public struct Facet: Equatable, Sendable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name }

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public func tagFacets() async throws -> [Facet] {
        try await facets(
            sql: """
                SELECT t.name AS name, COUNT(*) AS count FROM book_tags bt
                JOIN tags t ON t.id = bt.tag_id
                GROUP BY t.id ORDER BY t.name COLLATE NOCASE
                """)
    }

    public func authorFacets() async throws -> [Facet] {
        try await facets(
            sql: """
                SELECT a.name AS name, COUNT(*) AS count FROM book_authors ba
                JOIN authors a ON a.id = ba.author_id
                GROUP BY a.id ORDER BY a.name_sort COLLATE NOCASE
                """)
    }

    public func seriesFacets() async throws -> [Facet] {
        try await facets(
            sql: """
                SELECT s.name AS name, COUNT(*) AS count FROM books b
                JOIN series s ON s.id = b.series_id
                GROUP BY s.id ORDER BY s.name_sort COLLATE NOCASE
                """)
    }

    public func formatFacets() async throws -> [Facet] {
        try await facets(
            sql: """
                SELECT format AS name, COUNT(DISTINCT book_id) AS count FROM formats
                GROUP BY format ORDER BY format
                """)
    }

    private func facets(sql: String) async throws -> [Facet] {
        try await pool.read { database in
            try Row.fetchAll(database, sql: sql).map {
                Facet(name: $0["name"], count: $0["count"])
            }
        }
    }

    /// The counts the smart collections show.
    public struct Totals: Equatable, Sendable {
        public var all = 0
        public var unread = 0
        /// Added in the last thirty days.
        public var recentlyAdded = 0
        public var missingCover = 0
        public var notOnAnyShelf = 0
        public var duplicates = 0

        public init() {}
    }

    public func totals(recentDays: Int = 30, coversOnDisk: Set<UUID> = []) async throws -> Totals {
        try await pool.read { database in
            var totals = Totals()
            totals.all = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM books") ?? 0
            totals.unread = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM books WHERE is_read = 0") ?? 0
            let cutoff = Date().addingTimeInterval(-Double(recentDays) * 86_400)
            totals.recentlyAdded =
                try Int.fetchOne(
                    database, sql: "SELECT COUNT(*) FROM books WHERE added_at >= ?", arguments: [cutoff]) ?? 0
            totals.notOnAnyShelf =
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM books WHERE id NOT IN (SELECT book_id FROM book_shelves)") ?? 0
            // Counted against the caller's list rather than a column: whether a
            // cover file is there is a fact about the disk, and a column would
            // be a second copy of it that can go stale.
            totals.missingCover = max(0, totals.all - coversOnDisk.count)
            return totals
        }
    }

    /// Every book that looks like a copy of another, and why.
    ///
    /// The three rules are the importer's own (`ImportPlanner`), asked of the
    /// whole library instead of of one incoming file. That they are the same
    /// three is the point: a book the importer would have called a duplicate on
    /// the way in is a book this collection shows once it is in, and two
    /// different answers to "is this the same book" would be a defect nobody
    /// could see.
    ///
    /// **Why the books say which rule found them.** Same bytes is a fact; same
    /// ISBN is nearly one; same title and author is a guess — two editions, a
    /// translation, an abridgement. Shown together with no distinction, the
    /// honest matches and the guesses would be one undifferentiated list, and
    /// the guesses are the ones somebody might act on by deleting a book.
    public func duplicates() async throws -> [UUID: Set<DuplicateReason>] {
        // The two SQL rules first, as lists of groups, because a closure that
        // writes into a dictionary cannot be captured by the `@Sendable` read.
        let groups: [(ids: [UUID], reason: DuplicateReason)] = try await pool.read { database in
            // Same bytes. `DISTINCT` because one book may hold the same file
            // twice under two names, and a book is not a copy of itself.
            let byContent = try Row.fetchAll(
                database,
                sql: """
                    SELECT sha256, GROUP_CONCAT(DISTINCT book_id) AS ids FROM formats
                    GROUP BY sha256 HAVING COUNT(DISTINCT book_id) > 1
                    """)
            let byISBN = try Row.fetchAll(
                database,
                sql: """
                    SELECT value, GROUP_CONCAT(DISTINCT book_id) AS ids FROM identifiers
                    WHERE scheme = 'isbn_normalised'
                    GROUP BY value HAVING COUNT(DISTINCT book_id) > 1
                    """)
            return byContent.map { (Self.uuids($0["ids"]), DuplicateReason.content) }
                + byISBN.map { (Self.uuids($0["ids"]), DuplicateReason.isbn) }
        }

        // Title and author is folded in Swift, not in SQL: the folding drops
        // accents, punctuation and runs of space, and `DuplicateKey` is where
        // that rule lives. A second spelling of it in a `WHERE` clause is a
        // second rule.
        let byTitle = try await allTitleKeys().values.map { ($0, DuplicateReason.titleAuthor) }

        var found: [UUID: Set<DuplicateReason>] = [:]
        for group in groups + byTitle where group.0.count > 1 {
            for id in group.0 { found[id, default: []].insert(group.1) }
        }
        return found
    }

    /// `GROUP_CONCAT` gives a comma-separated list; UUID strings never contain
    /// a comma, so splitting on one is safe here and nowhere else.
    private static func uuids(_ list: String) -> [UUID] {
        list.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    // MARK: Duplicate detection

    /// Books that already carry this ISBN.
    public func bookIDs(isbn: String) async throws -> [UUID] {
        try await pool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT book_id FROM identifiers WHERE scheme = 'isbn_normalised' AND value = ?",
                arguments: [isbn]
            ).compactMap(UUID.init(uuidString:))
        }
    }

    /// The book a file already belongs to, found by its content.
    ///
    /// The strongest of the three duplicate tests: two files with the same
    /// SHA-256 are the same bytes, whatever they are called.
    public func bookID(sha256: String) async throws -> UUID? {
        try await pool.read { database in
            try String.fetchOne(
                database, sql: "SELECT book_id FROM formats WHERE sha256 = ? LIMIT 1", arguments: [sha256]
            ).flatMap(UUID.init(uuidString:))
        }
    }

    /// Books with this title and this first author, compared the way a person
    /// would: case-folded and stripped of punctuation.
    public func bookIDs(titleKey: String) async throws -> [UUID] {
        try await pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT b.id AS id, b.title AS title, a.name AS author
                    FROM books b
                    LEFT JOIN book_authors ba ON ba.book_id = b.id AND ba.position = 0
                    LEFT JOIN authors a ON a.id = ba.author_id
                    """)
            return
                rows
                .filter { DuplicateKey.titleAuthor(title: $0["title"], author: $0["author"]) == titleKey }
                .compactMap { UUID(uuidString: $0["id"] as String) }
        }
    }

    /// Every SHA-256 the index knows, for an import that is about to hash a
    /// folder full of files: one query beats one per file.
    public func allFormatDigests() async throws -> [String: UUID] {
        try await pool.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT sha256, book_id FROM formats")
            return Dictionary(
                rows.compactMap { row -> (String, UUID)? in
                    guard let id = UUID(uuidString: row["book_id"] as String) else { return nil }
                    return (row["sha256"] as String, id)
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// Every normalised ISBN the index knows, for the same reason.
    public func allISBNs() async throws -> [String: UUID] {
        try await pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT value, book_id FROM identifiers WHERE scheme = 'isbn_normalised'")
            return Dictionary(
                rows.compactMap { row -> (String, UUID)? in
                    guard let id = UUID(uuidString: row["book_id"] as String) else { return nil }
                    return (row["value"] as String, id)
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    /// Every title+author key the index knows, and the books behind it.
    public func allTitleKeys() async throws -> [String: [UUID]] {
        try await pool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT b.id AS id, b.title AS title, a.name AS author
                    FROM books b
                    LEFT JOIN book_authors ba ON ba.book_id = b.id AND ba.position = 0
                    LEFT JOIN authors a ON a.id = ba.author_id
                    """)
            var result: [String: [UUID]] = [:]
            for row in rows {
                guard let id = UUID(uuidString: row["id"] as String) else { continue }
                let key = DuplicateKey.titleAuthor(title: row["title"], author: row["author"])
                result[key, default: []].append(id)
            }
            return result
        }
    }

    // MARK: Shelves

    /// Writes the whole tree, and removes whatever is no longer in it.
    ///
    /// *The whole* tree, because `library.json` is the authority for the shape
    /// of the shelves (ADR 0008) and this table is a cache of it. An upsert
    /// that only added would leave a deleted shelf standing in the sidebar with
    /// its books still on it — the index quietly disagreeing with the file,
    /// which is the one thing a cache must never do.
    public func saveShelves(_ shelves: [Shelf]) async throws {
        try await pool.write { database in
            let wanted = shelves.map(\.id.uuidString)
            // `ON DELETE CASCADE` on `parent_id` takes the children with it, and
            // on `book_shelves` it takes the memberships – which is right: a
            // shelf that is gone holds no books. What the books' own OPFs say is
            // untouched; the caller rewrites those, or does not.
            try database.execute(
                sql: "DELETE FROM shelves WHERE id NOT IN (\(databaseQuestionMarks(count: wanted.count)))",
                arguments: StatementArguments(wanted.isEmpty ? [""] : wanted))
            // Children first would violate the foreign key; parents first is
            // the order a tree has to be written in.
            let ordered = shelves.sorted { ($0.parentID == nil ? 0 : 1) < ($1.parentID == nil ? 0 : 1) }
            for shelf in ordered {
                try database.execute(
                    sql: """
                        INSERT INTO shelves (id, name, parent_id, position) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            name = excluded.name, parent_id = excluded.parent_id, position = excluded.position
                        """,
                    arguments: [
                        shelf.id.uuidString, shelf.name, shelf.parentID?.uuidString, shelf.position,
                    ])
            }
        }
    }

    /// Every shelf id the index holds – what a test asks to see that a removed
    /// shelf is really gone.
    public func shelfIDs() async throws -> Set<UUID> {
        try await pool.read { database in
            Set(try String.fetchAll(database, sql: "SELECT id FROM shelves").compactMap(UUID.init(uuidString:)))
        }
    }

    public func shelfFacets() async throws -> [UUID: Int] {
        try await pool.read { database in
            let rows = try Row.fetchAll(
                database, sql: "SELECT shelf_id, COUNT(*) AS count FROM book_shelves GROUP BY shelf_id")
            return Dictionary(
                rows.compactMap { row -> (UUID, Int)? in
                    guard let id = UUID(uuidString: row["shelf_id"] as String) else { return nil }
                    return (id, row["count"] as Int)
                },
                uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: Rebuilding

    /// Empties every table. Used by `IndexRebuilder` before it walks the
    /// folders – a rebuild that merged into what was there could not remove a
    /// book somebody deleted in the Finder.
    ///
    /// Shelves are kept by the rebuilder, which reads them back out of
    /// `library.json` and the OPFs; this call does not decide that.
    public func eraseAll() async throws {
        try await pool.write { database in
            for table in [
                "book_shelves", "book_tags", "book_authors", "identifiers", "formats",
                "custom_values", "device_books", "search", "books", "authors", "series", "tags", "shelves",
            ] {
                try database.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    /// Reclaims the space a rebuild left behind. Worth doing once after an
    /// import of thousands of books, never on every launch.
    public func vacuum() async throws {
        try await pool.writeWithoutTransaction { database in
            try database.execute(sql: "VACUUM")
        }
    }
}

/// How the grid and the table are sorted.
///
/// A table rather than a `switch` in the view, so the sidebar, the table header
/// and a saved sort order cannot disagree about what "by author" means.
public enum BookSort: String, CaseIterable, Sendable {
    case titleSort
    case authorSort
    case seriesOrder
    case addedNewest
    case ratingHighest

    public var title: String {
        switch self {
        case .titleSort: return "Title"
        case .authorSort: return "Author"
        case .seriesOrder: return "Series"
        case .addedNewest: return "Recently Added"
        case .ratingHighest: return "Rating"
        }
    }

    /// `COLLATE NOCASE` everywhere a person's eye reads the column: a library
    /// that puts "Zola" before "adams" is a library nobody can scan.
    var sqlOrder: String {
        switch self {
        case .titleSort:
            return "b.title_sort COLLATE NOCASE"
        case .authorSort:
            return """
                (SELECT a.name_sort FROM book_authors ba JOIN authors a ON a.id = ba.author_id
                 WHERE ba.book_id = b.id ORDER BY ba.position LIMIT 1) COLLATE NOCASE,
                b.title_sort COLLATE NOCASE
                """
        case .seriesOrder:
            // Books without a series go last, not first: a NULL sorts before
            // everything in SQLite, which would bury every series behind them.
            return "s.name_sort IS NULL, s.name_sort COLLATE NOCASE, b.series_index, b.title_sort COLLATE NOCASE"
        case .addedNewest:
            return "b.added_at DESC, b.title_sort COLLATE NOCASE"
        case .ratingHighest:
            return "b.rating DESC, b.title_sort COLLATE NOCASE"
        }
    }
}

/// How two books are compared for "these are the same book".
public enum DuplicateKey {
    /// Title and first author, folded so that spelling differences that do not
    /// change the book do not make it a different one: case, accents,
    /// punctuation and runs of space all go.
    public static func titleAuthor(title: String, author: String?) -> String {
        "\(fold(title))|\(fold(author ?? Book.unknownAuthor))"
    }

    public static func titleAuthor(for book: Book) -> String {
        titleAuthor(title: book.title, author: book.authors.first)
    }

    static func fold(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        let letters = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }
}

/// `?, ?, ?` for an `IN` clause.
///
/// Built rather than interpolating the values, so a title with a quote in it
/// cannot become SQL. Every query in this file binds its values.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: max(count, 1)).joined(separator: ", ")
}
