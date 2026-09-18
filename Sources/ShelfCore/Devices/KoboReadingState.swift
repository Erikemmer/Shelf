import Foundation
import GRDB

/// What a Kobo knows about how far somebody has read, read **only**.
///
/// A Kobo keeps its whole state in `.kobo/KoboReader.sqlite`: which file is
/// which book, how far through it the reader is, what the shelves on the device
/// are called and what is on them. Shelf shows all of that in the library and
/// **never writes a byte of it back** (CONCEPT §8.1). Writing into a device's
/// own database is how people lose a reading position, and Shelf has nothing to
/// gain from it that is worth that.
///
/// The database is opened through a **copy with its WAL beside it**, exactly as
/// Calibre's is ([ADR 0009](../../../docs/adr/0009-calibre-is-read-through-a-copy-of-metadata-db.md)).
/// The argument is the same one and, on a device, a stronger one: the file
/// belongs to a program that is still running on the other end of the cable,
/// opening it in place takes SQLite locks on it, and a WAL copied without its
/// sidecar is the database as of the last checkpoint — which on a reader can be
/// days old, so every recent page turn would be silently missing.
public struct KoboReadingState: Sendable {

    public enum Failure: Error, Equatable {
        case noDatabase(volume: String)
        case cannotCopy(reason: String)
        case cannotOpen(reason: String)
    }

    /// Where the file sits on the volume.
    public static let relativePath = ".kobo/KoboReader.sqlite"
    static let sidecarSuffixes = ["-wal", "-shm"]

    /// A Kobo mounts itself here, and its `ContentID`s are absolute paths
    /// inside that. Stripping it is what turns a `ContentID` into a path Shelf
    /// can compare with its own listing of the volume.
    public static let onboardPrefix = "file:///mnt/onboard/"

    /// One book as the device sees it.
    public struct Book: Equatable, Sendable, Identifiable {
        /// Relative to the volume root, so it lines up with `DeviceFile.path`.
        public var path: String
        public var title: String?
        public var author: String?
        /// 0–100, as the device counts it.
        public var percentRead: Int
        public var status: ReadStatus
        public var lastReadAt: Date?
        /// The shelves the *device* has it on. The device's shelves, not
        /// Shelf's: they are shown and never merged into the library's own
        /// (ADR 0008 keeps the library's shelf tree in `library.json`).
        public var shelves: [String]

        public var id: String { path }

        public init(
            path: String, title: String? = nil, author: String? = nil, percentRead: Int = 0,
            status: ReadStatus = .unread, lastReadAt: Date? = nil, shelves: [String] = []
        ) {
            self.path = path
            self.title = title
            self.author = author
            self.percentRead = percentRead
            self.status = status
            self.lastReadAt = lastReadAt
            self.shelves = shelves
        }
    }

    /// What `ReadStatus` in the device's own table means.
    public enum ReadStatus: Int, Equatable, Sendable, CaseIterable {
        case unread = 0
        case reading = 1
        case finished = 2

        public var label: String {
            switch self {
            case .unread: return "Unread"
            case .reading: return "Reading"
            case .finished: return "Finished"
            }
        }

        /// A value the device wrote that this version has never seen is
        /// `unread` rather than a crash: a firmware update must not stop a
        /// library from opening.
        public static func of(_ raw: Int) -> ReadStatus { ReadStatus(rawValue: raw) ?? .unread }
    }

    public struct Reading: Sendable {
        public var books: [Book]
        /// What could not be read — a missing table on an old firmware, say.
        /// Carried rather than thrown: a Kobo whose shelves cannot be read is
        /// still a Kobo whose reading positions can.
        public var warnings: [String]

        public init(books: [Book], warnings: [String] = []) {
            self.books = books
            self.warnings = warnings
        }

        public func book(at path: String) -> Book? { books.first { $0.path == path } }
    }

    public init() {}

