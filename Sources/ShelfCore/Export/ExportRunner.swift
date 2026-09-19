import Foundation

/// Writes an export, and proves every file arrived.
///
/// Copy, verify, then trust, exactly as the import and the transfer do it
/// (ADR 0002): the file goes down under a short random `.part` name, the
/// source is hashed while it is read for the copy, the written file is read
/// back and hashed, and only if the two agree is it renamed into place.
///
/// Two things are its own:
///
/// * **Hard links, where they are possible.** On the same volume a link costs
///   a directory entry and no bytes at all, which turns an archive of a 20 GB
///   library into something somebody will actually run. It is safe here and
///   nowhere else for one reason: **a book file is never written** (CONCEPT
///   §4), so the two names cannot diverge. Across a volume boundary it is a
///   copy, without asking.
/// * **The OPF is rendered, not copied.** The Calibre mapping and the export's
///   own structure both change what it should say.
public struct ExportRunner: Sendable {
    private let makeHasher: HasherFactory
    private let freeSpace: FreeSpaceProbe

    public init(
        makeHasher: @escaping HasherFactory,
        freeSpace: @escaping FreeSpaceProbe = FileManager.defaultFreeSpaceProbe
    ) {
        self.makeHasher = makeHasher
        self.freeSpace = freeSpace
    }

    public static let partialPrefix = ".shelf-export-"

    public struct Options: Sendable {
        public var destination: URL
        public var plan: ExportPlan
        public var libraryName: String

        public init(destination: URL, plan: ExportPlan, libraryName: String) {
            self.destination = destination
            self.plan = plan
            self.libraryName = libraryName
        }
    }

    public struct Progress: Sendable, Equatable {
        public var filesDone: Int
        public var filesTotal: Int
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var currentTitle: String

        public init(
            filesDone: Int, filesTotal: Int, bytesDone: Int64, bytesTotal: Int64, currentTitle: String
        ) {
            self.filesDone = filesDone
            self.filesTotal = filesTotal
            self.bytesDone = bytesDone
            self.bytesTotal = bytesTotal
            self.currentTitle = currentTitle
        }

        public var fractionDone: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
    }

    public enum Failure: Error, Equatable {
        case notEnoughSpace(needed: Int64, available: Int64)
        case cannotCreateFolder(String)
    }

    public struct Outcome: Sendable {
        public var report: ExportReport
        public var manifest: ExportManifest
    }

    /// Runs the plan. A file that fails is a line in the report; only a
    /// problem that makes the whole run pointless is thrown.
    public func run(
        _ options: Options,
        manifest existing: ExportManifest = ExportManifest(),
        progress: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> Outcome {
        let started = Date()
        try checkSpace(for: options)

        let destination = options.destination
        try makeFolder(destination)
        // A run with other options describes a differently shaped destination,
        // so the old rows are not carried over.
        var manifest = ExportManifest(
            writtenAt: started, options: options.plan.options,
            entries: options.plan.optionsChanged ? [] : existing.entries)

        // Whether a link is even possible is a fact about the two volumes,
        // asked once rather than per file.
        let canLink =
            options.plan.options.prefersHardLinks
            && sameVolume(
                options.plan.operations.compactMap(\.source).first, destination)

        var written: [ExportReport.Written] = []
        var failures: [ExportReport.Failure] = []
        var linked = 0
        var bytes: Int64 = 0
        var done: Int64 = 0
        let work = options.plan.toWrite
        let total = work.reduce(0) { $0 + $1.byteSize }

        for (index, operation) in work.enumerated() {
            if Task.isCancelled { break }
            progress(
                Progress(
                    filesDone: index, filesTotal: work.count, bytesDone: done, bytesTotal: total,
                    currentTitle: operation.title))
            do {
                let target = destination.appendingPathComponent(operation.destinationPath)
                try makeFolder(target.deletingLastPathComponent())
                let wasLinked = try write(operation, to: target, mayLink: canLink)
                if wasLinked { linked += 1 } else { bytes += operation.byteSize }
                manifest.record(
                    .init(
                        path: operation.destinationPath, bookID: operation.bookID,
                        sha256: operation.sha256, byteSize: operation.byteSize,
                        isHardLink: wasLinked))
                written.append(
                    .init(
                        title: operation.title, kind: operation.kind, state: operation.state,
                        path: operation.destinationPath, byteSize: operation.byteSize,
                        isHardLink: wasLinked))
            } catch {
                failures.append(
                    .init(
                        title: operation.title, path: operation.destinationPath,
                        message: message(for: error)))
            }
            done += operation.byteSize
        }

        // What the last run wrote and this one does not want. Shelf's own
        // output, at paths its own manifest names, and only while the file is
        // still the size that manifest recorded.
        var removed: [String] = []
        var keptBack: [String] = []
        for entry in options.plan.stale {
            let url = destination.appendingPathComponent(entry.path)
            guard let facts = FileFacts.of(url) else {
                manifest.entries.removeAll { $0.path == entry.path }
                continue
            }
            guard facts.byteSize == entry.byteSize else {
                // Somebody has changed it. It is theirs now.
                keptBack.append(entry.path)
                continue
            }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(entry.path)
                manifest.entries.removeAll { $0.path == entry.path }
            }
        }

        // The folder a removed file leaves empty goes too — the same guard as
        // `OrganizeRunner`'s: it must be inside the destination, must not be
        // the destination itself, and must hold nothing at all. Without this a
        // library exported repeatedly grows a book folder per title anybody
        // ever corrected.
        for path in removed {
            var folder = destination.appendingPathComponent(path).deletingLastPathComponent()
            while folder.path != destination.path, folder.path.hasPrefix(destination.path) {
                guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                    contents.isEmpty, (try? FileManager.default.removeItem(at: folder)) != nil
                else { break }
                folder = folder.deletingLastPathComponent()
            }
        }

        try? manifest.write(at: destination)
        removePartials(in: destination)

        let report = ExportReport(
            libraryName: options.libraryName,
            destination: destination,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            written: written,
            unchanged: options.plan.count(of: .unchanged),
            skipped: options.plan.skipped,
            failures: failures,
            copiedBytes: bytes,
            hardLinkCount: linked,
            options: options.plan.options,
            removed: removed.sorted(),
            keptBack: keptBack.sorted())
        try? report.append(at: destination)
        return Outcome(report: report, manifest: manifest)
    }

