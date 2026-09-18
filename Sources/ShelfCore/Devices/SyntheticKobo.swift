import Foundation
import GRDB

/// A `KoboReader.sqlite` with the columns Shelf reads, for tests and for the
/// proof run.
///
/// **Synthetic, like every fixture here** (CLAUDE.md): no borrowed device
/// database goes into this repository, and one would carry somebody's reading
/// history. What this writes is the shape — the `content`, `Shelf` and
/// `ShelfContent` tables with the columns and the value conventions a real
/// Kobo uses — and nothing else. It is enough to prove the reader works and it
/// is honestly not a real device, which is a thing the proof run has to say.
public struct SyntheticKoboDatabase: Sendable {

    /// One book to write into it.
    public struct Entry: Sendable {
        /// Relative to the volume root, as the file really lies there.
        public var path: String
        public var title: String
        public var author: String
        public var percentRead: Int
        public var status: KoboReadingState.ReadStatus
        public var shelves: [String]
        public var lastReadAt: Date?

        public init(
            path: String, title: String, author: String, percentRead: Int = 0,
            status: KoboReadingState.ReadStatus = .unread, shelves: [String] = [], lastReadAt: Date? = nil
        ) {
            self.path = path
            self.title = title
            self.author = author
            self.percentRead = percentRead
            self.status = status
            self.shelves = shelves
            self.lastReadAt = lastReadAt
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Writes the database to `url`, making its folder if it is not there.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            // The columns Shelf reads, with the names and the underscore
            // prefixes a real device uses. The rest of a real `content` table
            // is another hundred columns, none of which this reads.
            try db.execute(
                sql: """
                    CREATE TABLE content (
                      ContentID TEXT PRIMARY KEY NOT NULL,
                      ContentType INTEGER,
                      MimeType TEXT,
                      Title TEXT,
                      Attribution TEXT,
                      ___PercentRead INTEGER,
                      ReadStatus INTEGER,
                      DateLastRead TEXT,
                      ___FileSize INTEGER
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE Shelf (
                      Name TEXT PRIMARY KEY NOT NULL, InternalName TEXT, Type TEXT, _IsDeleted BOOLEAN
                    )
                    """)
            try db.execute(
                sql: """
                    CREATE TABLE ShelfContent (
                      ShelfName TEXT NOT NULL, ContentId TEXT NOT NULL, _IsDeleted BOOLEAN,
                      PRIMARY KEY (ShelfName, ContentId)
                    )
                    """)

            var shelvesSeen: Set<String> = []
            for entry in entries {
                let contentID = KoboReadingState.onboardPrefix + entry.path
                try db.execute(
                    sql: """
                        INSERT INTO content
                          (ContentID, ContentType, MimeType, Title, Attribution, ___PercentRead,
                           ReadStatus, DateLastRead, ___FileSize)
                        VALUES (?, 6, 'application/epub+zip', ?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [
                        contentID, entry.title, entry.author, entry.percentRead, entry.status.rawValue,
                        entry.lastReadAt.map(Self.timestamp),
                    ])
                for shelf in entry.shelves {
                    if shelvesSeen.insert(shelf).inserted {
                        try db.execute(
                            sql: "INSERT INTO Shelf (Name, InternalName, Type, _IsDeleted) VALUES (?, ?, 'UserTag', 0)",
                            arguments: [shelf, shelf])
                    }
                    try db.execute(
                        sql: "INSERT INTO ShelfContent (ShelfName, ContentId, _IsDeleted) VALUES (?, ?, 0)",
                        arguments: [shelf, contentID])
                }
            }
        }
        try queue.close()
    }

    /// The date format a Kobo writes.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}
