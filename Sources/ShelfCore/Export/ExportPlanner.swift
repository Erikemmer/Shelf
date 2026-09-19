import Foundation

/// One file an export would write.
public struct ExportOperation: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        /// A book file, copied or linked out of the library.
        case bookFile
        /// `cover.jpg`, copied.
        case cover
        /// `metadata.opf`, rendered fresh — because the Calibre mapping and
        /// the chosen structure can change what it should say.
        case opf

        public var label: String {
            switch self {
            case .bookFile: return "book files"
            case .cover: return "covers"
            case .opf: return "metadata files"
            }
        }
    }

    /// What a second run has to decide about each file.
    public enum State: String, Sendable, CaseIterable {
        case new
        /// The library's copy differs from what the manifest says was written.
        case changed
        /// Already there and the same. Nothing is written and nothing is read.
        case unchanged

        public var label: String {
            switch self {
            case .new: return "new"
            case .changed: return "changed"
            case .unchanged: return "unchanged"
            }
        }
    }

    public var bookID: UUID
    public var title: String
    public var kind: Kind
    /// In the library, absolute. `nil` for an OPF, which is rendered rather
    /// than copied.
    public var source: URL?
    /// Relative to the destination folder.
    public var destinationPath: String
    public var byteSize: Int64
    /// The library's digest, which is what decides `state` on the next run.
    public var sha256: String
    public var state: State
    /// For an OPF, the very text that was hashed — so what the manifest
    /// records and what lands on the disk cannot be two different strings.
    /// `nil` for everything that is copied rather than rendered.
    public var renderedText: String?

    public var id: String { destinationPath }

    public init(
        bookID: UUID, title: String, kind: Kind, source: URL?, destinationPath: String,
        byteSize: Int64, sha256: String, state: State, renderedText: String? = nil
    ) {
        self.bookID = bookID
        self.title = title
        self.kind = kind
        self.source = source
        self.destinationPath = destinationPath
        self.byteSize = byteSize
        self.sha256 = sha256
        self.state = state
        self.renderedText = renderedText
    }
}

/// A book that will not be written out, and why.
public struct SkippedExport: Equatable, Sendable, Identifiable {
    public var bookID: UUID
    public var title: String
    public var reason: Reason

    public var id: UUID { bookID }

    public enum Reason: String, Sendable, CaseIterable {
        /// None of its formats was ticked.
        case noChosenFormat
        /// The file the index names is not in the library folder.
        case fileMissing

        public var label: String {
            switch self {
            case .noChosenFormat: return "none of its formats was chosen"
            case .fileMissing: return "the file is not in the library folder"
            }
        }
    }

    public init(bookID: UUID, title: String, reason: Reason) {
        self.bookID = bookID
        self.title = title
        self.reason = reason
    }
}

/// The counting protocol: what an export would write, before it writes it.
public struct ExportPlan: Equatable, Sendable {
    /// The same 5 % headroom the import and the transfer use.
    public static let freeSpaceMargin = 1.05

    public var operations: [ExportOperation]
    public var skipped: [SkippedExport]
    public var options: ExportOptions
    /// Files a previous run of *this* export wrote that this one no longer
    /// produces — a book whose title has changed since, and whose file
    /// therefore has a new name.
    ///
    /// They have to go, and the proof run is why. Left in place, the
    /// destination holds the book twice: once under its old name with its old
    /// `metadata.opf`, once under its new. Importing such a folder, the older
    /// copy sorts first, is read first, and wins — so a re-import came back
    /// with titles the library had changed weeks earlier. An export that does
    /// not tidy its own output is not an archive, it is an accumulation.
    ///
    /// Only ever paths a previous manifest names, so nothing a person put in
    /// that folder is ever a candidate — and only when the file is still the
    /// size the manifest recorded, so a file somebody has replaced is left
    /// alone and named instead.
    public var stale: [ExportManifest.Entry]
    /// Set when the destination holds a manifest written with *other* options,
    /// so "unchanged" could not be trusted and everything is being written
    /// again. Named rather than silent: a full rewrite that was expected to be
    /// an increment is exactly the surprise worth a sentence.
    public var optionsChanged: Bool