    // MARK: One file

    /// Returns whether it was linked rather than copied.
    private func write(_ operation: ExportOperation, to target: URL, mayLink: Bool) throws -> Bool {
        // An OPF has no source: it is the text the *planner* rendered, and
        // carried here rather than rendered again, so that what the manifest
        // recorded the digest of is byte for byte what lands on the disk.
        guard let source = operation.source else {
            try writeAtomically(Data((operation.renderedText ?? "").utf8), to: target)
            return false
        }

        if mayLink {
            // Nothing is ever written over, here as everywhere: the old link
            // is taken away first and only then is the new one made, so a
            // failure leaves no half-linked name.
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.linkItem(at: source, to: target)
                return true
            } catch {
                // A link can fail for reasons a copy will not — a destination
                // that turned out to be another volume after all, a file
                // system with no links. Falling back is better than failing a
                // book over an optimisation.
            }
        }

        let partial = target.deletingLastPathComponent()
            .appendingPathComponent("\(Self.partialPrefix)\(UUID().uuidString.prefix(8)).part")
        try? FileManager.default.removeItem(at: partial)
        let sourceDigest = try copy(from: source, to: partial)
        let writtenDigest = try FileDigest.sha256(of: partial, makeHasher: makeHasher)
        guard sourceDigest == writtenDigest else {
            try? FileManager.default.removeItem(at: partial)
            throw CopyError.checksumMismatch
        }
        // An export *does* replace what it wrote last time, which is the one
        // place this program overwrites anything — and it is overwriting its
        // own output at its own manifest's own path, never a book.
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return false
    }

    private func writeAtomically(_ data: Data, to target: URL) throws {
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent("\(Self.partialPrefix)\(UUID().uuidString.prefix(8)).part")
        try data.write(to: partial, options: .atomic)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }

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
        case cancelled
    }

    private func message(for error: Error) -> String {
        switch error {
        case CopyError.cannotReadSource: return "could not be read out of the library"
        case CopyError.cannotWriteDestination:
            return "could not be written — is there room, and is the folder writable?"
        case CopyError.checksumMismatch:
            return "checksum mismatch — what arrived differs from what left"
        case CopyError.cancelled: return "cancelled"
        case Failure.cannotCreateFolder(let name): return "the folder “\(name)” could not be made"
        default: return (error as NSError).localizedDescription
        }
    }

    // MARK: Before the first byte

    private func checkSpace(for options: Options) throws {
        // A link needs no room, so the question is only about what is copied.
        let needed = options.plan.requiredBytes
        guard let available = freeSpace(options.destination) else { return }
        guard available >= needed else {
            throw Failure.notEnoughSpace(needed: needed, available: available)
        }
    }

    /// Whether two paths are on one volume, which is what decides whether a
    /// hard link is even possible. Asked of the file system rather than
    /// guessed from the path: `/Volumes/…` is a good hint and a firmlink is a
    /// counter-example.
    func sameVolume(_ one: URL?, _ other: URL) -> Bool {
        guard let one else { return false }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let first = try? one.resourceValues(forKeys: keys).volumeIdentifier,
            let second = try? other.resourceValues(forKeys: keys).volumeIdentifier
        else { return false }
        return first.isEqual(second)
    }

    private func makeFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreateFolder(url.lastPathComponent)
        }
    }

    /// This runner's own leftovers, one level down and only inside the
    /// destination it was given.
    private func removePartials(in destination: URL) {
        guard let walker = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)
        else { return }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.partialPrefix), name.hasSuffix(".part") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