    /// Reads the device's database through a copy in `cacheDirectory`.
    ///
    /// The copy is made in a folder of its own named for this read, and taken
    /// away again afterwards — so what is removed is exactly what was made
    /// (CLAUDE.md's rule about that cache folder).
    public func read(volume: URL, cacheDirectory: URL) throws -> Reading {
        let manager = FileManager.default
        let source = volume.appendingPathComponent(Self.relativePath)
        guard manager.fileExists(atPath: source.path) else {
            throw Failure.noDatabase(volume: volume.lastPathComponent)
        }

        let directory = cacheDirectory.appending(path: "kobo-read-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: directory) }
        let name = source.lastPathComponent
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: directory.appending(path: name))
            for suffix in Self.sidecarSuffixes {
                let sidecar = volume.appendingPathComponent(Self.relativePath + suffix)
                guard manager.fileExists(atPath: sidecar.path) else { continue }
                try manager.copyItem(at: sidecar, to: directory.appending(path: name + suffix))
            }
        } catch {
            throw Failure.cannotCopy(reason: error.localizedDescription)
        }
        return try readCopy(at: directory.appending(path: name))
    }

    /// Reads a copy that is already on disk — what a test hands a fixture to.
    public func readCopy(at database: URL) throws -> Reading {
        let queue: DatabaseQueue
        do {
            var configuration = Configuration()
            // Read-only, on our own copy. Nothing in Shelf has any business
            // writing into a reader's database, and a connection that cannot
            // write cannot write by accident.
            configuration.readonly = true
            queue = try DatabaseQueue(path: database.path, configuration: configuration)
        } catch {
            throw Failure.cannotOpen(reason: error.localizedDescription)
        }

        do {
            return try queue.read { db in
                var warnings: [String] = []
                let shelves = Self.shelves(in: db, warnings: &warnings)
                var books: [Book] = []
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT ContentID, Title, Attribution, ___PercentRead, ReadStatus, DateLastRead
                        FROM content WHERE ContentType = 6 AND ContentID LIKE 'file://%'
                        """)
                for row in rows {
                    let contentID: String = row["ContentID"] ?? ""
                    guard let path = Self.path(fromContentID: contentID) else { continue }
                    books.append(
                        Book(
                            path: path,
                            title: row["Title"],
                            author: row["Attribution"],
                            percentRead: Self.percent(row["___PercentRead"]),
                            status: ReadStatus.of(row["ReadStatus"] ?? 0),
                            lastReadAt: Self.date(row["DateLastRead"]),
                            shelves: shelves[contentID]?.sorted() ?? []))
                }
                return Reading(books: books.sorted { $0.path < $1.path }, warnings: warnings)
            }
        } catch {
            throw Failure.cannotOpen(reason: error.localizedDescription)
        }
    }

    // MARK: The small rules

    /// Shelf names per `ContentID`. A firmware without the tables is a warning,
    /// not a failure: the reading positions are the part that matters.
    static func shelves(in db: Database, warnings: inout [String]) -> [String: Set<String>] {
        do {
            var result: [String: Set<String>] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT ShelfName, ContentId FROM ShelfContent WHERE _IsDeleted = 0")
            for row in rows {
                guard let shelf: String = row["ShelfName"], let content: String = row["ContentId"] else { continue }
                result[content, default: []].insert(shelf)
            }
            return result
        } catch {
            warnings.append("the device's shelves could not be read: \((error as NSError).localizedDescription)")
            return [:]
        }
    }

    /// `file:///mnt/onboard/Books/Emma.epub` → `Books/Emma.epub`.
    ///
    /// A `ContentID` that is not under the mount point is left out rather than
    /// guessed at: a Kobo with an SD card writes `file:///mnt/sd/…`, and
    /// mapping that onto the internal volume would attach a reading position to
    /// the wrong file.
    public static func path(fromContentID id: String) -> String? {
        guard id.hasPrefix(onboardPrefix) else { return nil }
        let raw = String(id.dropFirst(onboardPrefix.count))
        return raw.removingPercentEncoding ?? raw
    }

    /// The device writes this as an integer, and older firmware as a real.
    static func percent(_ value: DatabaseValue?) -> Int {
        guard let value else { return 0 }
        if let number = Int.fromDatabaseValue(value) { return min(max(number, 0), 100) }
        if let number = Double.fromDatabaseValue(value) { return min(max(Int(number.rounded()), 0), 100) }
        return 0
    }

    /// `2019-04-02T19:24:00Z`, and a handful of neighbours. A date that will
    /// not parse is no date rather than a wrong one.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    static let dateFormats = [
        "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss",
    ]
}