    public init(
        operations: [ExportOperation] = [], skipped: [SkippedExport] = [],
        options: ExportOptions = ExportOptions(), stale: [ExportManifest.Entry] = [],
        optionsChanged: Bool = false
    ) {
        self.operations = operations
        self.skipped = skipped
        self.options = options
        self.stale = stale
        self.optionsChanged = optionsChanged
    }

    public static let empty = ExportPlan()

    /// Only what actually has to be written.
    public var toWrite: [ExportOperation] { operations.filter { $0.state != .unchanged } }
    public var isEmpty: Bool { toWrite.isEmpty }

    public func count(of state: ExportOperation.State) -> Int {
        operations.count { $0.state == state }
    }

    public func count(of kind: ExportOperation.Kind, state: ExportOperation.State? = nil) -> Int {
        operations.count { $0.kind == kind && (state == nil || $0.state == state) }
    }

    public var bookCount: Int { Set(operations.filter { $0.kind == .bookFile }.map(\.bookID)).count }
    public var bytesToWrite: Int64 { toWrite.reduce(0) { $0 + $1.byteSize } }
    public var requiredBytes: Int64 {
        Int64((Double(bytesToWrite) * Self.freeSpaceMargin).rounded(.up))
    }

    /// "412 books · 37 new · 4 changed · 371 unchanged · 1.2 GB to write".
    public func summary() -> String {
        guard !operations.isEmpty else { return "Nothing to export" }
        var parts = ["\(bookCount) book\(bookCount == 1 ? "" : "s")"]
        for state in ExportOperation.State.allCases where count(of: state) > 0 {
            parts.append("\(count(of: state)) \(state.label)")
        }
        if bytesToWrite > 0 { parts.append("\(ByteCount.format(bytesToWrite)) to write") }
        if !stale.isEmpty { parts.append("\(stale.count) no longer wanted") }
        if !skipped.isEmpty { parts.append("\(skipped.count) left out") }
        return parts.joined(separator: " · ")
    }

    public func fits(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes >= requiredBytes
    }
}

/// Works out every file an export would write.
///
/// Pure, and for the usual reason: which formats go, what each file is called,
/// whether a second run has anything to do, what an unwritable book is — each
/// of those is a rule that can be wrong, and none of them is about a disk.
public enum ExportPlanner {

