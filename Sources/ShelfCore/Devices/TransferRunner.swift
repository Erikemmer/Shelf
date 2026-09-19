import Foundation

/// Copies a transfer plan onto a device and proves every copy arrived intact.
///
/// The same pattern as `ImportRunner`, and for the same reason
/// ([ADR 0002](../../../docs/adr/0002-copy-verify-then-trust.md)): the file is
/// written under a `.part` name, the source is hashed while it is read for the
/// copy, the file on the device is read back and hashed, and only if the two
/// digests agree is it renamed into place and written into the manifest. "The
/// copy call returned success" is not the same as "the file is on the card",
/// and on a USB card it is a good deal further from it than on a disk.
///
/// What is different from the import, and deliberately so:
///
/// * **The library is only ever read.** Nothing here writes into it, not even
///   a read-status. What comes *back* off a Kobo is a separate, read-only step.
/// * **Nothing on the device is ever deleted.** A run that is cancelled takes
///   away its own `.part` files and nothing else; deleting a book from a
///   device is its own menu item with its own confirmation
///   ([ADR 0014](../../../docs/adr/0014-deleting-on-a-device-needs-a-named-confirmation.md)).
/// * **A file that is already there is not overwritten.** The planner has made
///   the name unique against the plan; a name that exists on the card anyway
///   means something Shelf did not put there, and writing over somebody's file
///   is the one thing this must not do.
public struct TransferRunner: Sendable {
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
        public var device: ConnectedDevice
        public var plan: TransferPlan
        public var manifest: DeviceManifest

