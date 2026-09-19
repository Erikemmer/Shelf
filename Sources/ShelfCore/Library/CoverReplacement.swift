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
        /// The files that were displaced, in the order `CoverFile` prefers
        /// them, and empty when the book had no cover.
        ///
        /// A list and not one name, because a folder can hold more than one:
        /// `cover.jpg` beside `cover.jpeg` is ordinary in a Calibre folder
        /// that has grown over years, and leaving the second behind is worse
        /// than leaving both — the surviving one is found *in preference to*
        /// the picture that was just written.
        ///
        /// *Names*, because by the time anybody reads this the files are in
        /// the Trash and their URLs are no longer where they were.
        public var displaced: [String]
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
        sweepPartials(in: folder)
        let existing = CoverFile.urls(in: folder)
        guard !existing.isEmpty else {
            return Result(written: nil, displaced: [], generation: previousGeneration)
        }
        var displaced: [String] = []
        for cover in existing {
            do {
                try disposal.dispose(cover)
                displaced.append(cover.lastPathComponent)
            } catch {
                throw Refusal.cannotDisplace(error.localizedDescription)
            }
        }
        return Result(written: nil, displaced: displaced, generation: previousGeneration + 1)
    }

    /// The prefix every half-written cover carries.
    ///
    /// Named, and swept, for the reason `ImportRunner.partialPrefix` and
    /// `ExportRunner.partialPrefix` are: nothing else in Shelf would ever take
    /// one away. `CoverFile.isCover` says a `.part` is not a cover, so
    /// `EmptiedFolder` counts it as somebody's data and keeps an author folder
    /// alive for ever, and `OrphanedFolders` adds its bytes to a folder it
    /// reports — a file Shelf dropped, reported back to the user as a file
    /// Shelf found.
    public static let partialPrefix = ".shelf-cover-"

    /// Whether these bytes could be a cover at all.
    ///
    /// Asked by the window **before** it writes anything, including before it
    /// writes the new generation into `metadata.opf`, so that bytes which were
    /// never a picture cost nothing at all. The same question `replace` asks
    /// first; here so a caller can ask it without a folder.
    public static func accepts(_ data: Data) -> Bool {
        CoverFile.fileExtension(for: data) != nil
    }

    /// Removes this folder's half-written covers, if an earlier run left any.
    ///
    /// Not through the disposal: this is Shelf's own debris and never was
    /// anybody's picture. The Trash is for what a person might want back.
    private static func sweepPartials(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(partialPrefix) && name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
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
        guard accepts(data) else { throw Refusal.notAnImage }
        sweepPartials(in: folder)

        let target = folder.appendingPathComponent(CoverFile.name(for: data))
        let part = folder.appendingPathComponent("\(partialPrefix)\(UUID().uuidString.prefix(8)).part")
        do {
            try data.write(to: part, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.cannotWrite(error.localizedDescription)
        }

        // **Every** cover, not the first one found. A surviving `cover.jpeg`
        // beside a freshly written `cover.png` is drawn in preference to it.
        var displaced: [String] = []
        for existing in CoverFile.urls(in: folder) {
            do {
                try disposal.dispose(existing)
                displaced.append(existing.lastPathComponent)
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

extension CoverReplacement {
    /// What a commit turned out to do: the entry as it now is, or the refusal
    /// that stopped it.
    public enum Commit {
        case wrote(LibraryEntry)
        case refused(Refusal)
    }

    /// The whole two-write protocol behind changing a cover: the generation
    /// through `MetadataEditor`, then the picture through `replace`/`remove`
    /// above — with the generation put back if the picture write fails.
    ///
    /// This is `LibraryModel.applyCover`'s core, pulled out here rather than
    /// left in the app layer, for the reason every other rule in `ShelfCore`
    /// is here: it is the only way this exact sequence — bump, write picture,
    /// revert on failure — can be driven by a test. `LibraryModel` has no test
    /// target of its own (`docs/BACKLOG.md`); this does, because it needs
    /// nothing AppKit has.
    ///
    /// ## Why the generation is written before the picture
    ///
    /// A cover change is two writes and one of them can fail. The two orders
    /// are not symmetrical:
    ///
    /// - **Picture first.** The new picture is on disk and the book still
    ///   claims the old generation, so the cache *hits* on the thumbnail of
    ///   the old one. The window draws a picture that is no longer there, and
    ///   `Rebuild Index from Folders` brings it back rather than clearing it —
    ///   precisely the failure `coverGeneration` exists to prevent.
    /// - **Number first.** The book claims a generation for a picture that has
    ///   not arrived, so the cache *misses*, decodes the file that is actually
    ///   there and caches it under the new key. The window is correct. It
    ///   costs one decode of an unchanged cover, and nothing else.
    ///
    /// ## Why a failed picture write undoes the generation
    ///
    /// If the picture write then fails, doing nothing further would leave the
    /// book claiming a generation for a replacement that never happened — a
    /// small, permanent lie in `metadata.opf`, whose whole reason for existing
    /// is to be the truth (ADR 0001). So this writes the generation back down
    /// with a second `MetadataEditor` call. That second write can fail too —
    /// nothing makes it safer than the first — and if it does, its error is
    /// what `commit` throws, not the refusal that caused it: at that point
    /// there are two problems, and the caller has to know about the one nobody
    /// can fix by trying again. The window is never at risk either way: a
    /// generation that moved for nothing only costs the one decode above.
    @discardableResult
    public static func commit(
        _ bytes: Data?, to entry: LibraryEntry, library: Library, index: LibraryIndex,
        disposal: FolderDisposal = .trash
    ) async throws -> Commit {
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
        let editor = MetadataEditor(library: library)
        let generation = entry.book.coverGeneration + 1
        let bump = MetadataChange.make(from: entry.book) { $0.coverGeneration = generation }
        let bumped = try await editor.apply(bump, to: entry, in: index)

        do {
            if let bytes {
                try replace(with: bytes, in: folder, previousGeneration: entry.book.coverGeneration, disposal: disposal)
            } else {
                try remove(in: folder, previousGeneration: entry.book.coverGeneration, disposal: disposal)
            }
        } catch let refusal as Refusal {
            let revert = MetadataChange.make(from: bumped.book) { $0.coverGeneration = entry.book.coverGeneration }
            try await editor.apply(revert, to: bumped, in: index)
            return .refused(refusal)
        }
        return .wrote(bumped)
    }
}
