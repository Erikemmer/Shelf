import Foundation

/// One book offered to a device, with its files already located.
public struct TransferCandidate: Equatable, Sendable {
    public var entry: LibraryEntry
    /// The book's folder in the library, absolute. The planner never opens it;
    /// it only builds the paths the runner will read.
    public var folder: URL

    public init(entry: LibraryEntry, folder: URL) {
        self.entry = entry
        self.folder = folder
    }

    public func url(of format: BookFormat) -> URL {
        folder.appendingPathComponent(format.fileName)
    }
}

/// One file the transfer will copy.
public struct TransferOperation: Equatable, Sendable, Identifiable {
    public var bookID: UUID
    public var title: String
    public var author: String
    public var format: BookFileFormat
    /// In the library. Only ever read.
    public var source: URL
    /// On the volume, relative to its root.
    public var destinationPath: String
    public var byteSize: Int64
    /// What the index says the source's digest is, so the runner can compare
    /// without hashing the library file twice.
    public var sourceDigest: String

    public var id: String { destinationPath }

    public init(
        bookID: UUID, title: String, author: String, format: BookFileFormat, source: URL,
        destinationPath: String, byteSize: Int64, sourceDigest: String
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.format = format
        self.source = source
        self.destinationPath = destinationPath
        self.byteSize = byteSize
        self.sourceDigest = sourceDigest
    }
}

/// A book the transfer will not send, and why — in the words the sheet shows.
public struct SkippedTransfer: Equatable, Sendable, Identifiable {
    public var bookID: UUID
    public var title: String
    public var reason: Reason

    public var id: UUID { bookID }

    public enum Reason: String, Sendable, CaseIterable {
        /// The device reads none of the formats this book is held in. Shelf
        /// converts nothing in v1.0 (CONCEPT §4, "Won't"), so this is an
        /// answer and not a step towards one.
        case noCompatibleFormat
        /// The very bytes are on the device already.
        case alreadyOnDevice
        /// FAT32 cannot hold a file of 4 GB, whatever the card's size says.
        case tooBigForTheFileSystem
        /// The file the index names is not in the library folder.
        case fileMissing

        public var label: String {
            switch self {
            case .noCompatibleFormat: return "cannot be sent: no compatible format"
            case .alreadyOnDevice: return "already on the device"
            case .tooBigForTheFileSystem: return "cannot be sent: too big for this device's file system"
            case .fileMissing: return "cannot be sent: the file is not in the library folder"
            }
        }
    }

    public init(bookID: UUID, title: String, reason: Reason) {
        self.bookID = bookID
        self.title = title
        self.reason = reason
    }
}

/// The dry run: what would go to the device, before a byte moves.
///
/// The same shape, and the same argument, as `ImportPlan`: what the person
/// confirms is the value the runner is handed, so the counting protocol and
/// what happens cannot differ.
public struct TransferPlan: Equatable, Sendable {
    /// The same 5 % headroom the import uses.
    public static let freeSpaceMargin = 1.05

    public var operations: [TransferOperation]
    public var skipped: [SkippedTransfer]
    /// Files found on the device that this plan would otherwise have written,
    /// recognised by their bytes as ones Shelf put there itself.
    ///
    /// They are skipped as `alreadyOnDevice`, and the runner folds them into
    /// the manifest before it copies anything. That is what closes the gap a
    /// killed transfer leaves: the manifest is written every twenty files, so
    /// a process that dies without warning can leave up to nineteen books on
    /// the card that no manifest knows about, and before this the next run
    /// reported each of them as a failure (`docs/RUNBOOK.md` §9).
    ///
    /// The digest in each entry was read **off the device**, which is the same
    /// thing "verified" means everywhere else here (ADR 0002).
    public var adopted: [DeviceManifest.Entry]

    public init(
        operations: [TransferOperation] = [], skipped: [SkippedTransfer] = [],
        adopted: [DeviceManifest.Entry] = []
    ) {
        self.operations = operations
        self.skipped = skipped
        self.adopted = adopted
    }

    public static let empty = TransferPlan()

    public var isEmpty: Bool { operations.isEmpty }
    public var fileCount: Int { operations.count }
    public var totalBytes: Int64 { operations.reduce(0) { $0 + $1.byteSize } }
    public var requiredBytes: Int64 { Int64((Double(totalBytes) * Self.freeSpaceMargin).rounded(.up)) }

    public func skipped(for reason: SkippedTransfer.Reason) -> [SkippedTransfer] {
        skipped.filter { $0.reason == reason }
    }

    public func count(of format: BookFileFormat) -> Int {
        operations.count { $0.format == format }
    }

    /// "12 books · EPUB 9 · PDF 3 · 2 cannot be sent · 48.1 MB".
    public func summary() -> String {
        guard !operations.isEmpty || !skipped.isEmpty else { return "Nothing to send" }
        var parts: [String] = []
        if !operations.isEmpty {
            parts.append("\(operations.count) book\(operations.count == 1 ? "" : "s")")
            for format in BookFileFormat.allCases.sorted() where count(of: format) > 0 {
                parts.append("\(format.label) \(count(of: format))")
            }
        }
        let cannot = skipped.count { $0.reason != .alreadyOnDevice }
        if cannot > 0 { parts.append("\(cannot) cannot be sent") }
        let already = skipped(for: .alreadyOnDevice).count
        if already > 0 { parts.append("\(already) already there") }
        if !operations.isEmpty { parts.append(ByteCount.format(totalBytes)) }
        return parts.joined(separator: " · ")
    }

