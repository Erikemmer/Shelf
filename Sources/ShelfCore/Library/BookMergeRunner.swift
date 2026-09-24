import Foundation

/// Carrying out a `BookMergePlan`: moving files, discarding the losers,
/// trashing what an absorbed book leaves empty behind — never metadata.
///
/// **Metadata is deliberately not this type's job.** `MetadataEditor.apply`
/// already writes an OPF the safe way, merging changed fields onto whatever
/// is on disk rather than overwriting unknown ones, and `LibraryIndex.save`/
/// `.delete` already are the index's own writers. This runner hands its
/// caller a finished `GroupOutcome` — the survivor's complete new format
/// list, the books to delete — and the caller writes metadata through the
/// mechanisms that already do that correctly, the same separation
/// `OrganizeRunner` keeps from the metadata it never touches either.
public struct BookMergeRunner: Sendable {
    public var makeHasher: HasherFactory
    public var disposal: FolderDisposal

    public init(makeHasher: @escaping HasherFactory, disposal: FolderDisposal = .trash) {
        self.makeHasher = makeHasher
        self.disposal = disposal
    }

    public struct Options: Sendable {
        public var library: Library
        public var plan: BookMergePlan
        /// Every book a group in `plan` refers to, survivor and absorbed
        /// alike, as the index currently holds it.
        public var entries: [UUID: LibraryEntry]
        public var manifest: BookMergeManifest

        public init(
            library: Library, plan: BookMergePlan, entries: [UUID: LibraryEntry],
            manifest: BookMergeManifest = BookMergeManifest()
        ) {
            self.library = library
            self.plan = plan
            self.entries = entries
            self.manifest = manifest
        }
    }

    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
        public var currentTitle: String

