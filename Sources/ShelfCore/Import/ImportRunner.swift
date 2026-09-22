import Foundation

/// Copies the files of an import plan into the library and proves each copy
/// arrived intact.
///
/// The source is only ever read. A file is written under a `.part` name, the
/// source is hashed while it is read for the copy, the destination is read back
/// and hashed, and only if the two digests match is it renamed into place.
/// That is Selector's `IngestRunner` pattern, and it is here for the same
/// reason: this is the step where data can actually be lost, and "the copy call
/// returned success" is not the same as "the file is intact"
/// (`docs/adr/0002-copy-verify-then-trust.md`).
///
/// Nothing is ever deleted, moved or overwritten. A file already at the
/// destination is an error, not something to write over.
public struct ImportRunner: Sendable {
    private let makeHasher: HasherFactory
    private let freeSpace: FreeSpaceProbe

    public init(
        makeHasher: @escaping HasherFactory,
        freeSpace: @escaping FreeSpaceProbe = FileManager.defaultFreeSpaceProbe
    ) {
        self.makeHasher = makeHasher
        self.freeSpace = freeSpace
    }

    public struct Options: Sendable {
        public var library: Library
        public var plan: ImportPlan
        /// Where the import came from, for the report: a folder, "3 dropped
        /// files", a Calibre library.
        public var sourceDescription: String

        public init(library: Library, plan: ImportPlan, sourceDescription: String) {
            self.library = library
            self.plan = plan
            self.sourceDescription = sourceDescription
        }
    }

    public struct Progress: Sendable, Equatable {
        public var filesDone: Int
        public var filesTotal: Int
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var currentTitle: String
        /// Straight-line estimate; nil until there is enough to go on.
        public var estimatedRemaining: TimeInterval?

        public init(
            filesDone: Int, filesTotal: Int, bytesDone: Int64, bytesTotal: Int64,
            currentTitle: String, estimatedRemaining: TimeInterval? = nil
        ) {
            self.filesDone = filesDone
            self.filesTotal = filesTotal
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.currentTitle = currentTitle
            self.estimatedRemaining = estimatedRemaining
        }

        public var fractionDone: Double {
            bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0
        }
    }

    public enum Failure: Error, Equatable {
        /// Refused before the first byte.
        case notEnoughSpace(needed: Int64, available: Int64)
        case cannotCreateFolder(String)
    }

    public struct Outcome: Sendable {
        /// The books that are now in the library, ready for the index.
        public var entries: [LibraryEntry]
        public var report: ImportReport
        /// Where the counter stands afterwards, to be stored in `library.json`.
        public var nextBookNumber: Int
    }

    /// How many books go into the index at a time while the run is going on.
    ///
    /// One transaction for 5 000 books holds a lot of memory and one per book
    /// would be 5 000 fsyncs; 200 is the same order the callers already used
    /// when they saved everything at the end.
    public static let indexBatchSize = 200

