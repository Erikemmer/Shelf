import Foundation

/// Writing a book's own EPUB file — the rule that a book file is never
/// written falls here, for the first time, and falls in a controlled way.
///
/// `docs/adr/0021-…` is the decision; this is where it becomes code. Every
/// step below can refuse on its own, and a refusal at any step leaves the
/// original file exactly as it was — no `.part`, no half-result, nothing
/// changed but what the step that failed was trying to change.
///
/// **No ⌘Z.** The Trash is the way back, exactly as it is for a replaced
/// cover (`CoverReplacement`, ADR 0020): the original goes there, not to
/// `removeItem`, and a person can drag it out. Undo is not built on top of
/// that Trash the way a cover's is — two different answers to ⌘Z for two
/// different kinds of file change (a small picture kept in memory, a whole
/// book kept nowhere) would be worse than one consistent answer for both:
/// look in the Trash.
///
/// **Sequential, never concurrent, across several books.** A caller
/// replacing many books' files in one go does them one at a time. At
/// 24 MB and 187 entries per book (a real, illustrated EPUB — the size
/// that matters, `CHANGELOG.md`), the peak memory this costs is one book's,
/// not the whole batch's.
public enum EPUBFileReplacement {
    public struct Result: Equatable, Sendable {
        /// Where the new file ended up — the same path the original had.
        public var written: URL
        /// The original file's name, for a report to name — by the time
        /// anybody reads this it is in the Trash and its URL is no longer
        /// where it was.
        public var displacedOriginal: String
        /// The format row this book's index entry should be given in place
        /// of its old one: same `bookID`, same `fileName`, same `format`
        /// (`.epub`) — new `byteSize`, `sha256` and `modifiedAt`, freshly
        /// read off the file that is now actually there.
        public var format: BookFormat
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// The file is not named `.epub`, or is not readable as one at all —
        /// checked before anything else, so a wrong file never gets this far.
        case notAnEPUB
        /// `META-INF/encryption.xml` is present. Refused in the core, before
        /// the file is even opened for writing — not a check a window has to
        /// remember to add (CONCEPT §12).
        case drmProtected
        /// The volume the book's folder is on will not take a write. Found
        /// before anything is attempted, not discovered halfway through one.
        case readOnlyVolume(String)
        case cannotWrite(String)
        /// The new file was written, but reopening it with Shelf's own
        /// reader did not give back the title, the author or the cover the
        /// caller expected, or the archive itself would not read. The
        /// original is untouched; the `.part` is swept away.
        case readBackFailed(String)
        /// The original could not be moved to the Trash. The new file is
        /// swept away and the original is left exactly where it was.
        case cannotDisplace(String)

        /// The sentence, with no system text interpolated into it — one
        /// catalogue key rather than one per error the file system can have.
        public var message: String {
            switch self {
            case .notAnEPUB:
                return "That is not a readable EPUB, so nothing was written."
            case .drmProtected:
                return "This book is protected, so Shelf will not write into its file."
            case .readOnlyVolume(let volume):
                return "“\(volume)” cannot be written to, so nothing was changed."
            case .cannotWrite:
                return "The new file could not be written, so the book still has the one it had."
            case .readBackFailed:
                return "The new file did not read back correctly, so it was discarded and nothing changed."
            case .cannotDisplace:
                return "The original file could not be moved to the Trash, so nothing was replaced."
            }
        }

        /// What the file system or the reader said, shown under the
        /// sentence rather than folded into it.
        public var detail: String? {
            switch self {
            case .notAnEPUB, .drmProtected: return nil
            case .readOnlyVolume: return nil
            case .cannotWrite(let why), .readBackFailed(let why), .cannotDisplace(let why): return why
            }
        }
    }

    /// The prefix every half-written book file carries, so an interrupted
    /// run's debris is never mistaken for a book and is swept before the
    /// next attempt — the same reason `ImportRunner.partialPrefix`,
    /// `ExportRunner.partialPrefix` and `CoverReplacement.partialPrefix`
    /// are each named and swept.
    public static let partialPrefix = ".shelf-epub-write-"

    // MARK: Preflight

