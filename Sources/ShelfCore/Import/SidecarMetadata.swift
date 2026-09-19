import Foundation

/// A `metadata.opf` lying beside a book file, and whether to believe it.
///
/// Without this, an export is a one-way door. Shelf keeps the rating, the read
/// status, the tags and the shelves **only** in each book's `metadata.opf`
/// (CONCEPT §5.1) — never inside the book file, which is never written. So an
/// import that reads metadata out of the EPUB and ignores the OPF next to it
/// throws away exactly the work the library was for, and "Archive: can be
/// imported back with nothing lost" would be a sentence with nothing behind it.
///
/// It is also what makes an import of somebody else's Calibre *folder* — one
/// with no `metadata.db` to read — carry its ratings and series across.
///
/// **The identity comes from the OPF too.** `dc:identifier opf:scheme="uuid"`
/// is what makes a re-import reconstruct a library rather than reinvent it
/// (CONCEPT §5.3): the same books come back with the same ids, so a second
/// import of the same folder skips them instead of doubling them.
public enum SidecarMetadata {

    /// The OPF to believe for this book file, if there is one.
    ///
    /// Two shapes, because an export can be written in two:
    ///
    /// * `<stem>.opf` beside `<stem>.epub` — unambiguous, one file describing
    ///   one file, which is what a flat export writes.
    /// * `metadata.opf` in the folder — the library's own shape, and Calibre's.
    ///   Believed **only when the folder is a book's folder**: see
    ///   `describesTheFolder`.
    public static func url(for book: URL, in folder: URL, siblings: [URL]) -> URL? {
        let stem = book.deletingPathExtension().lastPathComponent
        let named = folder.appendingPathComponent("\(stem).opf")
        if FileManager.default.fileExists(atPath: named.path) { return named }

        let shared = folder.appendingPathComponent(OPFDocument.fileName)
        guard FileManager.default.fileExists(atPath: shared.path),
            describesTheFolder(siblings)
        else { return nil }
        return shared
    }

    /// Whether one `metadata.opf` can speak for every book file in this folder.
    ///
    /// It can when they are **different formats of one book** — `Emma.epub`
    /// and `Emma.azw3`, which is precisely what a book's folder holds here and
    /// in Calibre. It cannot when two of them are the same format, because
    /// then the folder is a pile rather than a book, and believing the OPF
    /// would give fifty books one UUID and fold them into a single book with
    /// fifty formats.
    ///
    /// Format rather than file name, because `Emma.epub` and `Emma (2).epub`
    /// are two books whatever their stems suggest, and because a book's two
    /// files are named alike by everything that writes them.
    static func describesTheFolder(_ siblings: [URL]) -> Bool {
        let formats = siblings.compactMap { BookFileFormat.of($0) }
        return !formats.isEmpty && Set(formats).count == formats.count
    }

    /// The book the sidecar describes.
    ///
    /// **The sidecar wins outright**, and the only thing taken from the file is
    /// a title when the OPF has none at all — because a book with no title is
    /// unusable and every other field can sensibly be empty.
    ///
    /// Filling the OPF's gaps from the file was tried first and is wrong, and
    /// the proof run is what showed it. A book with **no author** has an OPF
    /// that says so by saying nothing; treating that as "the OPF did not
    /// mention it" let the file's own guess through, and the file's guess came
    /// from its *name* — which the export had just written from the very
    /// metadata being reconstructed. One book came back with its title as its
    /// author. An empty field in a record is a statement, not a silence.
    ///
    /// What this costs: a hand-written, sparse OPF beside a richly tagged EPUB
    /// loses the EPUB's extras. That is the right way round. A `metadata.opf`
    /// is a deliberate record — Shelf writes one, Calibre writes one — and
    /// both write it complete. A program that second-guesses the record cannot
    /// round-trip, and round-tripping is the entire purpose of the export.
    public static func merged(_ sidecar: OPFDocument.Parsed, over fromFile: Book) -> Book {
        var book = sidecar.book
        if book.title.isEmpty { book.title = fromFile.title }
        return book
    }

    /// Reads it, or `nil` — a sidecar that will not parse is not a reason to
    /// refuse a book, it is a reason to fall back to the file (ADR 0002,
    /// decision 11).
    public static func read(at url: URL) -> OPFDocument.Parsed? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? OPFDocument.read(data, fallbackTitle: "")
    }
}
