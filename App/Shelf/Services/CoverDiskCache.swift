import AppKit
import ImageIO
import ShelfCore
import os

/// Keeps decoded covers on disk, inside the library's own `.shelf/covers/`.
///
/// **From Sprint 1, not later.** Selector learned this the hard way: its
/// preview cache arrived in Sprint 6c, after a sprint of "why is opening a
/// folder slow the second time". Here it is in the first sprint, because with
/// 8 000 books the difference between a cold and a warm open is the difference
/// between a usable app and an unusable one (CONCEPT §13).
///
/// Inside the library rather than in `~/Library/Caches`, because the key is the
/// book's UUID: the cache belongs to the library, moves with it, and a library
/// on an external disk carries its covers with it.
///
/// The cache is an accelerator and never a duty: every failure in here – a full
/// disk, a revoked permission, a half-written file – is swallowed and logged,
/// and the caller decodes as it always did.
actor CoverDiskCache {
    private let folder: URL
    private let logger = Logger(subsystem: "de.erikemmer.shelf", category: "cover-cache")
    private var didTrim = false

    init(library: Library) {
        folder = library.coversFolder
    }

    // MARK: Reading

    /// The stored cover for this book at this size, or nil – which simply means
    /// "decode it", never an error.
    func image(for key: CoverCacheKey) -> DecodedCover? {
        let file = folder.appending(path: fileName(for: key))
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        touch(file)
        return DecodedCover(
            image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)),
            byteSize: cgImage.width * cgImage.height * 4)
    }

    /// Which books have a cover in the cache.
    ///
    /// Read once when a library opens, to answer the "Missing Cover" collection
    /// without a stat call per book. The file name carries the UUID in plain
    /// text for exactly this.
    func cachedBookIDs() -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(
            names.compactMap { name in
                UUID(uuidString: String(name.prefix(36)))
            })
    }

    // MARK: Writing

    /// Stores a decoded cover. Called from a background task that has already
    /// passed the decode gate, so this never competes with a cover somebody is
    /// waiting for.
    func store(_ decoded: DecodedCover, for key: CoverCacheKey) {
        guard let cgImage = decoded.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            logger.notice("cannot create the cover cache folder: \(error.localizedDescription, privacy: .public)")
            return
        }

        let target = folder.appending(path: fileName(for: key))
        // Written under a temporary name and moved into place, so a crash or a
        // full disk cannot leave half a picture behind that would later be read
        // back as if it were whole.
        let temporary = folder.appending(path: ".writing-\(UUID().uuidString)")
        guard CoverDecoder.encode(cgImage, to: temporary) else { return }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            logger.notice("cannot store a cover: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Housekeeping

    /// Deletes the oldest files until the folder is under the limit again.
    /// Runs once per library open, in the background; a second call does nothing.
    func trimOnce() {
        guard !didTrim else { return }
        didTrim = true
        let doomed = CoverCachePolicy.evictions(from: entries())
        for entry in doomed {
            try? FileManager.default.removeItem(at: folder.appending(path: entry.fileName))
        }
        if !doomed.isEmpty {
            logger.info("cover cache: removed \(doomed.count, privacy: .public) old files")
        }
    }

    func usedBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.byteSize }
    }

    func clear() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        logger.info("cover cache cleared")
    }

    /// Forgets one book's cached covers — every size and **every generation**.
    ///
    /// For the cases where the file beside the book changes under the cache: a
    /// cover fetched from the net, chosen from a file, dragged in, or pulled
    /// out of the book file again. Without this the grid would keep drawing
    /// what it cached until the cache was trimmed — wrong, and then quietly
    /// right, which is the worse kind of wrong.
    ///
    /// By the name's UUID prefix rather than by rebuilding the keys, and that
    /// is the whole point: rebuilding them needs to know which generations
    /// have ever been written, and this type does not. Somebody trying four
    /// pictures in a row would otherwise leave three in the folder until the
    /// next trim. The UUID is in the name in plain text for exactly this kind
    /// of question (`CoverCacheKey.fileName`).
    func forget(_ bookID: UUID) {
        let prefix = bookID.uuidString
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Facts about files

    private func entries() -> [CoverCachePolicy.Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard
            let names = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }

        return names.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), let size = values.fileSize else {
                return nil
            }
            // Access date, because a cover that keeps being read is worth
            // keeping however long ago it was written; the modification date is
            // the fallback where the volume does not track reads.
            let used = values.contentAccessDate ?? values.contentModificationDate ?? .distantPast
            return CoverCachePolicy.Entry(fileName: file.lastPathComponent, byteSize: Int64(size), lastUsed: used)
        }
    }

    /// Marks a file as used now, which is what the eviction order reads.
    /// Volumes mounted `noatime` do not record this; then the write date stands.
    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private func fileName(for key: CoverCacheKey) -> String {
        // The extension is not the format: HEIC and JPEG are both read back by
        // ImageIO from the content, and one name keeps a file written by an
        // older machine findable after an upgrade.
        key.fileName(hashedBy: SHA256Hasher(), extension: "img")
    }
}
