import Foundation
import GRDB

/// The index's schema, as versioned migrations.
///
/// Migrations rather than "create if not exists": the index is rebuildable, but
/// that is not a licence to change it carelessly. A user who has spent an
/// evening arranging shelves has data in here that the folders do not hold, and
/// a migration is the difference between keeping it and asking them to do it
/// again (Leitlinie: "Schema-Änderungen nur per versionierter Migration").
///
/// The tables are the ones named in CONCEPT §5.2. Everything a book *is* can be
/// rebuilt from the folders; what cannot is marked in the comments.
enum IndexSchema {
    /// Bumped whenever a migration is added. Read back out of the file so a
    /// mismatch is visible rather than mysterious.
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        // In a development build a changed migration should rebuild rather than
        // fail; the index is a cache, so there is nothing to lose. In release
        // this is off, because silently erasing shelves would not be a cache.
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1-books") { database in
            try create(in: database)
        }
        return migrator
    }()

    private static func create(in database: Database) throws {
        // MARK: People, series, keywords
        //
        // Before `books`, because `books` points at `series`: SQLite resolves a
        // `REFERENCES` clause when the table is created, so a forward reference
        // fails with "no such table". Parents first is the order a schema with
        // foreign keys has to be written in.

        try database.create(table: "authors") { table in
            table.primaryKey("id", .text).notNull()
            table.column("name", .text).notNull().unique()
            table.column("name_sort", .text).notNull().indexed()
        }

        try database.create(table: "series") { table in
            table.primaryKey("id", .text).notNull()
            table.column("name", .text).notNull().unique()
            table.column("name_sort", .text).notNull().indexed()
        }

        try database.create(table: "tags") { table in
            table.primaryKey("id", .text).notNull()
            table.column("name", .text).notNull().unique()
        }

        // MARK: Shelves
        //
        // The one part of the index that is *not* derivable from the folders
        // alone – it is mirrored into each book's `metadata.opf` as
        // `shelf:shelves` and into `library.json` so that a lost index costs
        // nothing, but within the index this is the authority.

        try database.create(table: "shelves") { table in
            table.primaryKey("id", .text).notNull()
            table.column("name", .text).notNull()
            table.column("parent_id", .text).references("shelves", onDelete: .cascade)
            table.column("position", .integer).notNull().defaults(to: 0)
        }

        // MARK: Books

        try database.create(table: "books") { table in
            // The UUID as text. Text and not a blob so the file can be read
            // with any SQLite tool – a library nobody but Shelf can open would
            // be the lock-in the Leitlinie forbids.
            table.primaryKey("id", .text).notNull()
            // The running number in the book's folder name, `… (17)`. Unique,
            // because two books in one folder would overwrite each other.
            table.column("number", .integer).notNull().unique()
            /// Path of the book's folder relative to the library root.
            table.column("folder", .text).notNull()
            table.column("title", .text).notNull()
            table.column("title_sort", .text).notNull().indexed()
            table.column("series_id", .text).references("series", onDelete: .setNull)
            table.column("series_index", .double)
            table.column("rating", .integer).notNull().defaults(to: 0)
            table.column("is_read", .boolean).notNull().defaults(to: false)
            table.column("publisher", .text)
            table.column("published", .datetime)
            table.column("language", .text)
            table.column("description", .text)
            table.column("added_at", .datetime).notNull().indexed()
            table.column("modified_at", .datetime).notNull()
            // Whether the last look at the disk found the folder as expected.
            // The index is never allowed to quietly disagree with the folders
            // (CONCEPT §5.2): a mismatch is shown, not resolved.
            table.column("last_seen_at", .datetime)
        }

        // MARK: What links a book to the rest

        try database.create(table: "book_authors") { table in
            table.column("book_id", .text).notNull().references("books", onDelete: .cascade)
            table.column("author_id", .text).notNull().references("authors", onDelete: .cascade)
            // The order the names are printed in. Not a set: the first author
            // decides the folder, so the order is data.
            table.column("position", .integer).notNull().defaults(to: 0)
            table.primaryKey(["book_id", "author_id"])
        }

        try database.create(table: "book_tags") { table in
            table.column("book_id", .text).notNull().references("books", onDelete: .cascade)
            table.column("tag_id", .text).notNull().references("tags", onDelete: .cascade)
            table.primaryKey(["book_id", "tag_id"])
        }

        try database.create(table: "book_shelves") { table in
            table.column("book_id", .text).notNull().references("books", onDelete: .cascade)
            table.column("shelf_id", .text).notNull().references("shelves", onDelete: .cascade)
            table.column("position", .integer).notNull().defaults(to: 0)
            table.primaryKey(["book_id", "shelf_id"])
        }

        // MARK: Files

        try database.create(table: "formats") { table in
            table.autoIncrementedPrimaryKey("rowid")
            table.column("book_id", .text).notNull().references("books", onDelete: .cascade)
            table.column("format", .text).notNull()
            table.column("file_name", .text).notNull()
            table.column("byte_size", .integer).notNull()
            // Indexed because this is how a duplicate is found and how a book
            // already on a device is recognised (CONCEPT §5.3).
            table.column("sha256", .text).notNull().indexed()
            table.column("modified_at", .datetime).notNull()
            table.column("drm", .text)
            table.uniqueKey(["book_id", "file_name"])
        }

        try database.create(table: "identifiers") { table in
            table.column("book_id", .text).notNull().references("books", onDelete: .cascade)
            table.column("scheme", .text).notNull()
            table.column("value", .text).notNull()
            table.primaryKey(["book_id", "scheme"])
        }
        // The importer looks a book up by ISBN before anything else.
        try database.create(indexOn: "identifiers", columns: ["scheme", "value"])

        // MARK: Calibre's custom columns
        //
        // Read-only in v1.0 (CONCEPT §4, "Should"). The tables exist from the
        // first migration so Sprint 3 does not have to migrate a library that
        // is already in use.

        try database.create(table: "custom_columns") { table in
            table.primaryKey("id", .text).notNull()
            /// Calibre's label, e.g. `#read_date`.
            table.column("label", .text).notNull().unique()
            table.column("name", .text).notNull()
            /// `text`, `bool`, `datetime`, `int`, `float`, … as Calibre names it.
            table.column("kind", .text).notNull()
        }
        try database.create(table: "custom_values") { table in
            table.column("book_id", .text).notNull().references("books", onDelete: .cascade)
            table.column("column_id", .text).notNull().references("custom_columns", onDelete: .cascade)
            table.column("value", .text)
            table.primaryKey(["book_id", "column_id"])
        }

        // MARK: Devices
        //
        // Sprint 5. Here from the start for the same reason as the custom
        // columns, and because "which books are on my Kobo" is a question the
        // index has to be able to answer without the Kobo being plugged in.

        try database.create(table: "devices") { table in
            table.primaryKey("id", .text).notNull()
            table.column("name", .text).notNull()
            /// Which profile recognised it: `kobo`, `kindle`, `tolino`, …
            table.column("profile", .text).notNull()
            table.column("last_seen_at", .datetime)
        }
        try database.create(table: "device_books") { table in
            table.column("device_id", .text).notNull().references("devices", onDelete: .cascade)
            table.column("book_id", .text).references("books", onDelete: .setNull)
            /// Path on the device. Kept even when the book is not in the
            /// library, so a device's own contents can be listed honestly.
            table.column("path", .text).notNull()
            table.column("sha256", .text)
            table.column("verified_at", .datetime)
            table.primaryKey(["device_id", "path"])
        }

        // MARK: Full-text search
        //
        // A plain FTS5 table rather than one contentful over `books`: the text
        // that is searched spans five tables (title, authors, series, tags,
        // description), and there is no single row to point an external-content
        // table at. `LibraryIndex` writes this row whenever it writes a book,
        // which keeps the two in step in one place instead of in five triggers.
        try database.create(virtualTable: "search", using: FTS5()) { table in
            table.tokenizer = .unicode61(diacritics: .removeLegacy)
            table.column("title")
            table.column("authors")
            table.column("series")
            table.column("tags")
            table.column("description")
            // Not searched, only carried, so a hit can be turned back into a
            // book without a join on a rowid nobody stored.
            table.column("book_id").notIndexed()
        }
    }
}