    /// Runs the plan. Per-file problems end up in the report; only a problem
    /// that makes the whole run pointless is thrown.
    ///
    /// - Parameter saveBatch: called with each batch of finished books **while
    ///   the run is going on**, and once more with whatever is left at the end.
    ///
    ///   It exists because an interrupted import used to leave files on the
    ///   disk that nothing knew about. The index was written once, by the
    ///   caller, after the last file — so killing a run of 2 000 books left
    ///   1 394 books on disk and an index holding none, and the *next* run
    ///   planned all 2 000 again and copied them into new folders. Measured:
    ///   3 394 files where 2 000 belonged. Nothing was lost and nothing was
    ///   overwritten, which is why it went unnoticed; it simply was not the
    ///   resume ADR 0002 decision 6 claims.
    ///
    ///   A book reaches this closure only once its file, its cover and its
    ///   `metadata.opf` are all on disk, so an index written from here never
    ///   describes a book that is not there.
    /// - Parameter existingEntry: what the library already holds for a book,
    ///   by id. Asked only for an `.addFormat` whose book this run did not
    ///   create — which is `Add Format…`, and a second import over a folder
    ///   already in the library.
    ///
    ///   Without it the runner has nothing to add *to*, so it built a fresh
    ///   entry with no formats and one file in it, and the index took that as
    ///   the whole truth about the book. A book whose folder held an EPUB, an
    ///   AZW3, a MOBI and a PDF showed three formats; the fourth was on disk
    ///   and out of the index until the next rebuild. The folder number went
    ///   the same way, reset to 0.
    ///
    ///   Nothing was ever lost on disk, which is exactly why it went unseen —
    ///   the same shape of defect as the orphaned folders, and found the same
    ///   way, by looking at what a real run produced.
    public func run(
        _ options: Options,
        progress: @Sendable @escaping (Progress) -> Void = { _ in },
        saveBatch: @Sendable @escaping (_ entries: [LibraryEntry]) async throws -> Void = { _ in },
        existingEntry: @Sendable (UUID) -> LibraryEntry? = { _ in nil }
    ) async throws -> Outcome {
        let started = Date()
        try checkSpace(for: options)

        var entries: [UUID: LibraryEntry] = [:]
        var order: [UUID] = []
        var failures: [ImportReport.Failure] = []
        var warnings: [ImportReport.Warning] = []
        var copiedBytes: Int64 = 0
        var copiedByFormat: [BookFileFormat: Int] = [:]
        var newBookCount = 0
        var addedFormatCount = 0
        var highestNumber = 0
        // Books finished since the last time the index was written.
        var unsaved: [LibraryEntry] = []

        let total = options.plan.totalBytes
        var done: Int64 = 0

        for (index, operation) in options.plan.operations.enumerated() {
            if Task.isCancelled { break }
            let candidate = operation.candidate
            progress(
                Progress(
                    filesDone: index, filesTotal: options.plan.fileCount, bytesDone: done, bytesTotal: total,
                    currentTitle: candidate.book.title,
                    estimatedRemaining: estimate(done: done, total: total, since: started)))

            for warning in candidate.warnings {
                warnings.append(.init(path: candidate.source.lastPathComponent, message: warning))
            }

            do {
                switch operation {
                case .newBook(let new):
                    let entry = try writeNewBook(new, in: options.library)
                    entries[entry.book.id] = entry
                    unsaved.append(entry)
                    order.append(entry.book.id)
                    highestNumber = max(highestNumber, new.number)
                    newBookCount += 1
                case .addFormat(let add):
                    // The book may be one this very run created, or one that
                    // was already in the library; either way its entry is what
                    // the new format is appended to. The second case has to be
                    // *asked for* — the run has no memory of a book it did not
                    // make.
                    let existing = entries[add.bookID] ?? existingEntry(add.bookID)
                    let entry = try appendFormat(add, to: existing, in: options.library)
                    entries[entry.book.id] = entry
                    unsaved.append(entry)
                    if !order.contains(entry.book.id) { order.append(entry.book.id) }
                    addedFormatCount += 1
                }
                copiedBytes += candidate.byteSize
                copiedByFormat[candidate.format, default: 0] += 1
            } catch {
                failures.append(.init(path: candidate.source.path, message: message(for: error)))
            }
            done += candidate.byteSize

            // Into the index as we go, so an interruption leaves an index that
            // matches the folder rather than an empty one.
            if unsaved.count >= Self.indexBatchSize {
                try await saveBatch(unsaved)
                unsaved.removeAll(keepingCapacity: true)
            }
        }

        // The last, short batch. Before the cancellation bookkeeping below, so a
        // run that was cut off still hands over everything it did finish — which
        // is the whole of what makes the next run a resume rather than a repeat.
        //
        // `.detached`, not a plain `await`: this is reached most often
        // *because* the surrounding `Task` was just cancelled, and
        // `saveBatch` for the real `LibraryIndex` writes through GRDB, which
        // itself checks `Task.isCancelled` and refuses to write — silently,
        // under the `try?` below, which exists for an unrelated reason (a
        // batch write failing must not make the whole run look like a
        // failure). Measured against the real app: a cancelled run reached
        // this line every time and the batch never landed, because the very
        // cancellation that got it here also poisoned the write meant to
        // save what the cancellation should not have cost
        // (`CHANGELOG.md`, Sprint 13, Teil C). A `.detached` task starts
        // uncancelled regardless of what cancelled the one asking for it.
        if !unsaved.isEmpty {
            let batch = unsaved
            try? await Task.detached { try await saveBatch(batch) }.value
            unsaved.removeAll()
        }

        // Whatever happened – finished, cancelled or full of errors – nothing
        // half-written is left looking like a book.
        removePartials(in: options.library.root)

        if Task.isCancelled {
            let remaining = options.plan.fileCount - newBookCount - addedFormatCount - failures.count
            if remaining > 0 {
                failures.append(.init(path: "—", message: "cancelled with \(remaining) files still to copy"))
            }
        }

        let report = ImportReport(
            libraryName: options.library.name,
            sourceDescription: options.sourceDescription,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            newBooks: newBookCount,
            addedFormats: addedFormatCount,
            copiedByFormat: copiedByFormat,
            copiedBytes: copiedBytes,
            skipped: options.plan.skipped,
            warnings: warnings,
            failures: failures)

        return Outcome(
            entries: order.compactMap { entries[$0] },
            report: report,
            // Never below where the plan started: a run in which every book
            // failed must not hand back a counter that points at folder 1.
            nextBookNumber: max(highestNumber + 1, planStartNumber(options.plan)))
    }

