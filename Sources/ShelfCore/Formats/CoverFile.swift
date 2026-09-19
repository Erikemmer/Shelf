import Foundation

/// The cover image next to a book, on disk.
///
/// One place decides what it is called and how it is found, because two places
/// would eventually disagree and a book would show no cover while its cover sat
/// right there.
///
/// The name is `cover.<ext>` where the extension comes from the **bytes**, not
/// from whatever the EPUB called the file inside itself. An EPUB that declares
/// `image/jpeg` and stores a PNG is common, and a PNG written as `cover.jpg`
/// works with ImageIO but confuses every other tool, the Finder's preview and
/// the person looking at the folder.
public enum CoverFile {
    /// The base name, without extension. Calibre's, so a library stays
    /// recognisable to it.
    public static let baseName = "cover"

    /// The extensions a cover may have, in the order they are looked for.
    /// JPEG first because it is by far the most common.
    public static let extensions = ["jpg", "jpeg", "png", "gif", "webp", "avif"]

    /// What to call a cover with these bytes.
    ///
    /// Sniffed from the file's own first bytes. Unknown content is still
    /// written – a cover Shelf cannot name is better kept than dropped – under
    /// `.jpg`, which is what ImageIO will try first anyway.
    public static func name(for data: Data) -> String {
        "\(baseName).\(fileExtension(for: data) ?? "jpg")"
    }

    /// The extension for these bytes, or nil when the magic number is not one
    /// this list knows.
    ///
    /// Magic numbers rather than a decoder: the core has no image code and must
    /// not grow any, and the first eight bytes are enough to tell these formats
    /// apart with certainty.
    public static func fileExtension(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 12 else { return nil }

        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "gif" }
        // RIFF....WEBP – the size sits between the two markers.
        if bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "webp" }
        // ....ftypavif – an ISO container whose brand says AVIF.
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8), Array(bytes[8..<12]) == Array("avif".utf8) {
            return "avif"
        }
        return nil
    }

    /// The cover in a book's folder, whatever its extension.
    ///
    /// The *first* of `extensions` that is there, which is what every reader
    /// in Shelf draws. When a folder holds two — see `urls(in:)` — this is the
    /// one that wins, and that is exactly why replacing a cover must not stop
    /// at it.
    ///
    /// Stops at the first hit, and that is not an optimisation to be tidied
    /// away: `booksWithACover` calls this once per book, and its measurement —
    /// 37 ms for 4 996 folders — is a measurement of one or two `stat` calls,
    /// not of six.
    public static func url(in folder: URL) -> URL? {
        for ext in extensions {
            let candidate = folder.appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// **Every** cover in a book's folder, in the order `url(in:)` prefers.
    ///
    /// Usually none or one. A folder that has been through several programs
    /// can hold `cover.jpg` and `cover.jpeg` side by side — Calibre folders
    /// that have grown over years do — and anything that *replaces* a cover
    /// has to take them all away. Displacing only the first is worse than
    /// displacing none: `jpeg` comes before `png` in this list, so a surviving
    /// `cover.jpeg` is then found in preference to the picture that was just
    /// written, and the window shows the old one while the disk says it was
    /// replaced.
    ///
    /// Six `stat` calls, always. Only the replace path asks, and it asks once
    /// for one book — never the per-book question `url(in:)` answers.
    public static func urls(in folder: URL) -> [URL] {
        extensions
            .map { folder.appendingPathComponent("\(baseName).\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether a file name is a cover rather than part of the book.
    public static func isCover(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return extensions.contains { lower == "\(baseName).\($0)" }
    }

    /// Which of these books have a cover file sitting next to them.
    ///
    /// **This is a question about the folders, not about the cover cache**, and
    /// the difference is a defect that was in `docs/BACKLOG.md` for four
    /// sprints: `Missing Cover` was answered from the decoded-cover cache, one
    /// directory read, which is cheap and which is empty until something has
    /// been drawn. A freshly imported library therefore reported **every** book
    /// as missing a cover and then corrected itself as the grid filled in —
    /// wrong, and then quietly right, which is worse than wrong.
    ///
    /// Measured on 19 September 2026 against the library the accessibility run
    /// uses: 26 books, of which 15 have a cover. The old answer read 26 on a
    /// cold cache and 15 once the grid had been looked at.
    ///
    /// One or two `stat` calls per book — `jpg` first, because that is what
    /// nearly every cover is, and the loop stops at the first hit. Measured
    /// over the closing run's library: **37 ms for 4 996 folders**, off the
    /// main actor, and asked only when the answer can have changed for more
    /// than one book at once.
    public static func booksWithACover(in root: URL, entries: [LibraryEntry]) -> Set<UUID> {
        var found: Set<UUID> = []
        for entry in entries {
            let folder = root.appendingPathComponent(entry.folder, isDirectory: true)
            if url(in: folder) != nil { found.insert(entry.id) }
        }
        return found
    }
}
