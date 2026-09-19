import Foundation

/// Moves book folders to where the metadata says they belong, and proves every
/// one of them arrived whole.
///
/// **This is the only code in Shelf that moves a book's folder.** Everything
/// else is a copy or a read, which is why it is written to the import's rules
/// rather than to a `moveItem` and a hope (ADR 0002, ADR 0018):
///
/// * **The book files are never opened for writing.** A folder is renamed; the
///   bytes inside it are not touched. The digest taken before and the digest
///   taken after are what say so, rather than a sentence in a document.
/// * **Nothing is overwritten.** The planner has already refused a destination
///   that holds anything; the runner checks again at the moment of the move,
///   because a plan is a statement about a moment that has passed.
/// * **Nothing is deleted.** The one folder this touches at all is an author
///   folder this run has just **emptied** — "Atwood, Adrian" after its last
///   book moved to "Fitzek, Sebastian" — and it goes to the **Trash**, never
///   to `removeItem`. The rule is `EmptiedFolder` and the act is
///   `FolderDisposal`, kept apart so the first can be tested on Linux and the
///   second is the platform's. A folder holding anything but the file
///   system's own residue is left exactly where it is, for `Library ▸ Find
///   Orphaned Folders…`, which also moves things to the Trash behind a
///   confirmation that names every file.
/// * **The manifest is written as the run goes on**, so an interrupted run can
///   be resumed and can be undone. Every twenty moves, for the same reason the
///   device manifest is: often enough that an interruption costs little, seldom
///   enough that a library is not rewritten per book — *and* immediately
///   before the one move that has a halfway state, which is the case-only one.
public struct OrganizeRunner: Sendable {
    private let makeHasher: HasherFactory

    /// How an emptied author folder is disposed of. The Trash by default;
    /// a test passes one that keeps count and moves nothing.
    private let disposal: FolderDisposal

    public init(makeHasher: @escaping HasherFactory, disposal: FolderDisposal = .trash) {
        self.makeHasher = makeHasher
        self.disposal = disposal
    }

    /// Where a case-only move parks a folder between its two renames.
    ///
    /// Inside `.shelf/`, in one known place, rather than beside the folder:
    /// finding a leftover is then a listing of one directory instead of a walk
    /// over five thousand, and a walk over the whole library at the end of
    /// every run would cost more than the run.
    public static let stagingFolderName = "moving"
    public static let partialPrefix = "shelf-move-"

    /// How many moves go by before the manifest is written again.
    public static let manifestBatchSize = 20

    public struct Options: Sendable {
        public var library: Library
        public var plan: OrganizePlan
        /// What a previous, interrupted run already did. Books named in here
        /// are skipped.
        public var manifest: OrganizeManifest