        public init(done: Int, total: Int, currentTitle: String) {
            self.done = done
            self.total = total
            self.currentTitle = currentTitle
        }
    }

    /// What one group's merge actually did, resolved down to what the
    /// caller needs to finish the job.
    public struct GroupOutcome: Sendable, Equatable {
        public var survivingID: UUID
        /// The survivor's complete, final list of format files.
        public var newFormats: [BookFormat]
        /// Absorbed books, gone – to be deleted from the index.
        public var absorbedIDs: [UUID]
    }

    public struct Outcome: Sendable {
        public var manifest: BookMergeManifest
        public var groups: [GroupOutcome]
    }

    public enum Failure: Error, Equatable, Sendable {
        case bookNotFound(UUID)
        case destinationOccupied(String)
        case moveFailed(String)
        case hashMismatch(String)
    }

    /// Groups, not files: a group is the atomic resumable unit, the same way
    /// one book's whole folder move is `OrganizeRunner`'s.
    public static let manifestBatchSize = 5

    // MARK: run

    public func run(
        _ options: Options,
        progress: @Sendable @escaping (Progress) -> Void = { _ in },
        checkpoint: @Sendable (BookMergeManifest) -> Void = { _ in }
    ) async throws -> Outcome {
        var manifest = options.manifest
        let alreadyDone = manifest.mergedSurvivorIDs
        var groupOutcomes: [GroupOutcome] = []
        var sinceLastWrite = 0

        for (index, groupPlan) in options.plan.groups.enumerated() {
            if Task.isCancelled { break }
            progress(
                Progress(done: index, total: options.plan.groups.count, currentTitle: groupPlan.survivingTitle))

            if alreadyDone.contains(groupPlan.survivingID) {
                if let entry = manifest.entry(for: groupPlan.survivingID) {
                    groupOutcomes.append(
                        outcome(from: entry, survivorFormats: options.entries[groupPlan.survivingID]?.formats ?? []))
                }
                continue
            }

            let entry = try runGroup(groupPlan, options: options)
            manifest.record(entry)
            groupOutcomes.append(
                outcome(from: entry, survivorFormats: options.entries[groupPlan.survivingID]?.formats ?? []))

            sinceLastWrite += 1
            if sinceLastWrite >= Self.manifestBatchSize {
                try? manifest.write(in: options.library)
                checkpoint(manifest)
                sinceLastWrite = 0
            }
        }

        try? manifest.write(in: options.library)
        return Outcome(manifest: manifest, groups: groupOutcomes)
    }

    private func runGroup(_ groupPlan: BookMergeGroupPlan, options: Options) throws -> BookMergeManifest.Entry {
        guard let survivorEntry = options.entries[groupPlan.survivingID] else {
            throw Failure.bookNotFound(groupPlan.survivingID)
        }
        let survivorFolder = options.library.root.appendingPathComponent(survivorEntry.folder, isDirectory: true)

        let moves = try moveFiles(groupPlan.moves, into: survivorFolder, options: options)
        let discards = try discardFiles(groupPlan.discards, options: options)
        let coverMove = try moveCover(from: groupPlan.coverFromBookID, into: survivorFolder, options: options)
        let folderTrash = trashAbsorbedFolders(groupPlan.absorbedIDs, options: options)
        let absorbedSnapshots = groupPlan.absorbedIDs.compactMap { options.entries[$0] }

        return BookMergeManifest.Entry(
            survivingID: groupPlan.survivingID, priorSurvivorEntry: survivorEntry,
            absorbedEntries: absorbedSnapshots, moves: moves, discards: discards, coverMove: coverMove,
            absorbedFolderTrash: folderTrash)
    }

    private func moveFiles(
        _ planned: [BookMergeMove], into survivorFolder: URL, options: Options
    ) throws -> [BookMergeManifest.MoveRecord] {
        var moves: [BookMergeManifest.MoveRecord] = []
        for move in planned {
            guard let sourceEntry = options.entries[move.sourceBookID] else {
                throw Failure.bookNotFound(move.sourceBookID)
            }
            let sourceFolder = options.library.root.appendingPathComponent(sourceEntry.folder, isDirectory: true)
            let from = sourceFolder.appendingPathComponent(move.format.fileName)
            let to = survivorFolder.appendingPathComponent(move.format.fileName)
            try moveVerified(from: from, to: to, expectedSHA256: move.format.sha256)
            moves.append(
                BookMergeManifest.MoveRecord(
                    fromBookID: move.sourceBookID, fileName: move.format.fileName, sha256: move.format.sha256))
        }
        return moves
    }

    private func discardFiles(
        _ planned: [BookMergeDiscard], options: Options
    ) throws -> [BookMergeManifest.DiscardRecord] {
        var discards: [BookMergeManifest.DiscardRecord] = []
        for discard in planned {
            guard let sourceEntry = options.entries[discard.sourceBookID] else {
                throw Failure.bookNotFound(discard.sourceBookID)
            }
            let sourceFolder = options.library.root.appendingPathComponent(sourceEntry.folder, isDirectory: true)
            let url = sourceFolder.appendingPathComponent(discard.format.fileName)
            let trashedAt: URL?
            do {
                trashedAt = try disposal.dispose(url)
            } catch {
                throw Failure.moveFailed(error.localizedDescription)
            }
            discards.append(
                BookMergeManifest.DiscardRecord(
                    fromBookID: discard.sourceBookID, fileName: discard.format.fileName,
                    sha256: discard.format.sha256, trashedAt: trashedAt))
        }
        return discards
    }

    private func moveCover(
        from coverFromBookID: UUID?, into survivorFolder: URL, options: Options
    ) throws -> BookMergeManifest.MoveRecord? {
        guard let coverFromBookID, let coverEntry = options.entries[coverFromBookID] else { return nil }
        let coverFolder = options.library.root.appendingPathComponent(coverEntry.folder, isDirectory: true)
        guard let coverURL = CoverFile.url(in: coverFolder) else { return nil }
        let fileName = coverURL.lastPathComponent
        let destination = survivorFolder.appendingPathComponent(fileName)
        let hash: String
        do {
            hash = try FileDigest.sha256(of: coverURL, makeHasher: makeHasher)
        } catch {
            throw Failure.moveFailed(error.localizedDescription)
        }
        try moveVerified(from: coverURL, to: destination, expectedSHA256: hash)
        return BookMergeManifest.MoveRecord(fromBookID: coverFromBookID, fileName: fileName, sha256: hash)
    }

    /// Every absorbed book's folder, by this point holding nothing but
    /// residue — every real file already moved in or discarded — sent to the
    /// Trash whole. A folder that could not be disposed of is left exactly
    /// where it is and simply missing from the returned records; the group's
    /// other moves already happened and are not undone for this one failure.
    private func trashAbsorbedFolders(
        _ absorbedIDs: [UUID], options: Options
    ) -> [BookMergeManifest.FolderTrashRecord] {
        absorbedIDs.compactMap { bookID in
            guard let entry = options.entries[bookID] else { return nil }
            let folder = options.library.root.appendingPathComponent(entry.folder, isDirectory: true)
            let trashedAt = try? disposal.dispose(folder)
            return BookMergeManifest.FolderTrashRecord(bookID: bookID, trashedAt: trashedAt)
        }
    }

    private func moveVerified(from: URL, to: URL, expectedSHA256: String) throws {
        guard !FileManager.default.fileExists(atPath: to.path) else {
            throw Failure.destinationOccupied(to.lastPathComponent)
        }
        do {
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            throw Failure.moveFailed(error.localizedDescription)
        }
        let digest: String
        do {
            digest = try FileDigest.sha256(of: to, makeHasher: makeHasher)
        } catch {
            throw Failure.moveFailed(error.localizedDescription)
        }
        guard digest == expectedSHA256 else { throw Failure.hashMismatch(to.lastPathComponent) }
    }

    /// Rebuilds the survivor's final format list from a manifest entry,
    /// whether it was just written or read back for a resumed group.
    ///
    /// **A discard can be the survivor's own file, not only an absorbed
    /// one** — found live, the first time this ran against a real library:
    /// two different EPUBs of the same format competing, and the survivor's
    /// own copy loses `FormatPreference`'s tie-break to the absorbed book's.
    /// The file is correctly gone from disk either way; leaving it in
    /// `newFormats` would have the index still claim it exists.
    private func outcome(from entry: BookMergeManifest.Entry, survivorFormats: [BookFormat]) -> GroupOutcome {
        let discardedFromSurvivor = Set(
            entry.discards.filter { $0.fromBookID == entry.survivingID }.map(\.fileName))
        var formats = survivorFormats.filter { !discardedFromSurvivor.contains($0.fileName) }
        for move in entry.moves {
            guard
                let original = entry.absorbedEntries
                    .first(where: { $0.id == move.fromBookID })?
                    .formats.first(where: { $0.fileName == move.fileName })
            else { continue }
            if !formats.contains(where: { $0.id == original.id }) { formats.append(original) }
        }
        return GroupOutcome(
            survivingID: entry.survivingID, newFormats: formats,
            absorbedIDs: entry.absorbedEntries.map(\.id))
    }

    // MARK: undo

    public struct UndoneGroup: Sendable, Equatable {
        public var priorSurvivorEntry: LibraryEntry
        public var restoredEntries: [LibraryEntry]
    }

    public struct UndoOutcome: Sendable {
        public var manifest: BookMergeManifest
        public var undone: [UndoneGroup]
    }

    /// Reverses every group in `manifest`, newest first — the same order
    /// `OrganizeRunner.undo` reasons about, and for the same shape of
    /// reason: nothing here can collide the way a chain of folder renames
    /// can, but reading the manifest back to front still means each group's
    /// own books are exactly where this run's forward pass last left them.
    public func undo(
        _ manifest: BookMergeManifest, in library: Library,
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> UndoOutcome {
        var working = manifest
        var undone: [UndoneGroup] = []
        let backwards = Array(working.entries.reversed())

        for (index, entry) in backwards.enumerated() {
            if Task.isCancelled { break }
            progress(Progress(done: index, total: backwards.count, currentTitle: entry.priorSurvivorEntry.book.title))

            try undoGroup(entry, in: library)
            undone.append(
                UndoneGroup(priorSurvivorEntry: entry.priorSurvivorEntry, restoredEntries: entry.absorbedEntries))
            working.entries.removeAll { $0.survivingID == entry.survivingID }
            try? working.write(in: library)
        }

        if working.entries.isEmpty {
            BookMergeManifest.remove(in: library)
        } else {
            try? working.write(in: library)
        }
        return UndoOutcome(manifest: working, undone: undone)
    }

    private func undoGroup(_ entry: BookMergeManifest.Entry, in library: Library) throws {
        // Folders first: an absorbed book's own folder has to exist again
        // before anything can move back into it.
        for absorbed in entry.absorbedEntries {
            guard let trashedFolder = entry.trashedFolder(for: absorbed.id) else {
                throw Failure.bookNotFound(absorbed.id)
            }
            let destination = library.root.appendingPathComponent(absorbed.folder, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw Failure.destinationOccupied(absorbed.folder)
            }
            do {
                try FileManager.default.moveItem(at: trashedFolder, to: destination)
            } catch {
                throw Failure.moveFailed(error.localizedDescription)
            }
        }

        let survivorFolder = library.root.appendingPathComponent(entry.priorSurvivorEntry.folder, isDirectory: true)
        for move in entry.moves {
            try undoMove(move, from: survivorFolder, entry: entry, library: library)
        }
        if let coverMove = entry.coverMove {
            try undoMove(coverMove, from: survivorFolder, entry: entry, library: library)
        }
        for discard in entry.discards {
            try undoDiscard(discard, entry: entry, library: library)
        }
    }

    private func undoMove(
        _ move: BookMergeManifest.MoveRecord, from survivorFolder: URL, entry: BookMergeManifest.Entry,
        library: Library
    ) throws {
        guard let absorbed = entry.absorbedEntries.first(where: { $0.id == move.fromBookID }) else {
            throw Failure.bookNotFound(move.fromBookID)
        }
        let absorbedFolder = library.root.appendingPathComponent(absorbed.folder, isDirectory: true)
        try moveVerified(
            from: survivorFolder.appendingPathComponent(move.fileName),
            to: absorbedFolder.appendingPathComponent(move.fileName), expectedSHA256: move.sha256)
    }

    private func undoDiscard(
        _ discard: BookMergeManifest.DiscardRecord, entry: BookMergeManifest.Entry, library: Library
    ) throws {
        guard let trashedAt = discard.trashedAt else { throw Failure.bookNotFound(discard.fromBookID) }
        guard let absorbed = entry.absorbedEntries.first(where: { $0.id == discard.fromBookID }) else {
            throw Failure.bookNotFound(discard.fromBookID)
        }
        let digest: String
        do {
            digest = try FileDigest.sha256(of: trashedAt, makeHasher: makeHasher)
        } catch {
            throw Failure.moveFailed(error.localizedDescription)
        }
        guard digest == discard.sha256 else { throw Failure.hashMismatch(discard.fileName) }
        let absorbedFolder = library.root.appendingPathComponent(absorbed.folder, isDirectory: true)
        let destination = absorbedFolder.appendingPathComponent(discard.fileName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.destinationOccupied(discard.fileName)
        }
        do {
            try FileManager.default.moveItem(at: trashedAt, to: destination)
        } catch {
            throw Failure.moveFailed(error.localizedDescription)
        }
    }
}
