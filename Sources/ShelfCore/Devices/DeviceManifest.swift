import Foundation

/// What Shelf has put on one device, written on the device itself.
///
/// Three jobs, and each of them would otherwise cost a full re-hash of a
/// 32 GB card:
///
/// * **Resume.** A transfer cut off halfway is resumed by skipping what the
///   manifest already names with the same digest (ADR 0002, decision 6).
/// * **"On the device".** The grid's badge is a lookup here, not a walk.
/// * **Deleting.** The confirmation can name the book a file belongs to,
///   rather than only the file.
///
/// It is a *cache of the card*, exactly as the index is a cache of the library
/// folder: a manifest that is missing or unreadable costs speed and nothing
/// else, because the files themselves are still there to be listed and matched
/// by name. So nothing here throws on a bad file — it comes back empty.
public struct DeviceManifest: Equatable, Sendable, Codable {

    /// Where it lives on the volume. A dot folder, so a card opened in the
    /// Finder does not look like Shelf has left rubbish on it.
    public static let folderName = ".shelf"
    public static let fileName = "device-manifest.json"
    public static let currentVersion = 1

    public var version: Int
    /// Which profile wrote it, so a card moved between two readers says so.
    public var deviceID: String
    public var entries: [Entry]

    /// One file Shelf put there.
    public struct Entry: Equatable, Sendable, Codable, Identifiable {
        /// Path on the volume, relative to its root — `documents/Austen, Jane - Emma.epub`.
        public var path: String
        /// The book in the library it came from.
        public var bookID: UUID
        public var title: String
        public var author: String
        public var format: BookFileFormat
        public var byteSize: Int64
        /// Of the bytes as they were read back off the device. This is the
        /// whole of "verified": the digest in here was computed from the
        /// device's own copy, not from the source.
        public var sha256: String
        public var sentAt: Date

        public var id: String { path }

        public init(
            path: String, bookID: UUID, title: String, author: String, format: BookFileFormat,
            byteSize: Int64, sha256: String, sentAt: Date = Date()
        ) {
            self.path = path
            self.bookID = bookID
            self.title = title
            self.author = author
            self.format = format
            self.byteSize = byteSize
            self.sha256 = sha256
            self.sentAt = sentAt
        }
    }

    public init(deviceID: String, entries: [Entry] = [], version: Int = DeviceManifest.currentVersion) {
        self.version = version
        self.deviceID = deviceID
        self.entries = entries
    }

    // MARK: Asking it things

    /// Every digest on the device, so a plan can skip what is already there.
    public var digests: Set<String> { Set(entries.map(\.sha256)) }

    /// Which formats of a book are on the device already.
    public func formats(of bookID: UUID) -> Set<BookFileFormat> {
        Set(entries.filter { $0.bookID == bookID }.map(\.format))
    }

    public var bookIDs: Set<UUID> { Set(entries.map(\.bookID)) }

    public func entry(at path: String) -> Entry? { entries.first { $0.path == path } }

    /// Adds or replaces one file's row. Replaces, because sending a book again
    /// after editing its metadata writes the same path with new bytes, and two
    /// rows for one file would make the next resume skip the wrong one.
    public mutating func record(_ entry: Entry) {
        entries.removeAll { $0.path == entry.path }
        entries.append(entry)
    }

    public mutating func forget(paths: [String]) {
        let gone = Set(paths)
        entries.removeAll { gone.contains($0.path) }
    }

    // MARK: On disk

    public static func url(onVolume volume: URL) -> URL {
        volume.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    /// Reads the manifest, or an empty one. Never throws: a card whose
    /// manifest is gone is a card whose files are still there.
    public static func read(fromVolume volume: URL, deviceID: String) -> DeviceManifest {
        guard let data = try? Data(contentsOf: url(onVolume: volume)),
            let manifest = try? decoder.decode(DeviceManifest.self, from: data),
            manifest.version <= currentVersion
        else { return DeviceManifest(deviceID: deviceID) }
        return manifest
    }

    /// Writes it atomically. The one file Shelf writes to a device that is not
    /// a book.
    public func write(toVolume volume: URL) throws {
        let folder = volume.appendingPathComponent(Self.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
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
