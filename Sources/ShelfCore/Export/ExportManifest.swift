import Foundation

/// What a previous export put at a destination, written at the destination.
///
/// It is what makes a second run write **only the differences** — "37 new, 4
/// changed" — without reading a single byte back out of the exported files.
///
/// The direction is one-way and stays one-way. This file records what Shelf
/// *wrote*; it is never consulted to find out what a book is. Somebody who
/// edits an exported OPF has edited a copy, and the next export overwrites it
/// without ceremony. That is the difference between an export and a sync, and
/// Shelf is not offering a sync: two authorities that can disagree is the
/// failure this whole program is arranged to prevent.
///
/// ("Never reads back" is not in tension with copy-verify-then-trust. The
/// runner absolutely reads back the file it has just written, to hash it —
/// that is what "verified" means, here as everywhere. What it never does is
/// take *metadata* from the destination into the library.)
public struct ExportManifest: Equatable, Sendable, Codable {

    /// A dot file, so a folder handed to somebody else does not look like
    /// Shelf has left rubbish in it.
    public static let fileName = ".shelf-export.json"
    public static let currentVersion = 1

    public var version: Int
    public var writtenAt: Date
    /// The options the last run used. A second run with *different* options —
    /// other formats, another structure, another name pattern — cannot compare
    /// against these, and says so rather than pretending the destination is up
    /// to date.
    public var options: ExportOptions
    public var entries: [Entry]

    /// One file this export wrote.
    public struct Entry: Equatable, Sendable, Codable, Identifiable {
        /// Relative to the destination folder.
        public var path: String
        public var bookID: UUID
        /// Of the bytes in the **library**, which is what decides whether a
        /// second run needs to write it again. For an OPF, of the text that
        /// was rendered, so a metadata change shows up as "changed" without
        /// anything being hashed twice.
        public var sha256: String
        public var byteSize: Int64
        /// Whether this one was linked rather than copied, so a report can
        /// say how much space was really used.
        public var isHardLink: Bool

        public var id: String { path }

        public init(
            path: String, bookID: UUID, sha256: String, byteSize: Int64, isHardLink: Bool = false
        ) {
            self.path = path
            self.bookID = bookID
            self.sha256 = sha256
            self.byteSize = byteSize
            self.isHardLink = isHardLink
        }
    }

    public init(
        writtenAt: Date = Date(), options: ExportOptions = ExportOptions(), entries: [Entry] = [],
        version: Int = ExportManifest.currentVersion
    ) {
        self.version = version
        self.writtenAt = writtenAt
        self.options = options
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// What is at each path, for the planner's three-way answer: new, changed,
    /// or already right.
    public var byPath: [String: Entry] {
        Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { _, second in second })
    }

    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.path == entry.path }
        entries.append(entry)
    }

    // MARK: On disk

    public static func url(at destination: URL) -> URL {
        destination.appendingPathComponent(fileName)
    }

    /// Reads it, or an empty one. Never throws: a destination with no manifest
    /// is simply one that gets written in full.
    public static func read(at destination: URL) -> ExportManifest {
        guard let data = try? Data(contentsOf: url(at: destination)),
            let manifest = try? decoder.decode(ExportManifest.self, from: data),
            manifest.version <= currentVersion
        else { return ExportManifest() }
        return manifest
    }

    public func write(at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: Self.url(at: destination), options: .atomic)
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