    /// Whether the volume has room, with the margin. `nil` free space means
    /// the file system did not say, and a plan is not refused over a number
    /// nobody has.
    public func fits(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes >= requiredBytes
    }
}

/// Turns a selection of books into a transfer plan.
///
/// Pure — it never touches a file, and the only questions it asks about the
/// disk are ones the caller answers (`fileExists`, `onDevice`). That is what
/// lets every rule in here be tested without a device: which format a Kindle
/// gets, which book cannot be sent at all, what each file ends up called, that
/// nothing is sent twice, and that a file a killed run left behind is
/// recognised rather than reported as a failure.
public enum TransferPlanner {

    public static func plan(
        candidates: [TransferCandidate],
        device: ConnectedDevice,
        manifest: DeviceManifest = DeviceManifest(deviceID: ""),
        /// Whether a source file is really in the library folder. The app
        /// passes `FileManager.fileExists`; a test passes a set.
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        /// What is already at a path on the device. Asked only when a name
        /// this plan produced turns out to be taken, so on a tidy card it is
        /// never asked at all.
        onDevice: DeviceFileProbe = .none,
        /// Stamped into an adopted manifest entry. A parameter so a test can
        /// compare whole entries.
        now: Date = Date()
    ) -> TransferPlan {
        var operations: [TransferOperation] = []
        var skipped: [SkippedTransfer] = []
        var adopted: [DeviceManifest.Entry] = []
        var takenPaths: Set<String> = []
        let profile = device.profile
        let limited = device.volume.hasFAT32FileSizeLimit

        // A stable order, so two runs over one selection produce the same
        // report and the same numbers.
        for candidate in candidates.sorted(by: { $0.entry.book.title < $1.entry.book.title }) {
            let book = candidate.entry.book
            let available = Set(candidate.entry.formats.map(\.format)).filter(profile.accepts)
            guard let chosen = profile.bestFormat(among: available),
                let format = candidate.entry.formats.first(where: { $0.format == chosen })
            else {
                skipped.append(.init(bookID: book.id, title: book.title, reason: .noCompatibleFormat))
                continue
            }

            // The same bytes are already there. By digest, because a file
            // renamed on the device is still the same file — and because the
            // manifest's digest was read back *off the device*, so this is a
            // statement about the card and not about the library.
            if manifest.digests.contains(format.sha256) {
                skipped.append(.init(bookID: book.id, title: book.title, reason: .alreadyOnDevice))
                continue
            }
            if DeviceFileName.isTooBig(format.byteSize, forFAT32: limited) {
                skipped.append(.init(bookID: book.id, title: book.title, reason: .tooBigForTheFileSystem))
                continue
            }
            let source = candidate.url(of: format)
            guard fileExists(source) else {
                skipped.append(.init(bookID: book.id, title: book.title, reason: .fileMissing))
                continue
            }

            let name = uniqueName(
                DeviceFileName.of(book, format: chosen, pattern: profile.fileNamePattern),
                format: chosen, avoiding: &takenPaths, in: profile.booksFolder)

            // Something is already sitting where this book would go. If it is
            // the very book — the same size, and the same digest read off the
            // card — then this is a resume after an untidy death: Shelf wrote
            // that file itself and was killed before the manifest caught up.
            // Reporting it as a failure was the wrong word for "I had already
            // done that" (docs/RUNBOOK.md §9), and leaving it out of the
            // manifest left the card mis-describing itself for good.
            //
            // A file of that name whose bytes are *different* is not touched
            // and not claimed: it may be somebody else's, and the runner still
            // refuses to write over it.
            if let size = onDevice.byteSize(name), size == format.byteSize,
                onDevice.sha256(name) == format.sha256
            {
                skipped.append(.init(bookID: book.id, title: book.title, reason: .alreadyOnDevice))
                adopted.append(
                    .init(
                        path: name, bookID: book.id, title: book.title, author: book.primaryAuthor,
                        format: chosen, byteSize: format.byteSize, sha256: format.sha256, sentAt: now))
                continue
            }

            operations.append(
                .init(
                    bookID: book.id, title: book.title, author: book.primaryAuthor, format: chosen,
                    source: source, destinationPath: name, byteSize: format.byteSize,
                    sourceDigest: format.sha256))
        }
        return TransferPlan(operations: operations, skipped: skipped, adopted: adopted)
    }

    /// The path on the volume, guaranteed not to collide inside this plan.
    ///
    /// Two different books by one author really can share a title, and on a
    /// device there is no running number to keep them apart — the library's
    /// folder name has one and the device's file name deliberately does not,
    /// because a reader shows the file name to its user. So a collision gets a
    /// suffix, which is the same answer the importer gives.
    ///
    /// Case-insensitively, because FAT is: two names differing only in case
    /// are one file on a card, and the second copy would land on the first.
    static func uniqueName(
        _ name: String, format: BookFileFormat, avoiding taken: inout Set<String>, in folder: String
    ) -> String {
        let prefix = folder.isEmpty ? "" : "\(folder)/"
        var candidate = "\(prefix)\(name)"
        guard taken.contains(candidate.lowercased()) else {
            taken.insert(candidate.lowercased())
            return candidate
        }
        let ext = ".\(format.fileExtension)"
        let stem = String(name.dropLast(ext.count))
        var attempt = 2
        repeat {
            candidate = "\(prefix)\(DeviceFileName.truncated("\(stem) (\(attempt))", room: ext))\(ext)"
            attempt += 1
        } while taken.contains(candidate.lowercased())
        taken.insert(candidate.lowercased())
        return candidate
    }
}