        public init(library: Library, plan: OrganizePlan, manifest: OrganizeManifest = OrganizeManifest()) {
            self.library = library
            self.plan = plan
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

    public struct Outcome: Sendable {
        public var report: OrganizeReport
        public var manifest: OrganizeManifest
        /// The books whose folder changed, with the new path, so the caller can
        /// write the index. The index is a cache and follows the folder, in
        /// that order, always (ADR 0001).
        public var moved: [(bookID: UUID, folder: String)]
    }

    public enum Failure: Error, Equatable {
        case cannotCreateFolder(String)
    }

    /// Runs the plan. A book that fails is a line in the report; nothing here
    /// is fatal, because a library half-organised is a library that still
    /// works — the folder is the truth and a rebuild finds every book at
    /// whichever path it is at.
    public func run(
        _ options: Options,
        progress: @Sendable @escaping (Progress) -> Void = { _ in },
        checkpoint: @Sendable (OrganizeManifest) -> Void = { _ in }
    ) async throws -> Outcome {
        let started = Date()
        let root = options.library.root
        var manifest = options.manifest
        // Before anything is planned or moved: a folder a killed run parked
        // between its two renames goes back where it belongs.
        var recovered: [OrganizeReport.Failure] = []
        if let note = recover(&manifest, in: options.library) { recovered.append(note) }

        // Books an earlier run of this organise moved but never got into the
        // manifest — it is written every twenty moves, so a process killed
        // without warning can leave up to nineteen of them. The planner found
        // them at their new folder by UUID; recording them here is what makes
        // `Undo Organize` able to put *all* of them back rather than most.
        // The same argument, and the same word, as a resumed transfer adopting
        // the files it wrote itself.
        for found in options.plan.relocated where manifest.entry(for: found.bookID) == nil {
            let digests =
                (try? self.digests(of: root.appendingPathComponent(found.folder, isDirectory: true)))
                ?? [:]
            manifest.record(
                .init(
                    bookID: found.bookID, from: found.previousFolder, to: found.folder,
                    digests: digests))
        }
        if !options.plan.relocated.isEmpty { try? manifest.write(in: options.library) }

        let alreadyDone = manifest.movedBookIDs
        var moved: [(bookID: UUID, folder: String)] = []
        var succeeded: [OrganizeMove] = []
        var emptied: [String] = []
        var failures: [OrganizeReport.Failure] = recovered
        var sinceLastWrite = 0

        for (index, move) in options.plan.moves.enumerated() {
            if Task.isCancelled { break }
            progress(Progress(done: index, total: options.plan.moves.count, currentTitle: move.title))

            // Already done by the run this one is resuming.
            if alreadyDone.contains(move.bookID) {
                moved.append((move.bookID, move.to))
                continue
            }

            do {
                let digests = try moveFolder(move, in: options.library, manifest: &manifest)
                manifest.record(
                    .init(bookID: move.bookID, from: move.from, to: move.to, digests: digests))
                moved.append((move.bookID, move.to))
                succeeded.append(move)
                if let gone = trashIfEmptied(parentOf: move.from, under: root) { emptied.append(gone) }
                sinceLastWrite += 1
                if sinceLastWrite >= Self.manifestBatchSize {
                    try? manifest.write(in: options.library)
                    checkpoint(manifest)
                    sinceLastWrite = 0
                }
            } catch {
                failures.append(
                    .init(title: move.title, path: move.from, message: message(for: error)))
            }
        }

        // Whatever happened, the library is left describing what was done and
        // with no half-named folder in it.
        try? manifest.write(in: options.library)
        checkpoint(manifest)

        let report = OrganizeReport(
            libraryName: options.library.name,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            moved: succeeded,
            alreadyInPlace: options.plan.alreadyInPlace,
            blocked: options.plan.blocked,
            failures: failures,
            emptiedFolders: emptied.sorted())
        return Outcome(report: report, manifest: manifest, moved: moved)
    }

    // MARK: The way back

    /// Puts every folder the manifest names back where it came from.
    ///
    /// The manifest walked backwards, newest first, because that is the order
    /// that undoes a chain: if `A → B` and then `B → C` both happened, undoing
    /// `B → C` first frees `B` for the undo of `A → B`. Forwards, the second
    /// step would find its destination occupied.
    ///
    /// Every move back is verified the same way the move out was. A folder
    /// whose old path is occupied by something else is **left where it is** and
    /// named in the report: putting a library back is not worth burying
    /// whatever has appeared at the old path since.
    public func undo(
        _ manifest: OrganizeManifest, in library: Library,
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Outcome {
        let started = Date()
        let root = library.root
        var working = manifest
        var failures: [OrganizeReport.Failure] = []
        if let note = recover(&working, in: library) { failures.append(note) }

        var undone: [OrganizeMove] = []
        var moved: [(bookID: UUID, folder: String)] = []
        let backwards = Array(working.entries.reversed())

        for (index, entry) in backwards.enumerated() {
            if Task.isCancelled { break }
            progress(Progress(done: index, total: backwards.count, currentTitle: entry.from))

            let back = OrganizeMove(
                bookID: entry.bookID, title: entry.from, author: "", from: entry.to, to: entry.from,
                isCaseOnly: VolumeCase.isCaseOnly(
                    from: entry.to, to: entry.from,
                    folding: VolumeCase.folds(at: library.privateFolder)))
            do {
                _ = try moveFolder(back, in: library, manifest: &working)
                undone.append(back)
                moved.append((entry.bookID, entry.from))
                working.entries.removeAll { $0.bookID == entry.bookID }
                try? working.write(in: library)
            } catch {
                failures.append(
                    .init(title: entry.from, path: entry.to, message: message(for: error)))
            }
        }

        // Only when there is nothing left to put back does the file go: while
        // it is there, there is still a way back.
        if working.entries.isEmpty {
            OrganizeManifest.remove(in: library)
        } else {
            try? working.write(in: library)
        }

        let report = OrganizeReport(
            libraryName: library.name, startedAt: started,
            duration: Date().timeIntervalSince(started), moved: undone, alreadyInPlace: 0,
            blocked: [], failures: failures, isUndo: true)
        return Outcome(report: report, manifest: working, moved: moved)
    }

    // MARK: One folder

    /// Moves one folder and hands back what is in it, hashed **after** the
    /// move.
    ///
    /// The digests before come out of the index for the book files — the
    /// library already knows them and reading them again would be a second
    /// full read for nothing — and are computed here for the small files
    /// beside them, `cover.*` and `metadata.opf`, which the index does not
    /// hold. What comes back is read off the disk at the new path, and the two
    /// are compared. A mismatch puts the folder back.
    private func moveFolder(
        _ move: OrganizeMove, in library: Library, manifest: inout OrganizeManifest
    ) throws -> [String: String] {
        let root = library.root
        let source = root.appendingPathComponent(move.from, isDirectory: true)
        let destination = root.appendingPathComponent(move.to, isDirectory: true)

        let before = try digests(of: source)
        try makeFolder(destination.deletingLastPathComponent())

        if move.isCaseOnly {
            // `Fitzek` → `fitzek` on a folding volume is not a move between two
            // folders; it is one folder being spelled differently, and a direct
            // `moveItem` is a write into itself. Two steps through a name
            // nothing else can have — and the only halfway state in this whole
            // operation, so it is written down *before* it is entered.
            let stagingPath = Self.stagingPath(for: library)
            try makeFolder(
                root.appendingPathComponent(stagingPath, isDirectory: true)
                    .deletingLastPathComponent())
            manifest.inFlight = .init(
                bookID: move.bookID, staging: stagingPath, from: move.from, to: move.to)
            try manifest.write(in: library)

            let staging = root.appendingPathComponent(stagingPath, isDirectory: true)
            try FileManager.default.moveItem(at: source, to: staging)
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
            } catch {
                try? FileManager.default.moveItem(at: staging, to: source)
                manifest.inFlight = nil
                try? manifest.write(in: library)
                throw error
            }
            manifest.inFlight = nil
        } else {
            // Checked again here, not only in the plan: a plan is a statement
            // about a moment that has already passed, and this is the one
            // operation that could bury a folder inside another.
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw MoveError.destinationExists
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }

        let after = try digests(of: destination)
        guard after == before else {
            // Whatever happened, the book goes back where it was, and the
            // caller is told. Verified means compared.
            try? FileManager.default.moveItem(at: destination, to: source)
            throw MoveError.contentsChanged
        }
        return after
    }

    /// Every file directly in the folder, by name, with its SHA-256.
    ///
    /// One level. A book's folder holds its files, a cover and an OPF; a
    /// folder inside it is not something Shelf makes, and walking into one
    /// would turn a verification into an unbounded read.
    func digests(of folder: URL) throws -> [String: String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var result: [String: String] = [:]
        for name in names.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
                !isFolder.boolValue
            else { continue }
            result[name] = try FileDigest.sha256(of: url, makeHasher: makeHasher)
        }
        return result
    }