        public init(device: ConnectedDevice, plan: TransferPlan, manifest: DeviceManifest) {
            self.device = device
            self.plan = plan
            self.manifest = manifest
        }
    }

    public struct Progress: Sendable, Equatable {
        public var filesDone: Int
        public var filesTotal: Int
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var currentTitle: String

        public init(filesDone: Int, filesTotal: Int, bytesDone: Int64, bytesTotal: Int64, currentTitle: String) {
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
        public var report: TransferReport
        /// The manifest as it now stands, already written to the device.
        public var manifest: DeviceManifest
    }

    /// Every `.part` file this runner makes starts with this, so a cancelled
    /// run can find its own leftovers and nothing else is ever mistaken for one.
    public static let partialPrefix = ".shelf-send-"

    /// Runs the plan. A file that fails is a line in the report; only a
    /// problem that makes the whole run pointless is thrown.
    public func run(
        _ options: Options,
        progress: @Sendable @escaping (Progress) -> Void = { _ in },
        /// Called after each verified file, with the manifest as it stands.
        /// The manifest is written to the device **as the run goes on** for the
        /// same reason the index is: a run that is cut off must leave a device
        /// that describes itself, or the next run copies everything again.
        checkpoint: @Sendable (DeviceManifest) -> Void = { _ in }
    ) async throws -> Outcome {
        let started = Date()
        try checkSpace(for: options)

        var manifest = options.manifest
        // Files the planner recognised on the card as ones Shelf wrote itself
        // and then lost track of. Recording them before the first copy means a
        // run interrupted *again* still leaves the card describing itself.
        for entry in options.plan.adopted { manifest.record(entry) }
        if !options.plan.adopted.isEmpty {
            try? manifest.write(toVolume: options.device.volume.url)
            checkpoint(manifest)
        }
        var verified: [TransferReport.Sent] = []
        var failures: [TransferReport.Failure] = []
        var copiedBytes: Int64 = 0
        var done: Int64 = 0
        let total = options.plan.totalBytes
        let volume = options.device.volume.url
        var sinceLastWrite = 0

        for (index, operation) in options.plan.operations.enumerated() {
            if Task.isCancelled { break }
            progress(
                Progress(
                    filesDone: index, filesTotal: options.plan.fileCount, bytesDone: done,
                    bytesTotal: total, currentTitle: operation.title))

            do {
                let destination = volume.appendingPathComponent(operation.destinationPath)
                try makeFolder(destination.deletingLastPathComponent())
                let digest = try copyAndVerify(from: operation.source, to: destination)
                manifest.record(
                    .init(
                        path: operation.destinationPath, bookID: operation.bookID, title: operation.title,
                        author: operation.author, format: operation.format, byteSize: operation.byteSize,
                        sha256: digest, sentAt: Date()))
                verified.append(
                    .init(
                        title: operation.title, author: operation.author, format: operation.format,
                        path: operation.destinationPath, byteSize: operation.byteSize))
                copiedBytes += operation.byteSize
                sinceLastWrite += 1
                // Often enough that an interruption costs one file's worth of
                // knowledge, seldom enough that a card is not rewritten per
                // book. A card's write is slow and this file is small.
                if sinceLastWrite >= Self.manifestBatchSize {
                    try? manifest.write(toVolume: volume)
                    checkpoint(manifest)
                    sinceLastWrite = 0
                }
            } catch {
                failures.append(
                    .init(title: operation.title, path: operation.destinationPath, message: message(for: error)))
            }
            done += operation.byteSize
        }

        // Whatever happened, the device is left describing itself and with
        // nothing half-written on it.
        try? manifest.write(toVolume: volume)
        checkpoint(manifest)
        removePartials(under: options.device.booksFolder)
        removePartials(under: volume)

        if Task.isCancelled {
            let remaining = options.plan.fileCount - verified.count - failures.count
            if remaining > 0 {
                failures.append(
                    .init(title: "—", path: "—", message: "cancelled with \(remaining) books still to send"))
            }
        }

        let report = TransferReport(
            deviceName: options.device.name,
            profileName: options.device.profile.name,
            startedAt: started,
            duration: Date().timeIntervalSince(started),
            sent: verified,
            skipped: options.plan.skipped,
            failures: failures,
            copiedBytes: copiedBytes)
        return Outcome(report: report, manifest: manifest)
    }

    /// How many files go by before the manifest is written again.
    public static let manifestBatchSize = 20

    // MARK: Copying

    private func copyAndVerify(from source: URL, to destination: URL) throws -> String {
        // Short and random, like the import's: a device file name may already
        // use the whole 255-unit budget, and a prefix on it would push the
        // temporary name over the limit for exactly the longest titles.
        let partial =
            destination
            .deletingLastPathComponent()
            .appendingPathComponent("\(Self.partialPrefix)\(UUID().uuidString.prefix(8)).part")
        try? FileManager.default.removeItem(at: partial)

        let sourceDigest = try copy(from: source, to: partial)
        // Read back from the *device*, not from the buffer that wrote it. That
        // is the whole point: a card that accepted the write and lost it is
        // exactly the failure this catches.
        let writtenDigest = try FileDigest.sha256(of: partial, makeHasher: makeHasher)
        guard sourceDigest == writtenDigest else {
            try? FileManager.default.removeItem(at: partial)
            throw CopyError.checksumMismatch
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            try? FileManager.default.removeItem(at: partial)
            throw CopyError.destinationExists
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return sourceDigest
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
        case destinationExists
        case cancelled
    }

    private func message(for error: Error) -> String {
        switch error {
        case CopyError.cannotReadSource: return "could not be read out of the library"
        case CopyError.cannotWriteDestination:
            return "could not be written to the device – is it still connected, and is there room?"
        case CopyError.checksumMismatch:
            return "checksum mismatch – what arrived on the device differs from the original"
        case CopyError.destinationExists: return "a file of that name is already on the device"
        case CopyError.cancelled: return "cancelled"
        case Failure.cannotCreateFolder(let name): return "the folder “\(name)” could not be made on the device"
        default: return (error as NSError).localizedDescription
        }
    }

    // MARK: Before the first byte

    private func checkSpace(for options: Options) throws {
        let needed = options.plan.requiredBytes
        guard let available = freeSpace(options.device.volume.url) else { return }
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

    /// This runner's own leftovers, and only those.
    private func removePartials(under root: URL) {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix(Self.partialPrefix), name.hasSuffix(".part") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
