import Foundation

/// What an organise has actually moved, written inside the library as it goes.
///
/// It has the two jobs the device manifest has, and one more that matters more
/// than either:
///
/// * **Resume.** A run cut off halfway is resumed by skipping what is already
///   recorded here.
/// * **The way back.** `Undo Organize` is this file walked backwards. A folder
///   move is not something to put on the window's undo stack — that stack dies
///   with the window, and this has to survive a crash — so the way back is a
///   file, like everything else in this program that has to outlive a process.
/// * **Saying where a book went.** A run interrupted untidily leaves some
///   books at their old path and some at their new one. Both are findable: the
///   folder is the truth and a rebuild reads whatever is there (ADR 0001). This
///   file is what makes the *tidy* answer possible as well.
///
/// Like every other manifest here it is a cache: losing it costs the way back
/// and nothing else, because the folders still say what they hold. So nothing
/// in here throws on a bad file — it comes back empty.
public struct OrganizeManifest: Equatable, Sendable, Codable {

    public static let fileName = "organize-manifest.json"
    public static let currentVersion = 1

    public var version: Int
    public var startedAt: Date
    public var entries: [Entry]
    /// The one move that is half-done, if any.
    ///
    /// An ordinary move is a single `rename`, which the file system either did
    /// or did not do — there is no halfway to record. A **case-only** move is
    /// two renames through a third name, and a process killed between them
    /// leaves a book's folder under a name nothing points at. That is the one
    /// window in this whole operation where a book could be lost, so it is the
    /// one thing written down before it happens rather than after.
    ///
    /// Written and flushed before the first rename, cleared after the second.
    /// The next run puts it right before it plans anything.
    public var inFlight: InFlight?

    /// A case-only move that has begun.
    public struct InFlight: Equatable, Sendable, Codable {
        public var bookID: UUID
        /// Where the folder is parked, relative to the library root.
        public var staging: String
        public var from: String
        public var to: String

        public init(bookID: UUID, staging: String, from: String, to: String) {
            self.bookID = bookID
            self.staging = staging
            self.from = from
            self.to = to
        }
    }

    /// One folder that has moved, with the proof it arrived whole.
    public struct Entry: Equatable, Sendable, Codable, Identifiable {
        public var bookID: UUID
        public var from: String
        public var to: String
        /// Every file in the folder and its SHA-256 **read back after the
        /// move**, keyed by file name. That is what "verified" means here, the
        /// same as everywhere else: a digest was compared, not that a call
        /// returned success (ADR 0002, decision 2).
        public var digests: [String: String]
        public var movedAt: Date

        public var id: UUID { bookID }

        public init(
            bookID: UUID, from: String, to: String, digests: [String: String],
            movedAt: Date = Date()
        ) {
            self.bookID = bookID
            self.from = from
            self.to = to
            self.digests = digests
            self.movedAt = movedAt
        }
    }

    public init(
        startedAt: Date = Date(), entries: [Entry] = [], inFlight: InFlight? = nil,
        version: Int = OrganizeManifest.currentVersion
    ) {
        self.version = version
        self.startedAt = startedAt
        self.entries = entries
        self.inFlight = inFlight
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Which books have already been moved by this run, so a resume can skip
    /// them without asking the disk.
    public var movedBookIDs: Set<UUID> { Set(entries.map(\.bookID)) }

    public func entry(for bookID: UUID) -> Entry? { entries.first { $0.bookID == bookID } }

    /// Adds or replaces one book's row. Replaces, because a book organised
    /// twice must leave one row saying where it came from *first* — no: it
    /// leaves one row saying where it came from **this run**, which is what
    /// `Undo Organize` needs, and the row from the earlier run has already
    /// been undone or accepted.
    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.bookID == entry.bookID }
        entries.append(entry)
    }

    // MARK: On disk

    public static func url(in library: Library) -> URL {
        library.privateFolder.appendingPathComponent(fileName)
    }

    /// Reads it, or an empty one. Never throws: a library whose manifest is
    /// gone is a library whose folders still say what they hold.
    public static func read(in library: Library) -> OrganizeManifest {
        guard let data = try? Data(contentsOf: url(in: library)),
            let manifest = try? decoder.decode(OrganizeManifest.self, from: data),
            manifest.version <= currentVersion
        else { return OrganizeManifest() }
        return manifest
    }

    public func write(in library: Library) throws {
        try FileManager.default.createDirectory(
            at: library.privateFolder, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: Self.url(in: library), options: .atomic)
    }

    /// Takes the file away, once the run it describes has been accepted or
    /// undone. Not before: while it is there, there is a way back.
    public static func remove(in library: Library) {
        try? FileManager.default.removeItem(at: url(in: library))
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