    /// The lowest number the plan was going to use, so the counter moves
    /// forward even when nothing was written.
    private func planStartNumber(_ plan: ImportPlan) -> Int {
        let numbers = plan.operations.compactMap { operation -> Int? in
            if case .newBook(let new) = operation { return new.number }
            return nil
        }
        guard let highest = numbers.max() else { return 1 }
        return highest + 1
    }

    // MARK: One book

    /// Creates a book's folder and writes the file, the cover and the OPF.
    ///
    /// Order matters: the book file is copied and verified *first*, and the
    /// cover and OPF only afterwards. A folder that holds a cover and an OPF
    /// but no book would look like a book to the rebuilder.
    private func writeNewBook(_ operation: ImportOperation.NewBook, in library: Library) throws -> LibraryEntry {
        let candidate = operation.candidate
        let folder = library.root.appendingPathComponent(operation.folder, isDirectory: true)
        try makeFolder(folder)

        let digest = try copyAndVerify(
            from: candidate.source, to: folder.appendingPathComponent(operation.fileName))

        var book = candidate.book
        book.modifiedAt = Date()
        let format = BookFormat(
            bookID: book.id, format: candidate.format, fileName: operation.fileName,
            byteSize: candidate.byteSize, sha256: digest, modifiedAt: candidate.modifiedAt, drm: candidate.drm)

        writeCover(candidate, into: folder)
        // A failed OPF is a warning, not a failed import: the book file is
        // already in place and verified, and the OPF can be rewritten from the
        // index at any time. Losing the book over its metadata file would be
        // the wrong trade.
        try? OPFDocument.write(book, to: folder)

        return LibraryEntry(book: book, number: operation.number, folder: operation.folder, formats: [format])
    }

    /// Adds one more file to a book that already exists.
    private func appendFormat(
        _ operation: ImportOperation.AddFormat, to existing: LibraryEntry?, in library: Library
    ) throws -> LibraryEntry {
        let candidate = operation.candidate
        // An `addFormat` for a book that was already in the library carries no
        // folder from the planner – the caller fills it in from the index. An
        // empty one here would write into the library root, so it is refused.
        let folderPath = operation.folder.isEmpty ? existing?.folder ?? "" : operation.folder
        guard !folderPath.isEmpty else { throw Failure.cannotCreateFolder(candidate.book.title) }

        let folder = library.root.appendingPathComponent(folderPath, isDirectory: true)
        try makeFolder(folder)
        let digest = try copyAndVerify(
            from: candidate.source, to: folder.appendingPathComponent(operation.fileName))

        let format = BookFormat(
            bookID: operation.bookID, format: candidate.format, fileName: operation.fileName,
            byteSize: candidate.byteSize, sha256: digest, modifiedAt: candidate.modifiedAt, drm: candidate.drm)

        var entry =
            existing
            ?? LibraryEntry(
                book: {
                    var book = candidate.book
                    book.id = operation.bookID
                    return book
                }(), number: 0, folder: folderPath)
        // Never twice. A run asked to add a format the entry already lists —
        // the same file offered again — replaces that row rather than growing a
        // second one with the same name.
        entry.formats.removeAll { $0.fileName == format.fileName }
        entry.formats.append(format)
        entry.book.modifiedAt = Date()
        // A book that just gained a format should say so in its OPF too.
        try? OPFDocument.write(entry.book, to: folder)
        // A cover only if the folder has none: the first format's cover stays
        // the book's cover, so adding an AZW3 does not silently change it.
        if CoverFile.url(in: folder) == nil {
            writeCover(candidate, into: folder)
        }
        return entry
    }

    /// The cover next to the book, as `cover.<ext>` for whatever the bytes
    /// actually are (`CoverFile`).
    ///
    /// The image is never re-encoded: the core has no image code and must not
    /// grow any, and re-encoding would lose quality for nothing.
    private func writeCover(_ candidate: ImportCandidate, into folder: URL) {
        guard let cover = candidate.cover, !cover.isEmpty else { return }
        // A missing cover is a cosmetic problem and never worth failing an
        // import for, so this swallows its errors; what was missing is already
        // in the report through the candidate's own warnings.
        try? cover.write(to: folder.appendingPathComponent(CoverFile.name(for: cover)), options: .atomic)
    }

