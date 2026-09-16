import Foundation

/// What a cached cover is *of*.
///
/// The key is the whole of the correctness argument for the disk cache: serving
/// yesterday's picture for today's book is the one failure a cache must never
/// have. Unlike Selector, which keys on a file's path, size and date, a book's
/// cover is keyed on the **book's UUID and the size asked for** – because the
/// cover belongs to the book, not to any one of its files, and a book keeps its
/// UUID when its files change (CONCEPT §5.1: "Schlüssel: Buch-UUID + Größe").
///
/// The generation number is what replaces size-and-date: it is bumped when the
/// cover is replaced, so an edited cover misses instead of matching something
/// stale.
public struct CoverCacheKey: Sendable, Equatable, Hashable {
    public var bookID: UUID
    /// The long edge in pixels that was *asked for*, not what came back. It has
    /// to be computable before anything is decoded, because that is when the
    /// cache is asked.
    public var pixelWidth: Int
    /// Raised whenever the book's cover file is replaced. Zero for a cover
    /// that has never been changed since import.
    public var generation: Int

    public init(bookID: UUID, pixelWidth: Int, generation: Int = 0) {
        self.bookID = bookID
        self.pixelWidth = pixelWidth
        self.generation = generation
    }

    /// The exact bytes that get hashed into the file name.
    ///
    /// Written out rather than composed from `description` or `hashValue`: both
    /// are free to change between Swift releases, and a changed fingerprint
    /// means every cached cover on every machine misses at once.
    public var fingerprint: String {
        "v1\n\(bookID.uuidString)\n\(pixelWidth)\n\(generation)"
    }

    /// File name inside the cache folder.
    ///
    /// The UUID is in the name in plain sight, not only in the digest: when
    /// something goes wrong with one book's cover, being able to find its file
    /// in the Finder is worth more than four saved characters.
    public func fileName(hashedBy hasher: any ContentHasher, extension ext: String) -> String {
        hasher.update(Data(fingerprint.utf8))
        return "\(bookID.uuidString)-\(pixelWidth)-\(hasher.finish().prefix(8)).\(ext)"
    }
}

/// The sizes a cover is cached at.
///
/// Two, not one per slider position: the grid's cover size is continuous, and a
/// cache with a file per pixel width would decode the whole library again every
/// time the slider moved. Each tier is decoded at its own size and drawn
/// scaled, which at these ratios is invisible.
public enum CoverSize: Int, CaseIterable, Sendable, Comparable {
    /// The grid at every size up to the tier's own width, and the table.
    case grid = 400
    /// The inspector, and the grid at its largest.
    case large = 1_000

    public var pixels: Int { rawValue }

    public static func < (lhs: CoverSize, rhs: CoverSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The tier to ask for when a cell is `points` wide on screen.
    ///
    /// The retina factor is in here rather than at the call site so there is
    /// one place that decides it: a 200 pt cell on a 2× display needs 400 px,
    /// which is exactly the grid tier.
    public static func forCell(points: CGFloat, scale: CGFloat = 2) -> CoverSize {
        Int(points * scale) <= CoverSize.grid.pixels ? .grid : .large
    }
}

/// How the cover cache folder is kept under its limit.
///
/// A pure decision over a list of facts, so the rule can be tested without a
/// disk: which files go, in which order, and when nothing goes at all.
/// Copied from Selector's `PreviewCachePolicy`, with a budget suited to covers.
public enum CoverCachePolicy {
    /// Nothing is thrown away below this.
    ///
    /// A grid-tier cover is ~40 KB and a large one ~250 KB, so 1 GB holds both
    /// tiers for roughly 3 500 books, and the grid tier alone for far more than
    /// any library this app is for. The cache lives *inside the library*
    /// (`.shelf/covers/`), so this budget is per library, not per machine.
    public static let defaultLimitBytes: Int64 = 1_024 * 1_024 * 1_024

    public struct Entry: Sendable, Equatable {
        public var fileName: String
        public var byteSize: Int64
        /// Last read, or written if never read since.
        public var lastUsed: Date

        public init(fileName: String, byteSize: Int64, lastUsed: Date) {
            self.fileName = fileName
            self.byteSize = byteSize
            self.lastUsed = lastUsed
        }
    }

    /// Which files to delete so the rest fits under `limitBytes`, oldest first.
    ///
    /// Deletes down to the limit and no further: a cache that trims itself to
    /// half whenever it is full spends the next session rebuilding what it just
    /// threw away.
    public static func evictions(from entries: [Entry], limitBytes: Int64 = defaultLimitBytes) -> [Entry] {
        let total = entries.reduce(Int64(0)) { $0 + max(0, $1.byteSize) }
        guard total > limitBytes else { return [] }

        // Oldest first, and by name where the timestamps tie, so two runs over
        // the same folder make the same decision.
        let byAge = entries.sorted {
            $0.lastUsed == $1.lastUsed ? $0.fileName < $1.fileName : $0.lastUsed < $1.lastUsed
        }
        var freed: Int64 = 0
        var doomed: [Entry] = []
        for entry in byAge {
            guard total - freed > limitBytes else { break }
            doomed.append(entry)
            freed += max(0, entry.byteSize)
        }
        return doomed
    }

    /// "412 MB of 1 GB" for the menu item, so clearing the cache is a decision
    /// with a number behind it rather than a button that does something vague.
    public static func sizeLabel(usedBytes: Int64, limitBytes: Int64 = defaultLimitBytes) -> String {
        "\(ByteCount.format(usedBytes)) of \(ByteCount.format(limitBytes))"
    }
}
