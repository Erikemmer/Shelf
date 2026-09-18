import Foundation

/// The answers the services already gave, kept on disk so the same ISBN is
/// never asked twice (CONCEPT §9).
///
/// **In `~/Library/Caches/Shelf/online/`, not in the library.** The cover cache
/// lives inside the library because its key is a book's UUID and it belongs to
/// that library; this one is keyed by an ISBN or a title, so the same answer
/// serves every library on the Mac — and unlike the covers, nothing here is
/// worth carrying to another machine. It is a cache in the ordinary sense:
/// deleting the folder costs one more request.
///
/// The folder is handed in rather than found here, because the core builds on
/// Linux where `~/Library` does not exist, and because a test must be able to
/// point it somewhere of its own.
public actor ResponseCache {
    public let folder: URL
    /// How long an answer is trusted. A month: a book's metadata does not move
    /// quickly, and the alternative — asking every time — is the thing the
    /// cache exists to stop.
    public let maximumAge: TimeInterval

    public static let defaultMaximumAge: TimeInterval = 30 * 86_400

    public init(folder: URL, maximumAge: TimeInterval = ResponseCache.defaultMaximumAge) {
        self.folder = folder
        self.maximumAge = maximumAge
    }

    /// The stored answer, or `nil` when there is none or it has gone stale.
    public func read(_ key: String) -> Data? {
        let file = url(for: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            let written = attributes[.modificationDate] as? Date,
            Date().timeIntervalSince(written) < maximumAge,
            let data = try? Data(contentsOf: file)
        else { return nil }
        return data
    }

    /// Stores an answer. A cache that cannot be written is **not an error**:
    /// the lookup worked, and the only cost is asking again next time.
    public func write(_ data: Data, for key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Through a `.part` and an atomic rename, the same way every other
        // write in Shelf goes: a half-written answer read back as JSON is a
        // parse error blamed on the service.
        let target = url(for: key)
        let part = target.appendingPathExtension("part")
        guard (try? data.write(to: part, options: .atomic)) != nil else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: part, to: target)
    }

    /// What the folder holds, in bytes — what `Shelf ▸ Clear…` would name.
    public func size() -> Int64 {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        return names.reduce(into: Int64(0)) { total, name in
            let path = folder.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }

    /// Removes every stored answer. Only ever files this cache wrote, in the
    /// folder it was given — never the folder itself (CLAUDE.md).
    public func clear() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasSuffix(".json") || name.hasSuffix(".json.part") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func url(for key: String) -> URL {
        folder.appendingPathComponent(key).appendingPathExtension("json")
    }
}
