import AppKit
import Observation
import ShelfCore

/// The state of the import sheet: what was found, what the plan is, and how far
/// a run has got.
///
/// It is its own model rather than part of `LibraryModel` so a run survives the
/// sheet being closed and reopened – the same reason Selector's `IngestModel`
/// is separate.
///
/// The value the user confirms is the value the runner is handed: the counting
/// protocol and the run are the same `ImportPlan` (Leitlinie: "Importe mit
/// Zählprotokoll").
@MainActor
@Observable
final class ImportModel {
    enum Phase: Equatable {
        case idle
        /// Reading the files: metadata, covers and digests.
        case examining(done: Int, total: Int)
        /// The plan is ready and waiting for the user.
        case ready
        case running(ImportRunner.Progress)
        case finished(ImportReport)

        var isBusy: Bool {
            switch self {
            case .examining, .running: return true
            case .idle, .ready, .finished: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var plan = ImportPlan.empty
    /// Where the files came from, in the words the report uses.
    private(set) var sourceDescription = ""
    private(set) var errorMessage: String?
    /// Where the library's counter stands after a run.
    private(set) var nextBookNumber = 1
    /// The books the run added, for the model to put into the index.
    private(set) var imported: [LibraryEntry] = []

    private let library: Library
    @ObservationIgnored private let index: LibraryIndex
    @ObservationIgnored private var candidates: [ImportCandidate] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(library: Library, index: LibraryIndex) {
        self.library = library
        self.index = index
        nextBookNumber = (try? library.readDescriptor().nextBookNumber) ?? 1
    }

    // MARK: Examining

    /// Reads the dropped files and works out the plan. Nothing is written.
    func examine(_ urls: [URL]) async {
        task?.cancel()
        reset()
        let files = Self.books(in: urls)
        sourceDescription = Self.describe(urls, fileCount: files.count)

        guard !files.isEmpty else {
            phase = .idle
            errorMessage =
                "No books in what you chose. Shelf reads "
                + BookFileFormat.importable.map { $0.rawValue.uppercased() }.joined(separator: ", ") + "."
            return
        }

        phase = .examining(done: 0, total: files.count)
        // Detached so reading several thousand files does not block the window.
        // `ImportCandidate` is `Sendable`, so the result crosses back cleanly.
        let read = await Task.detached(priority: .userInitiated) { () -> [ImportCandidate] in
            var result: [ImportCandidate] = []
            result.reserveCapacity(files.count)
            for url in files {
                if Task.isCancelled { return result }
                if let candidate = Self.candidate(for: url) { result.append(candidate) }
            }
            return result
        }.value

        candidates = read
        await buildPlan()
    }

    private func buildPlan() async {
        do {
            let knowledge = ImportKnowledge(
                digests: try await index.allFormatDigests(),
                isbns: try await index.allISBNs(),
                titleKeys: try await index.allTitleKeys(),
                formatsByBook: try await formatsByBook(),
                foldersByBook: try await foldersByBook())
            let descriptor = try library.readDescriptor()
            nextBookNumber = descriptor.nextBookNumber
            // The stored counter, or the highest number already on the disk if a
            // killed run got further than the descriptor did. It never goes
            // backwards, so a deleted book's number is still not reused.
            let startingNumber = max(
                descriptor.nextBookNumber, try await index.highestBookNumber() + 1)
            plan = ImportPlanner.plan(
                candidates: candidates,
                knowledge: knowledge,
                startingNumber: startingNumber,
                existingFolders: Self.existingFolders(library))
            phase = .ready
        } catch {
            errorMessage = "Could not read the library index: \((error as NSError).localizedDescription)"
            phase = .idle
        }
    }

    private func formatsByBook() async throws -> [UUID: Set<BookFileFormat>] {
        var result: [UUID: Set<BookFileFormat>] = [:]
        for entry in try await index.allEntries() {
            result[entry.id] = Set(entry.formats.map(\.format))
        }
        return result
    }

    /// Where every book already lives. Without it the planner hands the runner
    /// an empty folder for a format added to a book the library already has,
    /// and the runner refuses rather than writing into the library root
    /// (ADR 0002, decision 8).
    private func foldersByBook() async throws -> [UUID: String] {
        var result: [UUID: String] = [:]
        for entry in try await index.allEntries() {
            result[entry.id] = entry.folder
        }
        return result
    }

    // MARK: Running

    /// Copies the files the plan names, verifying each one.
    func run() async {
        guard case .ready = phase, !plan.isEmpty else { return }
        let runner = ImportRunner(makeHasher: SHA256Hasher.factory)
        let options = ImportRunner.Options(
            library: library, plan: plan, sourceDescription: sourceDescription)
        phase = .running(
            ImportRunner.Progress(
                filesDone: 0, filesTotal: plan.fileCount, bytesDone: 0, bytesTotal: plan.totalBytes,
                currentTitle: ""))

        do {
            // The handle is kept because cancellation does not otherwise reach
            // a detached task.
            // The index is written in batches **while the run goes on**: one
            // transaction for thousands of books holds a lot of memory, one per
            // book would be as many fsyncs, and writing it only at the end
            // meant an import stopped halfway left files on disk that nothing
            // knew about — so the next run copied every one of them again.
            let outcome = try await runner.run(
                options,
                progress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .running = self.phase else { return }
                        self.phase = .running(progress)
                    }
                },
                saveBatch: { try await index.save($0) })
            imported = outcome.entries
            nextBookNumber = outcome.nextBookNumber
            try? outcome.report.append(to: library)
            phase = .finished(outcome.report)
        } catch {
            errorMessage = Self.describe(error)
            phase = .ready
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func reset() {
        phase = .idle
        plan = .empty
        candidates = []
        imported = []
        errorMessage = nil
    }

    // MARK: Reading files

    /// One file into a candidate: metadata, cover and digest.
    ///
    /// `nonisolated` and static because it runs off the main actor: reading a
    /// few thousand EPUBs and hashing them must not touch the window's thread,
    /// and a static method of a `@MainActor` type would be main-actor isolated
    /// like everything else in here.
    nonisolated private static func candidate(for url: URL) -> ImportCandidate? {
        // The format comes from the name the *user* sees; everything else from
        // the file the name points at (`FileFacts` follows symlinks).
        guard let format = BookFileFormat.of(url),
            let facts = FileFacts.of(url),
            let digest = try? FileDigest.sha256(of: facts.url, makeHasher: SHA256Hasher.factory)
        else { return nil }

        if format.hasReadableMetadata, let read = try? EPUBMetadata.read(url: facts.url) {
            return ImportCandidate(
                source: facts.url, byteSize: facts.byteSize, format: format, sha256: digest, book: read.book,
                cover: read.cover, coverName: read.coverName, drm: read.drm, modifiedAt: facts.modifiedAt,
                warnings: read.warnings)
        }
        // Everything else imports by file name in Sprint 1 (CONCEPT §6). The
        // book is still added, and the report says where its metadata came from.
        // The *original* name is used, because that is what the user chose.
        let stem = url.deletingPathExtension().lastPathComponent
        let book = Book(title: FileNameMetadata.title(from: stem), authors: FileNameMetadata.authors(from: stem))
        return ImportCandidate(
            source: facts.url, byteSize: facts.byteSize, format: format, sha256: digest, book: book,
            modifiedAt: facts.modifiedAt,
            warnings: [
                "metadata from the file name – \(format.rawValue.uppercased()) is read from Sprint 4 on"
            ])
    }

    /// Every book file in what was chosen: the files themselves, and the
    /// contents of any folder, recursively.
    private static func books(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                guard
                    let walker = FileManager.default.enumerator(
                        at: url, includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
                else { continue }
                for case let file as URL in walker where BookFileFormat.of(file) != nil {
                    found.append(file)
                }
            } else if BookFileFormat.of(url) != nil {
                found.append(url)
            }
        }
        // Sorted and de-duplicated: dropping a folder and one of its files at
        // once must not import that file twice.
        return Array(Set(found)).sorted { $0.path < $1.path }
    }

    private static func existingFolders(_ library: Library) -> Set<String> {
        let manager = FileManager.default
        guard let authors = try? manager.contentsOfDirectory(atPath: library.root.path) else { return [] }
        var result: Set<String> = []
        for author in authors where author != Library.privateFolderName {
            let authorURL = library.root.appendingPathComponent(author)
            guard authorURL.hasDirectoryPath,
                let books = try? manager.contentsOfDirectory(atPath: authorURL.path)
            else { continue }
            for book in books { result.insert("\(author)/\(book)") }
        }
        return result
    }

    private static func describe(_ urls: [URL], fileCount: Int) -> String {
        if urls.count == 1, let first = urls.first {
            return first.hasDirectoryPath
                ? first.path : "\(fileCount) file(s) from \(first.deletingLastPathComponent().path)"
        }
        return "\(fileCount) file(s) from \(urls.count) place(s)"
    }

    private static func describe(_ error: any Error) -> String {
        if case ImportRunner.Failure.notEnoughSpace(let needed, let available) = error {
            return "Not enough room: \(ByteCount.format(needed)) needed, \(ByteCount.format(available)) free. "
                + "Nothing was copied."
        }
        return (error as NSError).localizedDescription
    }
}

extension Array {
    /// Runs of at most `size`, for writing the index in transactions that are
    /// neither one per book nor one for all of them.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