    public static func plan(
        entries: [LibraryEntry],
        libraryRoot: URL,
        options: ExportOptions,
        /// What a previous export left at the destination.
        manifest: ExportManifest = ExportManifest(),
        /// Whether a source file is really in the library folder.
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        /// The cover in a book's folder, if it has one. Its own closure
        /// because "which of six extensions is it" is a disk question.
        coverFile: (URL) -> URL? = { CoverFile.url(in: $0) }
    ) -> ExportPlan {
        var operations: [ExportOperation] = []
        var skipped: [SkippedExport] = []
        var takenPaths: Set<String> = []

        // A manifest written with other options describes a differently shaped
        // destination, so nothing in it can be believed about this one.
        let optionsChanged = !manifest.isEmpty && manifest.options != options
        let known = optionsChanged ? [:] : manifest.byPath

        for entry in entries.sorted(by: { $0.book.title < $1.book.title }) {
            let book = entry.book
            let folder = libraryRoot.appendingPathComponent(entry.folder, isDirectory: true)
            let chosen = entry.formats.filter { options.includes($0.format) }
            guard !chosen.isEmpty else {
                skipped.append(.init(bookID: book.id, title: book.title, reason: .noChosenFormat))
                continue
            }

            let present = chosen.filter { fileExists(folder.appendingPathComponent($0.fileName)) }
            guard !present.isEmpty else {
                skipped.append(.init(bookID: book.id, title: book.title, reason: .fileMissing))
                continue
            }

            let bookFolder = destinationFolder(for: entry, options: options)
            for format in present.sorted(by: { $0.format < $1.format }) {
                let name = NamePattern.name(
                    for: entry, pattern: options.namePattern, extension: format.format.fileExtension)
                let path = unique(join(bookFolder, name), avoiding: &takenPaths)
                operations.append(
                    .init(
                        bookID: book.id, title: book.title, kind: .bookFile,
                        source: folder.appendingPathComponent(format.fileName),
                        destinationPath: path, byteSize: format.byteSize, sha256: format.sha256,
                        state: state(of: path, digest: format.sha256, in: known)))
            }

            if options.includesCover, let cover = coverFile(folder) {
                // Named for the book rather than always `cover.jpg`, because a
                // flat export would otherwise have one cover for the whole
                // folder — and in a per-book folder the two names are the same
                // thing to everything that reads one.
                let name =
                    options.structure == .flat
                    ? NamePattern.name(
                        for: entry, pattern: options.namePattern,
                        extension: cover.pathExtension)
                    : "\(CoverFile.baseName).\(cover.pathExtension)"
                let path = unique(join(bookFolder, name), avoiding: &takenPaths)
                let facts = FileFacts.of(cover)
                operations.append(
                    .init(
                        bookID: book.id, title: book.title, kind: .cover, source: cover,
                        destinationPath: path, byteSize: facts?.byteSize ?? 0,
                        // The cover's digest is not in the index, so "has it
                        // changed" is answered by size and modification date —
                        // the same cheap question `IndexRebuilder` asks before
                        // it re-hashes a book file.
                        sha256: facts.map { "\($0.byteSize)-\(Int($0.modifiedAt.timeIntervalSince1970))" } ?? "",
                        state: state(
                            of: path,
                            digest: facts.map { "\($0.byteSize)-\(Int($0.modifiedAt.timeIntervalSince1970))" } ?? "",
                            in: known)))
            }

            if options.includesOPF {
                let path = unique(
                    join(
                        bookFolder,
                        options.structure == .flat
                            ? NamePattern.name(for: entry, pattern: options.namePattern, extension: "opf")
                            : OPFDocument.fileName),
                    avoiding: &takenPaths)
                let text = opfText(for: entry, options: options)
                // Portable rather than CryptoKit: the planner is pure core
                // and builds on Linux, and this digest is only ever compared
                // with another one this same code made.
                let digest = FileDigest.sha256(
                    of: Data(text.utf8), makeHasher: PortableSHA256Hasher.factory)
                operations.append(
                    .init(
                        bookID: book.id, title: book.title, kind: .opf, source: nil,
                        destinationPath: path, byteSize: Int64(text.utf8.count), sha256: digest,
                        state: state(of: path, digest: digest, in: known), renderedText: text))
            }
        }

        // Whatever the last run wrote and this one does not.
        let wanted = Set(operations.map(\.destinationPath))
        let stale = manifest.entries
            .filter { !wanted.contains($0.path) }
            .sorted { $0.path < $1.path }

        return ExportPlan(
            operations: operations, skipped: skipped, options: options, stale: stale,
            optionsChanged: optionsChanged)
    }

    /// The OPF text one book gets in the export. Rendered rather than copied,
    /// because the Calibre mapping changes what it should say — and because a
    /// copied OPF would carry a cover path that the export's own structure may
    /// have changed.
    public static func opfText(for entry: LibraryEntry, options: ExportOptions) -> String {
        let book = options.mapsShelvesToTags ? CalibreTagMapping.mapped(entry.book) : entry.book
        return OPFDocument.render(book)
    }

    static func destinationFolder(for entry: LibraryEntry, options: ExportOptions) -> String {
        switch options.structure {
        case .flat: return ""
        case .authorTitle:
            return BookFolderName.relativePath(for: entry.book, number: entry.number)
        }
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    /// Two books can share an author and a title, and a flat export has no
    /// running number to keep them apart — the same problem a device has, and
    /// the same answer: a suffix (`TransferPlanner.uniqueName`).
    ///
    /// Case-insensitively, because the destination may be a FAT card and two
    /// names differing only in case would be one file there.
    static func unique(_ path: String, avoiding taken: inout Set<String>) -> String {
        guard taken.contains(path.lowercased()) else {
            taken.insert(path.lowercased())
            return path
        }
        let ext = (path as NSString).pathExtension
        let stem = ext.isEmpty ? path : String(path.dropLast(ext.count + 1))
        var attempt = 2
        var candidate = path
        repeat {
            candidate = ext.isEmpty ? "\(stem) (\(attempt))" : "\(stem) (\(attempt)).\(ext)"
            attempt += 1
        } while taken.contains(candidate.lowercased())
        taken.insert(candidate.lowercased())
        return candidate
    }

    static func state(
        of path: String, digest: String, in known: [String: ExportManifest.Entry]
    ) -> ExportOperation.State {
        guard let previous = known[path] else { return .new }
        return previous.sha256 == digest ? .unchanged : .changed
    }
}