    // MARK: Copying

    /// The prefix every half-written file carries, so `removePartials` can find
    /// them and so nothing that starts with it is ever mistaken for a book.
    static let partialPrefix = ".shelf-import-"

    /// Copies one file and returns its digest, or throws.
    private func copyAndVerify(from source: URL, to destination: URL) throws -> String {
        // The temporary name is *short* and random, not the destination's name
        // with a prefix. A book file may already use all 255 bytes a path
        // component is allowed – `BookFolderName.fileName` truncates to exactly
        // that – and prefixing it pushed the temporary file over the limit, so
        // the copy failed for the longest titles and only for those. Random
        // rather than a counter, so two imports into one folder cannot collide.
        let partial =
            destination
            .deletingLastPathComponent()
            .appendingPathComponent("\(Self.partialPrefix)\(UUID().uuidString.prefix(8)).part")
        try? FileManager.default.removeItem(at: partial)

        let sourceDigest = try copy(from: source, to: partial)
        let writtenDigest = try FileDigest.sha256(of: partial, makeHasher: makeHasher)
        guard sourceDigest == writtenDigest else {
            try? FileManager.default.removeItem(at: partial)
            throw CopyError.checksumMismatch
        }
        // Never overwrite. The planner has already made the name unique, so a
        // file sitting there means something is wrong.
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            try? FileManager.default.removeItem(at: partial)
            throw CopyError.destinationExists
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return sourceDigest
    }

    /// Streams the file across in chunks, hashing the source as it goes – one
    /// read of the source, not two.
    private func copy(from source: URL, to destination: URL) throws -> String {
        guard let input = FileHandle(forReadingAtPath: source.path) else { throw CopyError.cannotReadSource }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
            let output = FileHandle(forWritingAtPath: destination.path)
        else { throw CopyError.cannotWriteDestination }
        defer { try? output.close() }

        let hasher = makeHasher()
        var reachedEnd = false
        while !reachedEnd {
            if Task.isCancelled { throw CopyError.cancelled }
            // Each chunk is backed by an autoreleased buffer. Without a pool of
            // its own the loop holds every chunk of the file until it ends –
            // measured at 1.2 GB peak in Selector for a 7.4 GB folder.
            try withAutoreleasePool {
                let chunk = try input.read(upToCount: FileDigest.chunkSize) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                    return
                }
                try output.write(contentsOf: chunk)
                hasher.update(chunk)
            }
        }
        try output.synchronize()
        return hasher.finish()
    }

    enum CopyError: Error, Equatable {
        case cannotReadSource
        case cannotWriteDestination
        case checksumMismatch
        case destinationExists
        case cancelled
    }

    private func message(for error: Error) -> String {
        switch error {
        case CopyError.cannotReadSource: return "could not be read – is the drive still connected?"
        case CopyError.cannotWriteDestination: return "could not be written into the library"
        case CopyError.checksumMismatch: return "checksum mismatch – the copy differs from the original"
        case CopyError.destinationExists: return "a file of that name is already in the library folder"
        case CopyError.cancelled: return "cancelled"
        case Failure.cannotCreateFolder(let name): return "the folder for “\(name)” could not be created"
        default: return (error as NSError).localizedDescription
        }
    }

    // MARK: Before the first byte

    private func checkSpace(for options: Options) throws {
        let needed = options.plan.requiredBytes
        guard let available = freeSpace(options.library.root) else { return }
        guard available >= needed else {
            throw Failure.notEnoughSpace(needed: needed, available: available)
        }
    }

    private func makeFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreateFolder(url.lastPathComponent)
        }
    }

    /// Leftovers from a cancelled or failed run, anywhere under the library.
    /// They are never books, so they go; the books they would have become are
    /// simply not in the index.
    private func removePartials(in root: URL) {
        guard
            let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        // Hidden files are skipped by the enumerator, and the partials are
        // hidden, so the folders are walked and the names checked directly.
        for case let url as URL in walker where url.hasDirectoryPath {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names where name.hasPrefix(Self.partialPrefix) && name.hasSuffix(".part") {
                try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
            }
        }
    }

    private func estimate(done: Int64, total: Int64, since started: Date) -> TimeInterval? {
        guard done > 0, total > done else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 0.5 else { return nil }
        return elapsed / Double(done) * Double(total - done)
    }
}
