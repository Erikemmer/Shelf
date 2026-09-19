import Foundation

/// Putting a different picture beside a book.
///
/// Until Sprint 9 a cover arrived twice and both times only once: at import,
/// out of the book file, and from the net when the folder had none. Changing
/// one was the most obvious hole in the program — a library manager whose
/// covers cannot be corrected is a catalogue of whatever the files happened to
/// carry.
///
/// **What this type is careful about** is the pair of mistakes a picture on
/// disk can make:
///
/// - The old file being *gone* rather than recoverable. A cover is often
///   somebody's own scan, and it is replaced by a person who may be wrong
///   about which book they had selected. So it goes through `FolderDisposal` —
///   the Trash on a Mac — and a disposal that cannot take it means nothing is
///   written at all. Overwriting it is the one thing Shelf does not do.
/// - The new file being *there* while the window draws the old one. The cover
///   cache is keyed by UUID, size and generation (ADR 0005, decision 4), and
///   the generation is the only part of that key a replaced cover can move.
///   So the generation is part of this type's answer and not an afterthought
///   for the caller to remember.
///
/// The book file is not opened, not read and not written. Nothing here knows
/// how to decode an image either: the bytes arrive already decided on, and the
/// only question asked of them is the magic number `CoverFile` reads — the
/// core has no image code and must not grow any (CONCEPT §10).
public enum CoverReplacement {

    /// What a replacement turned out to have done.
    public struct Result: Equatable, Sendable {
        /// Where the new picture went. Its extension comes from the bytes, so
        /// it is not necessarily the name the old one had. Nil when the cover
        /// was taken away rather than replaced.
        public var written: URL?
        /// The file that was displaced, or nil when the book had no cover.
        /// A *name*, because by the time anybody reads this the file is in the
        /// Trash and its URL is no longer where it was.
        public var displaced: String?
        /// What the book's `coverGeneration` becomes. The caller writes it into
        /// the book; this type does not touch `metadata.opf`.
        public var generation: Int
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// The magic number is not one `CoverFile` knows. Checked first, so a
        /// book cannot lose its picture to a file that was never one.
        case notAnImage
        /// The cover that was there could not be moved out of the way. The old
        /// file is still exactly where it was.
        case cannotDisplace(String)
        case cannotWrite(String)

        /// The sentence, with **no system text interpolated into it**, so it
        /// is one catalogue key rather than one per error the file system can
        /// have. `NameMerge.refusal` is the pattern; what the system itself
        /// said is `detail`, which macOS has already put in the reader's
        /// language.
        public var message: String {
            switch self {
            case .notAnImage:
                return "That is not an image Shelf recognises, so nothing was written."
            case .cannotDisplace:
                return "The cover that is there could not be moved to the Trash, "
                    + "so it was left alone and nothing was replaced."
            case .cannotWrite:
                return "The cover could not be written, so the book still has the one it had."
            }
        }

        /// What the file system said, shown under the sentence rather than
        /// inside it. Never the whole answer on its own: "No such file or
        /// directory" tells a reader nothing about what Shelf was trying to do.
        public var detail: String? {
            switch self {
            case .notAnImage: return nil
            case .cannotDisplace(let why), .cannotWrite(let why): return why
            }
        }
    }

    /// Takes the cover away, leaving the folder with none.
    ///
    /// **Not a menu item — this is what undo needs.** Setting the first cover
    /// on a book that had none has to be undoable, and the only honest undo of
    /// that is a folder with no cover in it again.
    ///
    /// A book that had no cover to begin with is left entirely alone, and the
    /// generation does not move: nothing was written, so no cached thumbnail
    /// has gone stale, and bumping it would throw away a perfectly good
    /// placeholder for nothing.
    @discardableResult
    public static func remove(
        in folder: URL, previousGeneration: Int, disposal: FolderDisposal = .trash
    ) throws -> Result {
        guard let existing = CoverFile.url(in: folder) else {
            return Result(written: nil, displaced: nil, generation: previousGeneration)
        }
        do {
            try disposal.dispose(existing)
        } catch {
            throw Refusal.cannotDisplace(error.localizedDescription)
        }
        return Result(
            written: nil, displaced: existing.lastPathComponent, generation: previousGeneration + 1)
    }

    /// Writes these bytes as the book's cover, displacing whatever was there.
    ///
    /// The order is the one every other write in Shelf uses, for the reason
    /// `copyAndVerify` uses it: the new file is complete on disk **before**
    /// anything is taken away, so a full disk or a crash between the two steps
    /// leaves the book with the cover it already had rather than with none.
    @discardableResult
    public static func replace(
        with data: Data, in folder: URL, previousGeneration: Int,
        disposal: FolderDisposal = .trash
    ) throws -> Result {
        guard CoverFile.fileExtension(for: data) != nil else { throw Refusal.notAnImage }

        let target = folder.appendingPathComponent(CoverFile.name(for: data))
        let part = folder.appendingPathComponent(".\(CoverFile.baseName)-\(UUID().uuidString.prefix(8)).part")
        do {
            try data.write(to: part, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.cannotWrite(error.localizedDescription)
        }

        var displaced: String?
        if let existing = CoverFile.url(in: folder) {
            do {
                try disposal.dispose(existing)
                displaced = existing.lastPathComponent
            } catch {
                try? FileManager.default.removeItem(at: part)
                throw Refusal.cannotDisplace(error.localizedDescription)
            }
        }

        do {
            try FileManager.default.moveItem(at: part, to: target)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.cannotWrite(error.localizedDescription)
        }
        return Result(written: target, displaced: displaced, generation: previousGeneration + 1)
    }
}
