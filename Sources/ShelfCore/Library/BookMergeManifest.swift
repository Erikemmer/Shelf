import Foundation

/// The on-disk record of what a merge run has actually done — resume and
/// "Zusammenführen widerrufen" both read this one file, the same shape
/// `OrganizeManifest` already proved for `Organize Library…`.
public struct BookMergeManifest: Equatable, Sendable, Codable {
    public static let fileName = "book-merge-manifest.json"
    public static let currentVersion = 1

    public var version: Int
    public var startedAt: Date
    public var entries: [Entry]

    public init(startedAt: Date = Date(), entries: [Entry] = [], version: Int = currentVersion) {
        self.version = version
        self.startedAt = startedAt
        self.entries = entries
    }

    /// One file that moved from an absorbed book's folder into the
    /// surviving one, or – for `coverMove` – a cover file taken the same way.
    public struct MoveRecord: Equatable, Sendable, Codable {
        public var fromBookID: UUID
        public var fileName: String
        public var sha256: String

        public init(fromBookID: UUID, fileName: String, sha256: String) {
            self.fromBookID = fromBookID
            self.fileName = fileName
            self.sha256 = sha256
        }
    }

    /// One file sent straight to the Trash instead of moving anywhere.
    public struct DiscardRecord: Equatable, Sendable, Codable {
        public var fromBookID: UUID
        public var fileName: String
        public var sha256: String
        /// Where `FolderDisposal` says it landed. `nil` when the disposal
        /// used cannot say – undo then has nothing to bring this one file
        /// back from, though the rest of the group can still be reversed.
        public var trashedAt: URL?

        public init(fromBookID: UUID, fileName: String, sha256: String, trashedAt: URL?) {
            self.fromBookID = fromBookID
            self.fileName = fileName
            self.sha256 = sha256
            self.trashedAt = trashedAt
        }
    }

    /// Where one absorbed book's now-emptied folder landed in the Trash.
    /// `trashedAt` is `nil` when the disposal used cannot say – that one
    /// book's folder then stays failed rather than guessed at by undo.
    public struct FolderTrashRecord: Equatable, Sendable, Codable {
        public var bookID: UUID
        public var trashedAt: URL?

        public init(bookID: UUID, trashedAt: URL?) {
            self.bookID = bookID
            self.trashedAt = trashedAt
        }
    }

    /// One group's whole merge, recorded whole: everything `undo` needs to
    /// put the group back exactly as it was, without asking the folders
    /// anything they can no longer answer once an absorbed folder is in the
    /// Trash.
    public struct Entry: Equatable, Sendable, Codable, Identifiable {
        public var survivingID: UUID
        /// The survivor's own book and formats, exactly as they were before
        /// this merge touched them – restored on undo, not re-derived.
        public var priorSurvivorEntry: LibraryEntry
        /// Every absorbed book, whole, as it was before the merge – undo
        /// re-adds these to the index verbatim.
        public var absorbedEntries: [LibraryEntry]
        public var moves: [MoveRecord]
        public var discards: [DiscardRecord]
        public var coverMove: MoveRecord?
        public var absorbedFolderTrash: [FolderTrashRecord]
        public var mergedAt: Date

        public var id: UUID { survivingID }

        public init(
            survivingID: UUID, priorSurvivorEntry: LibraryEntry, absorbedEntries: [LibraryEntry],
            moves: [MoveRecord], discards: [DiscardRecord], coverMove: MoveRecord?,
            absorbedFolderTrash: [FolderTrashRecord], mergedAt: Date = Date()
        ) {
            self.survivingID = survivingID
            self.priorSurvivorEntry = priorSurvivorEntry
            self.absorbedEntries = absorbedEntries
            self.moves = moves
            self.discards = discards
            self.coverMove = coverMove
            self.absorbedFolderTrash = absorbedFolderTrash
            self.mergedAt = mergedAt
        }

        /// Where a particular absorbed book's folder landed, if it did.
        public func trashedFolder(for bookID: UUID) -> URL? {
            absorbedFolderTrash.first { $0.bookID == bookID }?.trashedAt
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Which survivors already have a recorded merge – what "already done"
    /// means for resume, the same UUID-set membership test
    /// `OrganizeManifest.movedBookIDs` uses.
    public var mergedSurvivorIDs: Set<UUID> { Set(entries.map(\.survivingID)) }

    public func entry(for survivingID: UUID) -> Entry? {
        entries.first { $0.survivingID == survivingID }
    }

    /// Replaces any existing row for this survivor, then appends – a group
    /// merged twice in one run has exactly one row.
    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.survivingID == entry.survivingID }
        entries.append(entry)
    }

    public static func url(in library: Library) -> URL {
        library.privateFolder.appendingPathComponent(fileName)
    }

    /// Never throws: a missing, corrupt or future-versioned manifest comes
    /// back empty, the same rule `OrganizeManifest.read` follows and for the
    /// same reason – the folders are the truth (ADR 0001), and this file is
    /// only ever a cache of what a run already did.
    public static func read(in library: Library) -> BookMergeManifest {
        let url = url(in: library)
        guard let data = try? Data(contentsOf: url) else { return BookMergeManifest() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(BookMergeManifest.self, from: data),
            manifest.version == currentVersion
        else { return BookMergeManifest() }
        return manifest
    }

    public func write(in library: Library) throws {
        try FileManager.default.createDirectory(at: library.privateFolder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(in: library), options: .atomic)
    }

    public static func remove(in library: Library) {
        try? FileManager.default.removeItem(at: url(in: library))
    }
}
