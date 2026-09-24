import Foundation

/// Sending an entire book — its whole folder, every format it has — to the
/// Trash.
///
/// `FormatDisposal` removes one file and refuses when it would be the book's
/// last one, on purpose: it exists for a book that keeps several formats and
/// loses one, never for making a book disappear one file at a time. This type
/// is the other half — the deliberate, explicit command for taking a whole
/// book out of the library, which CLAUDE.md's own list of what may ever be
/// removed names narrowly (a duplicate that lost a merge, a file a merge
/// displaced, an encrypted KFX with a readable sibling, a stray "My
/// Clippings", a folder `Organize Library…` moves) — never a routine part of
/// looking at a book.
///
/// The whole folder goes through `FolderDisposal`, the same seam every other
/// disposal in this project uses — the Trash, never `removeItem` — and
/// `restore` verifies every file inside it by hash before trusting a move
/// back, the same way `FormatDisposal.restore` does for one file.
public enum BookDisposal {
    /// What removing a book turned out to do, and everything `restore` needs
    /// to undo it later.
    public struct Result: Equatable, Sendable {
        /// The entry exactly as it was before removal — every format's own
        /// `sha256` is what `restore` checks the Trash copy against.
        public var entry: LibraryEntry
        /// Where `FolderDisposal` itself says the folder landed. `nil` when
        /// the disposal used cannot say (a test double, most often).
        public var trashedAt: URL?
        /// The folder's path relative to the library root, before it moved.
        public var relativeFolder: String
    }

    public enum Refusal: Error, Equatable, Sendable {
        case cannotDispose(String)

        public var message: String {
            "The book's folder could not be moved to the Trash, so it was left where it was."
        }

        public var detail: String? {
            if case .cannotDispose(let why) = self { return why }
            return nil
        }
    }

    /// Moves a book's whole folder to the Trash.
    @discardableResult
    public static func remove(
        _ entry: LibraryEntry, library: Library, disposal: FolderDisposal = .trash
    ) throws -> Result {
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
        do {
            let trashedAt = try disposal.dispose(folder)
            return Result(entry: entry, trashedAt: trashedAt, relativeFolder: entry.folder)
        } catch {
            throw Refusal.cannotDispose(error.localizedDescription)
        }
    }

    public enum RestoreFailure: Error, Equatable, Sendable {
        case noTrashLocation
        case trashItemMissing
        /// One of the book's own files, inside the Trash copy, is not what it
        /// was — named, because a book can hold several and restoring only
        /// to find one of them wrong is worth saying which.
        case hashMismatch(fileName: String)
        case destinationOccupied
        case cannotMove(String)

        public var message: String {
            switch self {
            case .noTrashLocation:
                return "Shelf does not know where this book went, so it cannot bring it back on its own."
            case .trashItemMissing:
                return "The book is no longer in the Trash, so it cannot be brought back automatically."
            case .hashMismatch:
                return
                    "A file in the Trash has changed, so Shelf will not put the book back as if nothing had happened."
            case .destinationOccupied:
                return "Something is already at the book's old place, so it was not overwritten."
            case .cannotMove:
                return "The book could not be moved back."
            }
        }

        public var detail: String? {
            switch self {
            case .noTrashLocation, .trashItemMissing, .destinationOccupied: return nil
            case .hashMismatch(let fileName): return fileName
            case .cannotMove(let why): return why
            }
        }
    }

    /// Moves a removed book's folder back to exactly the path it came from,
    /// every one of its files verified by content first.
    @discardableResult
    public static func restore(
        _ result: Result, library: Library, makeHasher: HasherFactory
    ) throws -> URL {
        guard let trashedAt = result.trashedAt else { throw RestoreFailure.noTrashLocation }
        guard FileManager.default.fileExists(atPath: trashedAt.path) else {
            throw RestoreFailure.trashItemMissing
        }
        for format in result.entry.formats {
            let fileURL = trashedAt.appendingPathComponent(format.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw RestoreFailure.trashItemMissing
            }
            let digest: String
            do {
                digest = try FileDigest.sha256(of: fileURL, makeHasher: makeHasher)
            } catch {
                throw RestoreFailure.cannotMove(error.localizedDescription)
            }
            guard digest == format.sha256 else { throw RestoreFailure.hashMismatch(fileName: format.fileName) }
        }

        let destination = library.root.appendingPathComponent(result.relativeFolder, isDirectory: true)
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