    /// Everything that can be decided before a single byte is written:
    /// is this a readable EPUB, is it free of DRM, and can its folder
    /// actually be written to. Called on its own so a caller can show a
    /// refusal before doing any of the work `replace` would otherwise do
    /// and then have to undo.
    public static func preflight(_ url: URL) throws {
        guard BookFileFormat.of(url) == .epub, let archive = try? ZipReader(url: url) else {
            throw Refusal.notAnEPUB
        }
        guard archive.entry(at: EPUBMetadata.encryptionPath) == nil else {
            throw Refusal.drmProtected
        }
        let folder = url.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Refusal.readOnlyVolume(Self.volumeName(of: folder))
        }
    }

    /// The volume's own display name, for the refusal to name — `folder`
    /// itself when the name cannot be read, which still says something
    /// rather than nothing.
    private static func volumeName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.path
    }

    // MARK: Writing

    /// Replaces the EPUB at `url` with `newContent`, in place — same path,
    /// same name, different bytes.
    ///
    /// The order is the one every other write in Shelf uses, for the reason
    /// `CoverReplacement.replace` and `copyAndVerify` use it: the new file is
    /// complete and proven **before** anything is taken away, so a failure at
    /// any point leaves the book with the file it already had.
    ///
    /// 1. Preflight — see above.
    /// 2. `newContent` is written under a `.part` name, in the same folder.
    /// 3. **Read back with Shelf's own reader.** The title, the author and
    ///    the cover it names all have to come back, and the archive itself
    ///    has to parse — `EPUBMetadata.read`, the same reader an import
    ///    uses. Only once this passes does the new file count for anything.
    /// 4. The bytes on disk are hashed and checked against `newContent`'s own
    ///    hash — the same "copy, verify, then trust" ADR 0002 already asks
    ///    of everything else that lands on disk, applied to a file that was
    ///    generated rather than copied.
    /// 5. The original is moved to the Trash, through `FolderDisposal`.
    ///    A disposal that cannot take it means the `.part` is swept and
    ///    nothing about the original changes.
    /// 6. The `.part` is moved to the exact path the original had.
    @discardableResult
    public static func replace(
        with newContent: Data, at url: URL, bookID: UUID, disposal: FolderDisposal = .trash,
        makeHasher: HasherFactory = PortableSHA256Hasher.factory
    ) throws -> Result {
        try preflight(url)
        // What the original had, so the read-back below can ask for the
        // same shape of book back rather than merely "something parsed" —
        // an EPUB with a title and no author is ordinary; one that had an
        // author and comes back without one is a book that lost data.
        let before = try EPUBMetadata.read(url: url)

        let folder = url.deletingLastPathComponent()
        sweepPartials(in: folder)
        let part = folder.appendingPathComponent("\(partialPrefix)\(UUID().uuidString.prefix(8)).part")
        do {
            try newContent.write(to: part, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.cannotWrite(error.localizedDescription)
        }

        do {
            try Self.verifyReadBack(part, expecting: before)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.readBackFailed(String(describing: error))
        }

        let expectedDigest = FileDigest.sha256(of: newContent, makeHasher: makeHasher)
        guard let writtenDigest = try? FileDigest.sha256(of: part, makeHasher: makeHasher),
            writtenDigest == expectedDigest
        else {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.readBackFailed("the written file's own hash did not match what was written")
        }

        let originalName = url.lastPathComponent
        do {
            try disposal.dispose(url)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.cannotDisplace(error.localizedDescription)
        }

        do {
            try FileManager.default.moveItem(at: part, to: url)
        } catch {
            // The original is already gone to the Trash at this point – it
            // can be dragged back, but it is not where it was. Named in the
            // failure rather than pretended away: this is the one step in
            // the whole sequence that is not fully reversible by retrying,
            // because there is no third place to put the new bytes.
            throw Refusal.cannotWrite(error.localizedDescription)
        }

        let facts = FileFacts.of(url)
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: originalName,
            byteSize: facts?.byteSize ?? Int64(newContent.count), sha256: writtenDigest,
            modifiedAt: facts?.modifiedAt ?? Date(), drm: nil)
        return Result(written: url, displacedOriginal: originalName, format: format)
    }

    /// Reopens a candidate file with Shelf's own reader and checks it holds
    /// the same shape of book `expecting` did: a title always (a book
    /// without one does not happen), an author if the original had one, a
    /// cover if the original had one. Never the window's reader, never a
    /// second implementation: the same `EPUBMetadata` an import trusts.
    private static func verifyReadBack(_ url: URL, expecting before: EPUBMetadata.Result) throws {
        let read = try EPUBMetadata.read(url: url)
        guard !read.book.title.isEmpty else {
            throw Refusal.readBackFailed("no title read back")
        }
        guard before.book.authors.isEmpty || !read.book.authors.isEmpty else {
            throw Refusal.readBackFailed("the author did not come back")
        }
        guard before.cover == nil || read.cover != nil else {
            throw Refusal.readBackFailed("the cover did not come back")
        }
    }

    /// Removes this folder's half-written EPUBs, if an earlier run left any
    /// — Shelf's own debris, never through the disposal, because the Trash
    /// is for what a person might want back and this was never theirs.
    private static func sweepPartials(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(partialPrefix) && name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

extension EPUBFileReplacement {
    /// What a commit turned out to do: the entry with its format record
    /// updated, or the refusal that stopped it.
    public enum Commit {
        case wrote(LibraryEntry)
        case refused(Refusal)
    }

    /// The whole path from new bytes to a saved index entry: `replace`
    /// above, then the book's `.epub` format row in `entry.formats` is
    /// replaced with the fresh one and the entry is saved.
    ///
    /// **Only the index changes.** `byteSize`, `sha256` and `modifiedAt` are
    /// properties of the file itself, re-derivable from it at any time —
    /// exactly like everything else a rebuild reads straight off the folders
    /// rather than trusting a stored copy of (ADR 0001). Writing them into
    /// `metadata.opf` as well would be a second copy of a fact that goes
    /// stale the moment anything else touches the file, and that nothing
    /// reads back out of the OPF regardless — the sidecar mirrors what
    /// cannot be reconstructed from the folder, and a file's own hash always
    /// can be.
    @discardableResult
    public static func commit(
        _ newContent: Data, to entry: LibraryEntry, library: Library, index: LibraryIndex,
        disposal: FolderDisposal = .trash, makeHasher: HasherFactory = PortableSHA256Hasher.factory
    ) async throws -> Commit {
        guard let epub = entry.formats.first(where: { $0.format == .epub }) else {
            return .refused(.notAnEPUB)
        }
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
        let url = folder.appendingPathComponent(epub.fileName)

        let result: Result
        do {
            result = try replace(
                with: newContent, at: url, bookID: entry.book.id, disposal: disposal, makeHasher: makeHasher)
        } catch let refusal as Refusal {
            return .refused(refusal)
        }

        var updated = entry
        updated.formats = entry.formats.map { $0.format == .epub ? result.format : $0 }
        try await index.save(updated)
        return .wrote(updated)
    }
}
