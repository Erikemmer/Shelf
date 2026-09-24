import Foundation

/// Sending one of a book's format files to the Trash, keeping the book.
///
/// The book's folder can hold several files of the same work — a KFX beside
/// an EPUB, a MOBI a Calibre import left over. Removing one of them is not
/// "removing the book" and needs its own narrow command, distinct from
/// `Organize`'s folder moves and from `EPUBFileReplacement`'s in-place swap of
/// a book's own content: this type only ever moves one whole, unmodified file
/// out of a folder, never opens it and never writes a new one in its place.
///
/// **The book must keep at least one file.** A book with none left is not a
/// book Shelf can show a cover, a format line or an inspector row for, so the
/// command that would leave zero is refused before anything is touched
/// (CONCEPT §4, "Won't"; ADR 0018's own "a preview that is the plan" —
/// refusing early is part of the plan, not a separate check).
///
/// **The Trash, never `removeItem`** — the same rule as `FolderDisposal`
/// everywhere else in this project. Unlike `EPUBFileReplacement`, which
/// deliberately answers "no ⌘Z, look in the Trash yourself" because it swaps
/// a book's own content for new content at the same path, this type only ever
/// *removes* a file and puts nothing in its place — so the file's own
/// pre-removal path stays free, and a hash-verified move back out of the
/// Trash is both simple and honest. `restore` is that move back; it is not
/// automatic and not silent — a caller decides whether to offer it, the same
/// way `EPUBFileReplacement`'s doc comment reasons about why its own answer
/// differs.
public enum FormatDisposal {
    /// What removing one format turned out to do, and everything `restore`
    /// needs to undo it later without re-deriving anything from a book that
    /// may itself have changed since.
    public struct Result: Equatable, Sendable {
        /// The format row exactly as it was before removal — its `sha256` is
        /// what `restore` checks the Trash copy against.
        public var format: BookFormat
        /// Where `FolderDisposal` itself says the file landed. `nil` when the
        /// disposal used cannot say (a test double, most often) — `restore`
        /// then has nothing to go on and refuses honestly rather than
        /// guessing at a Trash path.
        public var trashedAt: URL?
        /// The file's path relative to the library root, before it moved —
        /// where `restore` puts it back.
        public var relativePath: String
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// This is the book's only file. Checked first, before `disposal` is
        /// ever asked to do anything.
        case lastFormat
        case cannotDispose(String)

        /// One catalogue key rather than one per error the file system can
        /// have — the pattern every other refusal type in this project uses.
        public var message: String {
            switch self {
            case .lastFormat:
                return "This is the book's only file, so it cannot be sent to the Trash."
            case .cannotDispose:
                return "The file could not be moved to the Trash, so it was left where it was."
            }
        }

        public var detail: String? {
            switch self {
            case .lastFormat: return nil
            case .cannotDispose(let why): return why
            }
        }
    }

    /// Moves one of `entry`'s files to the Trash. Refuses, untouched, if it
    /// is the only one the book has.
    @discardableResult
    public static func remove(
        _ format: BookFormat, from entry: LibraryEntry, library: Library,
        disposal: FolderDisposal = .trash
    ) throws -> Result {
        guard entry.formats.count > 1 else { throw Refusal.lastFormat }
        let relativePath = "\(entry.folder)/\(format.fileName)"
        let url = library.root.appendingPathComponent(relativePath)
        do {
            let trashedAt = try disposal.dispose(url)
            return Result(format: format, trashedAt: trashedAt, relativePath: relativePath)
        } catch {
            throw Refusal.cannotDispose(error.localizedDescription)
        }
    }

    public enum RestoreFailure: Error, Equatable, Sendable {
        /// `disposal` could not say where the file went (a test double, or a
        /// disposal that never learned the destination) — nothing to restore
        /// from, said plainly rather than guessed at.
        case noTrashLocation
        /// Gone from the Trash since — emptied, or dragged out and moved
        /// somewhere else by a person.
        case trashItemMissing
        /// What is in the Trash is not, byte for byte, what was removed.
        /// Restoring it anyway would put back something that only looks
        /// right — the same reason a merge or an organise hashes before
        /// trusting a move (ADR 0002).
        case hashMismatch
        /// Something is already at the file's old path. Never overwritten —
        /// that would be exactly the accidental write CLAUDE.md forbids.
        case destinationOccupied
        case cannotMove(String)

        public var message: String {
            switch self {
            case .noTrashLocation:
                return "Shelf does not know where this file went, so it cannot bring it back on its own."
            case .trashItemMissing:
                return "The file is no longer in the Trash, so it cannot be brought back automatically."
            case .hashMismatch:
                return "The file in the Trash has changed, so Shelf will not put it back as if nothing had happened."
            case .destinationOccupied:
                return "Something is already at the file's old place, so it was not overwritten."
            case .cannotMove:
                return "The file could not be moved back."
            }
        }

        public var detail: String? {
            switch self {
            case .noTrashLocation, .trashItemMissing, .hashMismatch, .destinationOccupied: return nil
            case .cannotMove(let why): return why
            }
        }
    }

    /// Moves a removed file back from the Trash to exactly the path it came
    /// from, verified by content first. This is the whole of "undo" this type
    /// offers — no in-memory copy is kept, because a book's own format file
    /// can be tens of megabytes and `remove` may be called on many books in
    /// one sitting.
    @discardableResult
    public static func restore(
        _ result: Result, library: Library, makeHasher: HasherFactory
    ) throws -> URL {
        guard let trashedAt = result.trashedAt else { throw RestoreFailure.noTrashLocation }
        guard FileManager.default.fileExists(atPath: trashedAt.path) else {
            throw RestoreFailure.trashItemMissing
        }
        let digest: String
        do {
            digest = try FileDigest.sha256(of: trashedAt, makeHasher: makeHasher)
        } catch {
            throw RestoreFailure.cannotMove(error.localizedDescription)
        }
        guard digest == result.format.sha256 else { throw RestoreFailure.hashMismatch }

        let destination = library.root.appendingPathComponent(result.relativePath)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw RestoreFailure.destinationOccupied
        }
        do {
            try FileManager.default.moveItem(at: trashedAt, to: destination)
        } catch {
            throw RestoreFailure.cannotMove(error.localizedDescription)
        }
        return destination
    }
}
