import Foundation

/// A `metadata.opf` already sitting beside a book file being imported for
/// the **first** time — never a book already in a Shelf library, which
/// `IndexRebuilder.readFolder` handles on its own.
///
/// **The bug this exists to fix, found asking rather than assumed
/// (Sprint 21, Teil B4):** `ImportModel.candidate(for:)` read a book's
/// metadata only from the file itself (`FileReader`) — never from a
/// `metadata.opf` Calibre, or an earlier Shelf, had already written beside
/// it. `IndexRebuilder.readFolder` already treats that OPF as the authority
/// for a folder already *in* the library (CONCEPT §5.3: "the OPF is the
/// authority: it carries the UUID, and the UUID is the book's identity
/// across a rebuild"); a fresh import silently threw the same file away and
/// re-derived every field from the book alone. Sprint 16's own "plain
/// folder" batch (65 books, `docs/HANDOFF.md`) came from exactly such a
/// folder — a Calibre-style tree without `metadata.db` reachable, each book
/// carrying its own `metadata.opf` that the import never looked at.
public enum SidecarOPF {
    /// The book a `metadata.opf` beside `fileURL` describes, or `nil` when
    /// there is none or it cannot be read — in which case the caller keeps
    /// whatever the book file itself said, exactly as before this existed.
    public static func book(besideFile fileURL: URL, fallbackTitle: String) -> Book? {
        let opfURL = fileURL.deletingLastPathComponent().appendingPathComponent(OPFDocument.fileName)
        guard let data = try? Data(contentsOf: opfURL),
            let parsed = try? OPFDocument.read(data, fallbackTitle: fallbackTitle)
        else { return nil }
        return parsed.book
    }
}
