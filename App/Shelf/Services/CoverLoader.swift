import AppKit
import Foundation
import ShelfCore

/// Coordinates cover decoding: caches results, makes sure the same cover is
/// never decoded twice at once, and hands the actual work to detached tasks so
/// several decode in parallel (bounded by `DecodeGate`).
///
/// The actor itself must stay quick – it only bookkeeps. Decoding *inside* the
/// actor was Selector's original mistake: every request queued behind every
/// other one, so jumping to the last photo meant waiting for all the photos
/// before it (Selector's ADR 0003). The same shape is used here, with the one
/// difference that a cover is small enough that every book can keep one in
/// memory at the grid size.
actor CoverLoader {
    /// Four parallel decodes keep the CPU busy without starving the UI. One
    /// number in one place, ready to be measured on real machines.
    static let maxParallelDecodes = 4

    /// Where the covers are, and where the cached ones go.
    private let library: Library
    private let diskCache: CoverDiskCache

    /// Background warming may hold at most half the slots, so scrolling still
    /// has cores to run on while a library warms up.
    private let gate = DecodeGate(limit: maxParallelDecodes, backgroundLimit: maxParallelDecodes / 2)

    /// The grid size for every book: ~40 KB each decoded to 400 px, so 8 000
    /// books cost about 320 MB at the top of the budget and a jump anywhere in
    /// the library shows a cover at once.
    private let gridCovers = Cache(countLimit: 10_000, megabytes: 500)
    /// The inspector's size, kept for a window around the selection only:
    /// a 1 000 px cover is ~2.5 MB, so a whole library would not fit.
    private let largeCovers = Cache(countLimit: 60, megabytes: 200)

    /// Decodes under way, so a second request for the same cover waits for the
    /// first instead of starting its own.
    private var inFlight: [Request: Task<DecodedCover?, Never>] = [:]

    private struct Request: Hashable {
        let bookID: UUID
        let size: CoverSize
    }

    init(library: Library) {
        self.library = library
        diskCache = CoverDiskCache(library: library)
    }

    // MARK: Requests

    /// The cover for a book at a size, decoding it if need be.
    func cover(for entry: LibraryEntry, size: CoverSize, priority: LoadPriority = .interactive) async -> NSImage? {
        let key = CoverCacheKey(bookID: entry.id, pixelWidth: size.pixels)
        if let hit = cache(for: size).image(for: entry.id) { return hit.image }

        // Somebody is already decoding this exact cover – wait for them rather
        // than doing the same work twice. Priority does not change the result.
        let request = Request(bookID: entry.id, size: size)
        if let running = inFlight[request] {
            return await running.value?.image
        }
        return await decode(entry: entry, size: size, key: key, priority: priority)?.image
    }

    /// The best version already in memory, without decoding anything.
    ///
    /// This is what lets a cell put *something* on screen the moment it scrolls
    /// into view: the grid tier is held for every book, so this is usually a hit.
    func cached(for bookID: UUID, size: CoverSize) -> NSImage? {
        if let hit = cache(for: size).image(for: bookID) { return hit.image }
        // A larger tier will do, scaled down; the reverse would be blurry.
        if size == .grid, let hit = largeCovers.image(for: bookID) { return hit.image }
        return nil
    }

    /// Passed through to the gate: while the user works the window, warming waits.
    func setInteracting(_ interacting: Bool) async {
        await gate.setInteracting(interacting)
    }

    /// Releases every large cover except the ones still worth holding.
    func limitLargeCovers(to ids: Set<UUID>) {
        largeCovers.removeAll(except: ids)
    }

    // MARK: The cache on disk

    func cachedBookIDs() async -> Set<UUID> {
        await diskCache.cachedBookIDs()
    }

    func trimDiskCache() async {
        await diskCache.trimOnce()
    }

    func diskCacheBytes() async -> Int64 {
        await diskCache.usedBytes()
    }

    func clearDiskCache() async {
        await diskCache.clear()
        gridCovers.removeAll(except: [])
        largeCovers.removeAll(except: [])
    }

    // MARK: Decoding

    private func decode(
        entry: LibraryEntry, size: CoverSize, key: CoverCacheKey, priority: LoadPriority
    ) async -> DecodedCover? {
        let request = Request(bookID: entry.id, size: size)
        let url = library.root.appendingPathComponent(entry.folder, isDirectory: true)

        // `Task.detached` takes the work off this actor, so the next request can
        // be served while this cover decodes.
        let task = Task.detached(priority: priority.taskPriority) { [gate, diskCache] () -> DecodedCover? in
            // The disk cache is asked *before* the gate: reading back a small
            // HEIC is a fraction of decoding a 1 600 px cover, and queueing it
            // behind four running decodes would throw away most of the saving.
            if let cached = await diskCache.image(for: key) { return cached }
            guard let coverURL = CoverFile.url(in: url) else { return nil }

            // No suspension point between acquire and release, so the slot
            // cannot leak: `decode` is synchronous and does not throw.
            await gate.acquire(priority)
            let decoded = CoverDecoder.decode(url: coverURL, pixels: size.pixels)
            await gate.release(priority)

            if let decoded {
                // Written later and separately, through the background lane of
                // the same gate – which stands still while the user is working
                // the window, so encoding a cover never competes with showing one.
                //
                // `LoadPriority.background.taskPriority`, which is `.utility`,
                // and *not* `.background`: the system throttles `.background`
                // QoS hard, and a throttled task that holds one of the gate's
                // two background slots starves the warmer behind it. Measured
                // at 285 ms per cover instead of a few milliseconds – see
                // ADR 0005. This is the mistake `LoadPriority`'s own comment
                // warns about, made one line away from the warning.
                Task.detached(priority: LoadPriority.background.taskPriority) {
                    await gate.acquire(.background)
                    await diskCache.store(decoded, for: key)
                    await gate.release(.background)
                }
            }
            return decoded
        }
        inFlight[request] = task
        let decoded = await task.value
        // Only the task's own creator clears the entry; a newer request for the
        // same cover must not be dropped.
        if inFlight[request] == task { inFlight[request] = nil }
        if let decoded { cache(for: size).store(decoded, for: entry.id) }
        return decoded
    }

    private func cache(for size: CoverSize) -> Cache {
        size == .grid ? gridCovers : largeCovers
    }
}

/// An `NSCache` with a byte budget, so a library's covers cannot fill the
/// machine's memory.
private final class Cache {
    private let storage = NSCache<NSString, Entry>()
    /// What has been stored, so entries can be dropped on purpose rather than
    /// only when `NSCache` decides to. It may name entries the cache has already
    /// evicted; removing those is harmless.
    private var keys: Set<UUID> = []

    init(countLimit: Int, megabytes: Int) {
        storage.countLimit = countLimit
        storage.totalCostLimit = megabytes * 1_024 * 1_024
    }

    func image(for id: UUID) -> DecodedCover? {
        storage.object(forKey: id.uuidString as NSString)?.decoded
    }

    func store(_ decoded: DecodedCover, for id: UUID) {
        storage.setObject(Entry(decoded), forKey: id.uuidString as NSString, cost: decoded.byteSize)
        keys.insert(id)
    }

    /// Drops everything except `keep`.
    func removeAll(except keep: Set<UUID>) {
        for id in keys.subtracting(keep) { storage.removeObject(forKey: id.uuidString as NSString) }
        keys.formIntersection(keep)
    }

    /// `NSCache` needs a class; `DecodedCover` stays a value type.
    private final class Entry {
        let decoded: DecodedCover
        init(_ decoded: DecodedCover) { self.decoded = decoded }
    }
}
