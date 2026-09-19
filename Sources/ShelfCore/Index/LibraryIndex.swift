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
    /// What protects this book, for the one badge the grid has room for.
    ///
    /// When the files disagree — and they do: a protected book bought twice is
    /// an EPUB with Adobe DRM and an AZW3 with Kindle's — the answer is the
    /// generic `.unknown`, which draws as "DRM". Picking whichever file came
    /// first out of SQLite would put "Kindle DRM" on a book whose EPUB is
    /// Adobe's, which is a smaller lie than most and still a lie. The
    /// inspector lists every file with its own badge, which is where the whole
    /// truth belongs.
    public var drm: DRMKind? {
        let kinds = Set(formats.compactMap(\.drm))
        guard kinds.count <= 1 else { return .unknown }
        return kinds.first
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

    /// `entry.number`, or the next free one when another book already has it.
    ///
    /// **A rebuild must never fail on a library somebody actually has.** The
    /// index is a cache exactly because it can always be built again
    /// (ADR 0001), and `books.number` is unique because two books in one folder
    /// would overwrite each other — a rule about *folders*, which the importer
    /// keeps, not an invariant the cache may die over. It died over it:
    ///
    ///     Fatal error: SQLite error 19: UNIQUE constraint failed: books.number
    ///
    /// on a library whose import had been killed, leaving files with numbers
    /// the resumed run handed out again. One Finder duplication does it too.
    ///
    /// The **folder on disk is not renamed** (ADR 0007): only the index's idea
    /// of the number moves, and the number is bookkeeping for handing out the
    /// next one. Which of two colliding books keeps the original is not worth
    /// promising — that both are there, and findable, is.
    ///
    /// One indexed lookup per book, on a column that already has a unique index.
    private static func freeNumber(_ wanted: Int, for id: String, in database: Database) throws -> Int {
        let taken = try String.fetchOne(
            database, sql: "SELECT id FROM books WHERE number = ? AND id <> ?", arguments: [wanted, id])
        guard taken != nil else { return wanted }
        let highest = try Int.fetchOne(database, sql: "SELECT MAX(number) FROM books") ?? 0
        return highest + 1
    }

    private static func write(_ entry: LibraryEntry, in database: Database) throws {
        let book = entry.book
        let id = book.id.uuidString

        let seriesID = try book.series.map { try upsertSeries($0.name, in: database) }
        let number = try freeNumber(entry.number, for: id, in: database)
        try database.execute(
            sql: """
                INSERT INTO books
                    (id, number, folder, title, title_sort, series_id, series_index, rating, is_read,
                     publisher, published, language, description, cover_generation,
                     added_at, modified_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    number = excluded.number, folder = excluded.folder, title = excluded.title,
                    title_sort = excluded.title_sort, series_id = excluded.series_id,
                    series_index = excluded.series_index, rating = excluded.rating,
                    is_read = excluded.is_read, publisher = excluded.publisher,
                    published = excluded.published, language = excluded.language,
                    description = excluded.description,
                    cover_generation = excluded.cover_generation, added_at = excluded.added_at,
                    modified_at = excluded.modified_at, last_seen_at = excluded.last_seen_at
                """,
            arguments: [
                id, number, entry.folder, book.title, book.titleSort, seriesID, book.series?.index,
                book.rating, book.isRead, book.publisher, book.published, book.language, book.description,
                book.coverGeneration, book.addedAt, book.modifiedAt, Date(),
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

        // Calibre's custom columns. Read-only in v1.0, and still written on
        // every save: an entry that came back from the index and was saved
        // again would otherwise lose them, which is exactly how the identifiers
        // were lost in Sprint 2 — twice, because nothing draws attention to a
        // dictionary that is always empty.
        try database.execute(sql: "DELETE FROM custom_values WHERE book_id = ?", arguments: [id])
        for label in book.customValues.keys.sorted() {
            guard let value = book.customValues[label], !value.isEmpty else { continue }
            let columnID = try upsertCustomColumn(label: label, in: database)
            try database.execute(
                sql: "INSERT OR REPLACE INTO custom_values (book_id, column_id, value) VALUES (?, ?, ?)",
                arguments: [id, columnID, value])
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
    public func allEntries(sortedBy sort: BookOrder = .byTitle) async throws -> [LibraryEntry] {
        try await pool.read { database in
            try Self.entries(matching: nil, sortedBy: sort, in: database)
        }
    }

    public func entry(id: UUID) async throws -> LibraryEntry? {
        try await pool.read { database in
            try Self.entries(matching: [id], sortedBy: .byTitle, in: database).first
        }
    }

    public func entries(ids: [UUID], sortedBy sort: BookOrder = .byTitle) async throws -> [LibraryEntry] {
        guard !ids.isEmpty else { return [] }
        return try await pool.read { database in
            try Self.entries(matching: ids, sortedBy: sort, in: database)
        }
    }

    private static func entries(
        matching ids: [UUID]?, sortedBy sort: BookOrder, in database: Database
    ) throws -> [LibraryEntry] {
        var sql = """
            SELECT b.id, b.number, b.folder, b.title, b.title_sort, s.name AS series_name, b.series_index,
                   b.rating, b.is_read, b.publisher, b.published, b.language, b.description,
                   b.cover_generation, b.added_at, b.modified_at
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
        let customValues = try customValueRows(for: bookIDs, in: database)

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
                customValues: customValues[id] ?? [:],
                coverGeneration: row["cover_generation"] ?? 0,
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

    /// Calibre's custom columns per book, by label.
    private static func customValueRows(
        for bookIDs: [String], in database: Database
    ) throws -> [String: [String: String]] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT v.book_id AS book_id, c.label AS label, v.value AS value
                FROM custom_values v JOIN custom_columns c ON c.id = v.column_id
                WHERE v.book_id IN (\(databaseQuestionMarks(count: bookIDs.count)))
                """,
            arguments: StatementArguments(bookIDs))
        return Dictionary(grouping: rows) { $0["book_id"] as String }
            .mapValues { group in
                Dictionary(group.map { ($0["label"] as String, $0["value"] as String) }) { _, last in last }
            }
    }

    /// The column a value belongs to, made if it is not there.
    ///
    /// A book read back from its own OPF knows its columns' *labels* and
    /// nothing else — what they are called and what kind they are belongs to
    /// the library and lives in `library.json`. So a rebuild that has only the
    /// folders to go on creates the column named after its label, and
    /// `saveCustomColumns` fills in the rest when the descriptor is read.
    /// A column standing in for itself is better than a value with nowhere to go.
    private static func upsertCustomColumn(label: String, in database: Database) throws -> String {
        try database.execute(
            sql: """
                INSERT INTO custom_columns (id, label, name, kind) VALUES (?, ?, ?, 'text')
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [label, label, label])
        return label
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

    /// Publishers, which have no table of their own.
    ///
    /// A publisher is a column on `books` rather than a row somewhere, because
    /// nothing hangs off it: no sort key, no second name, no membership. That
    /// makes this a `GROUP BY` over one column instead of a join, and it is
    /// the only facet with no `name_sort` to order by — a publisher's name is
    /// a company's, and "Verlag" does not move to the end the way "The" does.
    public func publisherFacets() async throws -> [Facet] {
        try await facets(
            sql: """
                SELECT publisher AS name, COUNT(*) AS count FROM books
                WHERE publisher IS NOT NULL AND TRIM(publisher) <> ''
                GROUP BY publisher ORDER BY publisher COLLATE NOCASE
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
        /// Same file or same ISBN. Filled in by the caller from
        /// `duplicates()`, which is why `totals()` alone leaves it at zero.
        public var duplicates = 0
        /// Same title and first author, and nothing stronger.
        public var possibleDuplicates = 0

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
        let byTitle = try await suspectsByTitleAndAuthor().map { ($0, DuplicateReason.titleAuthor) }

        var found: [UUID: Set<DuplicateReason>] = [:]
        for group in groups + byTitle where group.0.count > 1 {
            for id in group.0 { found[id, default: []].insert(group.1) }
        }
        return found
    }

    /// Books that look like the same book by their title, grouped.
    ///
    /// **Why this is not `allTitleKeys()`.** That key is the *importer's*, and
    /// it has to stay strict: joining two files into one book is a decision
    /// about the disk, and a wrong one puts somebody else's book in a folder.
    /// This collection only ever raises a suspicion, and the Sprint 4
    /// screenshot showed what strictness costs it — the grid held
    /// "A Desolation #164 164" beside "A Desolation #164" and the sidebar said
    /// 0, because the two differed in a number the file name wrote twice *and*
    /// in an author one of them never had.
    ///
    /// So two things are widened, and only here:
    ///
    /// - the title is `DuplicateKey.foldedTitle`, which collapses a repeated
    ///   trailing number;
    /// - **a book with no author matches any author.** "Unknown" is the
    ///   absence of evidence, not evidence of a different person. Two *named*
    ///   authors under one title stay two books, because Ulysses by Joyce and
    ///   Ulysses by Tennyson are two books.
    func suspectsByTitleAndAuthor() async throws -> [[UUID]] {
        let rows: [(id: UUID, title: String, author: String?)] = try await pool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT b.id AS id, b.title AS title, a.name AS author
                    FROM books b
                    LEFT JOIN book_authors ba ON ba.book_id = b.id AND ba.position = 0
                    LEFT JOIN authors a ON a.id = ba.author_id
                    """
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"] as String) else { return nil }
                return (id, row["title"] as String, row["author"] as String?)
            }
        }

        var byTitle: [String: [(id: UUID, author: String?)]] = [:]
        for row in rows {
            let author = row.author.map(DuplicateKey.fold).flatMap { $0.isEmpty ? nil : $0 }
            byTitle[DuplicateKey.foldedTitle(row.title), default: []].append((row.id, author))
        }

        return byTitle.values.compactMap { books -> [UUID]? in
            guard books.count > 1 else { return nil }
            let suspects = books.filter { book in
                books.contains { other in
                    other.id != book.id && (other.author == nil || book.author == nil || other.author == book.author)
                }
            }
            return suspects.count > 1 ? suspects.map(\.id) : nil
        }
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
    /// What the library's custom columns are called and what kind each one is.
    ///
    /// The definitions live in `library.json` (ADR 0010) and this table is a
    /// cache of them, exactly as `shelves` is a cache of the shelf tree. Unlike
    /// the shelves, a column is **not** deleted when the descriptor stops
    /// mentioning it: the values still hang off it, they came out of somebody's
    /// Calibre library, and Shelf offers no way to put them back. A column
    /// nobody has a definition for keeps the one `upsertCustomColumn` gave it —
    /// its own label — which is worse than a name and better than a loss.
    /// The highest folder number any book in this library actually has.
    ///
    /// A **floor** for the next import's counter, not a replacement for it.
    /// `library.json` stays the authority (ADR 0001, decision 6): deriving the
    /// counter from what exists would let a book deleted in the Finder hand its
    /// number to the next import. But the stored counter is written when a run
    /// *finishes*, and a run that was killed has already put books on the disk
    /// — so the next run began at 1 again and collided with them.
    ///
    /// Measured, before this existed: an import of 2 000 books killed after 400
    /// left 400 in the index, and the resumed run died on
    /// `UNIQUE constraint failed: books.number`.
    public func highestBookNumber() async throws -> Int {
        try await pool.read { database in
            try Int.fetchOne(database, sql: "SELECT MAX(number) FROM books") ?? 0
        }
    }

    public func saveCustomColumns(_ columns: [CalibreCustomColumn]) async throws {
        try await pool.write { database in
            for column in columns {
                try database.execute(
                    sql: """
                        INSERT INTO custom_columns (id, label, name, kind) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET name = excluded.name, kind = excluded.kind
                        """,
                    arguments: [column.label, column.label, column.name, column.kind.rawValue])
            }
        }
    }

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

/// What the grid and the table are sorted by.
///
/// A table rather than a `switch` in the view, so the sort menu, the table's
/// column headers and a sort order saved in `library.json` cannot disagree
/// about what "by author" means.
///
/// The *direction* is not in here. It was — `addedNewest` and `ratingHighest`
/// baked it in — and that made three of the six orders reversible and three of
/// them not, for no reason a person could see. Field and direction are two
/// things, and `BookOrder` is the pair.
public enum BookSort: String, CaseIterable, Sendable, Codable {
    case title
    case author
    case series
    case rating
    case added
    case modified
    // The four the table drew as columns and could not sort by, from Sprint 2c
    // until Sprint 7. A column with no arrow is not a small gap: the header
    // invites a click and answers it with nothing.
    case tags
    case format
    case read
    case size

    public var label: String {
        switch self {
        case .title: return "Title"
        case .author: return "Author"
        case .series: return "Series"
        case .rating: return "Rating"
        case .added: return "Date Added"
        case .modified: return "Last Changed"
        case .tags: return "Tags"
        case .format: return "Format"
        case .read: return "Read"
        case .size: return "Size"
        }
    }

    /// Which way round the field is usually wanted first.
    ///
    /// A name reads A–Z; a date and a rating read newest and best first. The
    /// menu offers both either way — this only decides what one click gives.
    public var prefersDescending: Bool {
        switch self {
        case .title, .author, .series, .tags, .format: return false
        // Read first, biggest first, best first, newest first: what a person
        // clicking one of these is usually looking for is the far end of it.
        case .rating, .added, .modified, .read, .size: return true
        }
    }

    /// `COLLATE NOCASE` everywhere a person's eye reads the column: a library
    /// that puts "Zola" before "adams" is a library nobody can scan.
    ///
    /// Every order ends in the title, so two books that tie are in a fixed
    /// order rather than in whatever order SQLite happened to read them — a
    /// grid that reshuffles its ties on every reload looks broken.
    func sqlOrder(ascending: Bool) -> String {
        let direction = ascending ? "ASC" : "DESC"
        let byTitle = "b.title_sort COLLATE NOCASE \(direction)"
        switch self {
        case .title:
            return byTitle
        case .author:
            return """
                (SELECT a.name_sort FROM book_authors ba JOIN authors a ON a.id = ba.author_id
                 WHERE ba.book_id = b.id ORDER BY ba.position LIMIT 1) COLLATE NOCASE \(direction),
                b.title_sort COLLATE NOCASE
                """
        case .series:
            // Books without a series go last whichever way round it is sorted.
            // A NULL sorts before everything in SQLite, so ascending would bury
            // every series behind the books that have none.
            return """
                s.name_sort IS NULL, s.name_sort COLLATE NOCASE \(direction),
                b.series_index \(direction), b.title_sort COLLATE NOCASE
                """
        case .rating:
            return "b.rating \(direction), b.title_sort COLLATE NOCASE"
        case .added:
            return "b.added_at \(direction), b.title_sort COLLATE NOCASE"
        case .modified:
            return "b.modified_at \(direction), b.title_sort COLLATE NOCASE"
        case .tags:
            // The same string the table's Tags column draws: the tag names,
            // alphabetically, comma-separated. Alphabetically because that is
            // the order they come back in (`tags(for:)` orders by name), and a
            // column sorted by a string other than the one it shows is a column
            // in an order nobody can see.
            //
            // Books with no tags go last either way round, as the series rule
            // does and for the same reason: an empty string sorts before
            // everything, so ascending would begin with every untagged book.
            return """
                (SELECT GROUP_CONCAT(name, ', ') FROM
                    (SELECT t.name AS name FROM book_tags bt JOIN tags t ON t.id = bt.tag_id
                     WHERE bt.book_id = b.id ORDER BY t.name)) IS NULL,
                (SELECT GROUP_CONCAT(name, ', ') FROM
                    (SELECT t.name AS name FROM book_tags bt JOIN tags t ON t.id = bt.tag_id
                     WHERE bt.book_id = b.id ORDER BY t.name)) COLLATE NOCASE \(direction),
                b.title_sort COLLATE NOCASE
                """
        case .format:
            // "AZW3 · EPUB", the same string the Format column draws. The raw
            // values are lower case and the labels are the same letters in
            // capitals, so `COLLATE NOCASE` over the raw values is the order
            // the column shows.
            return """
                (SELECT GROUP_CONCAT(format, ' · ') FROM
                    (SELECT DISTINCT f.format AS format FROM formats f
                     WHERE f.book_id = b.id ORDER BY f.format)) COLLATE NOCASE \(direction),
                b.title_sort COLLATE NOCASE
                """
        case .read:
            return "b.is_read \(direction), b.title_sort COLLATE NOCASE"
        case .size:
            // Every file of the book together, which is what the Size column
            // shows. `COALESCE`, because a book whose files have all gone
            // missing has no rows to sum and would otherwise sort as NULL.
            return """
                (SELECT COALESCE(SUM(f.byte_size), 0) FROM formats f WHERE f.book_id = b.id) \(direction),
                b.title_sort COLLATE NOCASE
                """
        }
    }
}

/// A field and a direction: the whole of "how is this library sorted".
///
/// One value, so it can be compared, saved in `library.json` and restored —
/// and so nothing can hold a field without a direction.
public struct BookOrder: Equatable, Sendable, Codable {
    public var field: BookSort
    public var ascending: Bool

    public init(field: BookSort = .title, ascending: Bool = true) {
        self.field = field
        self.ascending = ascending
    }

    /// What one click on a field gives: its own preferred direction.
    public init(_ field: BookSort) {
        self.field = field
        self.ascending = !field.prefersDescending
    }

    public static let byTitle = BookOrder()

    /// "Title ↑", "Date Added ↓" – what the menu shows and what a screen
    /// reader reads.
    public var label: String { "\(field.label) \(ascending ? "↑" : "↓")" }

    public var reversed: BookOrder { BookOrder(field: field, ascending: !ascending) }

    var sqlOrder: String { field.sqlOrder(ascending: ascending) }
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

    /// A title folded for the *Duplicates* collection, with a number the name
    /// carries twice collapsed to one.
    ///
    /// `A Desolation #164 164` is what a file name makes of a book whose own
    /// title already ends with the issue number and whose scanner appended it
    /// again. Folded plainly it is "a desolation 164 164", which no comparison
    /// can join to "a desolation 164" — and the Sprint 4 screenshot showed the
    /// two of them side by side in the grid over a *Duplicates* that said 0.
    ///
    /// Only the *last* word, and only when it repeats the one before it, so
    /// `Battle 2000 15` keeps both of its numbers.
    public static func foldedTitle(_ title: String) -> String {
        var words = fold(title).split(separator: " ").map(String.init)
        while words.count >= 2, words[words.count - 1] == words[words.count - 2],
            Double(words[words.count - 1]) != nil
        {
            words.removeLast()
        }
        return words.joined(separator: " ")
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