    enum MoveError: Error, Equatable {
        case destinationExists
        case contentsChanged
    }

    private func message(for error: Error) -> String {
        switch error {
        case MoveError.destinationExists: return "something is already at that path"
        case MoveError.contentsChanged:
            return "what arrived differs from what left — the folder has been put back"
        case Failure.cannotCreateFolder(let name): return "the folder “\(name)” could not be made"
        default: return (error as NSError).localizedDescription
        }
    }

    private func makeFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreateFolder(url.lastPathComponent)
        }
    }

    /// Puts the author folder a move has just emptied into the Trash, and
    /// only that.
    ///
    /// Everything that decides *whether* is in `EmptiedFolder`, which is pure
    /// and runs on Linux; everything that decides *how* is behind
    /// `FolderDisposal`, which on a Mac is the Trash. Neither is inlined here,
    /// because this is the one place in Shelf's library handling that makes a
    /// folder go away and both halves of it want a test of their own.
    ///
    /// The path handed in is always the parent of a folder **this run has just
    /// moved out of**, so "this run emptied it" is true by construction rather
    /// than by inspection. What is checked here is the rest: that it is a
    /// direct child of the root, not `.shelf`, really a directory, and holds
    /// nothing but the file system's own residue.
    ///
    /// Returns the folder's name for the report, or `nil` — and `nil` whenever
    /// the disposal fails, so a folder that could not reach the Trash is left
    /// where it is rather than reported as gone.
    private func trashIfEmptied(parentOf movedFrom: String, under root: URL) -> String? {
        guard let parent = EmptiedFolder.candidate(parentOf: movedFrom) else { return nil }

        let url = root.appendingPathComponent(parent, isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder),
            isFolder.boolValue,
            let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
            EmptiedFolder.holdsNothingButResidue(contents)
        else { return nil }

        do {
            try disposal.dispose(url)
        } catch {
            return nil
        }
        return parent
    }

    /// Where the next case-only move parks its folder.
    static func stagingPath(for library: Library) -> String {
        "\(Library.privateFolderName)/\(stagingFolderName)/\(partialPrefix)\(UUID().uuidString.prefix(8))"
    }

    /// Puts back a folder that a killed run left parked between its two
    /// renames. **The only thing in this program that can lose a book, made
    /// impossible rather than unlikely.**
    ///
    /// It goes to the destination if that is free, and otherwise back where it
    /// came from. A staging folder is never deleted — it holds a whole book —
    /// and if neither path is available it is left where it is and named in
    /// the report, because a folder a person can find is better than a clever
    /// guess.
    private func recover(_ manifest: inout OrganizeManifest, in library: Library) -> OrganizeReport.Failure? {
        guard let flight = manifest.inFlight else { return nil }
        defer {
            manifest.inFlight = nil
            try? manifest.write(in: library)
        }
        let root = library.root
        let staging = root.appendingPathComponent(flight.staging, isDirectory: true)
        guard FileManager.default.fileExists(atPath: staging.path) else { return nil }

        for candidate in [flight.to, flight.from] {
            let url = root.appendingPathComponent(candidate, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: staging, to: url)) != nil { return nil }
        }
        return .init(
            title: flight.from, path: flight.staging,
            message: "a folder from an interrupted run is parked here and could not be put back")
    }
}
