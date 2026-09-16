import Foundation

/// One file offered for import, with everything already read out of it.
///
/// The planner works on values, never on files: that is what lets the whole of
/// "what would this import do" be tested without a disk, and it is what makes
/// the counting protocol the user confirms *the same plan* the runner executes.
public struct ImportCandidate: Equatable, Sendable {
    /// Where the file is now. Never written to, never moved.
    public var source: URL
    public var byteSize: Int64
    public var format: BookFileFormat
    /// Of the file's bytes. The strongest duplicate test there is.
    public var sha256: String
    /// What the file says about itself, or what its name says.
    public var book: Book
    public var cover: Data?
    public var coverName: String?
    public var drm: DRMKind?
    public var modifiedAt: Date
    /// What could not be read. Carried into the report; never a reason to skip.
    public var warnings: [String]

    public init(
        source: URL,
        byteSize: Int64,
        format: BookFileFormat,
        sha256: String,
        book: Book,
        cover: Data? = nil,
        coverName: String? = nil,
        drm: DRMKind? = nil,
        modifiedAt: Date = Date(),
        warnings: [String] = []
    ) {
        self.source = source
        self.byteSize = byteSize
        self.format = format
        self.sha256 = sha256
        self.book = book
        self.cover = cover
        self.coverName = coverName
        self.drm = drm
        self.modifiedAt = modifiedAt
        self.warnings = warnings
    }
}

/// What the library already holds, as far as the planner needs to know.
///
/// A snapshot taken in one go before planning, rather than a question asked per
/// file: 3 000 dropped files would otherwise be 9 000 round trips to SQLite.
public struct ImportKnowledge: Equatable, Sendable {
    /// SHA-256 → the book that file already belongs to.
    public var digests: [String: UUID]
    /// Normalised ISBN → book.
    public var isbns: [String: UUID]
    /// Folded title+author → books. A list, because two different books can
    /// genuinely share both.
    public var titleKeys: [String: [UUID]]
    /// Which formats each book already has, so a second EPUB of the same book
    /// is a duplicate but its AZW3 is a new format.
    public var formatsByBook: [UUID: Set<BookFileFormat>]

    public init(
        digests: [String: UUID] = [:],
        isbns: [String: UUID] = [:],
        titleKeys: [String: [UUID]] = [:],
        formatsByBook: [UUID: Set<BookFileFormat>] = [:]
    ) {
        self.digests = digests
        self.isbns = isbns
        self.titleKeys = titleKeys
        self.formatsByBook = formatsByBook
    }
}

/// What the import will do with one file.
public enum ImportOperation: Equatable, Sendable {
    /// A book the library does not have: its folder is created and the file,
    /// the cover and `metadata.opf` are written into it.
    case newBook(NewBook)
    /// A book it does have, in a format it does not: only the file is copied
    /// into the existing folder, and the OPF is rewritten.
    case addFormat(AddFormat)

    public struct NewBook: Equatable, Sendable {
        public var candidate: ImportCandidate
        /// The running number the folder name gets.
        public var number: Int
        /// Relative to the library root.
        public var folder: String
        public var fileName: String

        public init(candidate: ImportCandidate, number: Int, folder: String, fileName: String) {
            self.candidate = candidate
            self.number = number
            self.folder = folder
            self.fileName = fileName
        }
    }

    public struct AddFormat: Equatable, Sendable {
        public var candidate: ImportCandidate
        public var bookID: UUID
        public var folder: String
        public var fileName: String

        public init(candidate: ImportCandidate, bookID: UUID, folder: String, fileName: String) {
            self.candidate = candidate
            self.bookID = bookID
            self.folder = folder
            self.fileName = fileName
        }
    }

    public var candidate: ImportCandidate {
        switch self {
        case .newBook(let operation): return operation.candidate
        case .addFormat(let operation): return operation.candidate
        }
    }

    public var byteSize: Int64 { candidate.byteSize }
}

/// A file the import will leave alone, and why.
public struct SkippedImport: Equatable, Sendable {
    public var path: String
    public var reason: Reason
    /// The book it duplicates, when that is why.
    public var existingTitle: String?

    public enum Reason: String, Sendable, CaseIterable {
        /// Byte-for-byte the same file the library already has.
        case sameContent
        /// Same ISBN, same format.
        case sameISBN
        /// Same title and author, same format.
        case sameTitleAndAuthor
        /// Two files in this very import are the same book and format.
        case duplicateWithinImport
        /// Not a book format Shelf imports.
        case notABook

        public var label: String {
            switch self {
            case .sameContent: return "already in the library (identical file)"
            case .sameISBN: return "already in the library (same ISBN)"
            case .sameTitleAndAuthor: return "already in the library (same title and author)"
            case .duplicateWithinImport: return "the same book twice in this import"
            case .notABook: return "not a book format Shelf reads"
            }
        }
    }

    public init(path: String, reason: Reason, existingTitle: String? = nil) {
        self.path = path
        self.reason = reason
        self.existingTitle = existingTitle
    }
}

/// The dry run: what would happen, before a single byte is copied.
///
/// This is what the counting protocol in the import sheet shows, and the exact
/// value the runner is handed afterwards – so what the user confirmed and what
/// happens cannot differ (Leitlinie: "Importe mit Zählprotokoll").
public struct ImportPlan: Equatable, Sendable {
    /// Headroom on top of the payload, for the file system's own overhead.
    /// The same 5 % Selector's ingest uses.
    public static let freeSpaceMargin = 1.05

    public var operations: [ImportOperation]
    public var skipped: [SkippedImport]

    public init(operations: [ImportOperation] = [], skipped: [SkippedImport] = []) {
        self.operations = operations
        self.skipped = skipped
    }

    public static let empty = ImportPlan()

    public var isEmpty: Bool { operations.isEmpty }
    public var fileCount: Int { operations.count }
    public var totalBytes: Int64 { operations.reduce(0) { $0 + $1.byteSize } }

    public var newBookCount: Int {
        operations.count { if case .newBook = $0 { return true } else { return false } }
    }
    public var addedFormatCount: Int {
        operations.count { if case .addFormat = $0 { return true } else { return false } }
    }

    public func count(of format: BookFileFormat) -> Int {
        operations.count { $0.candidate.format == format }
    }

    public func skipped(for reason: SkippedImport.Reason) -> [SkippedImport] {
        skipped.filter { $0.reason == reason }
    }

    /// Bytes that must be free before the run may start. Checked up front:
    /// running out of space halfway is the one failure that leaves a library
    /// half-imported.
    public var requiredBytes: Int64 {
        Int64((Double(totalBytes) * Self.freeSpaceMargin).rounded(.up))
    }

    /// The counting protocol, in the words the sheet shows.
    ///
    /// "3 new books · 1 new format · 2 skipped · 14.2 MB" – every number the
    /// user needs to decide whether to press Import.
    public func summary() -> String {
        var parts: [String] = []
        if newBookCount > 0 { parts.append("\(newBookCount) new book\(newBookCount == 1 ? "" : "s")") }
        if addedFormatCount > 0 {
            parts.append("\(addedFormatCount) new format\(addedFormatCount == 1 ? "" : "s")")
        }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if operations.isEmpty && skipped.isEmpty { return "Nothing to import" }
        parts.append(ByteCount.format(totalBytes))
        return parts.joined(separator: " · ")
    }
}

/// Turns a pile of files into a plan.
///
/// Pure – it never touches a file. Everything that makes an import risky lives
/// here, where it can be tested: which files are duplicates, which book a new
/// format belongs to, what each folder is called, and that no two books ever
/// aim at the same folder.
public enum ImportPlanner {

    public static func plan(
        candidates: [ImportCandidate],
        knowledge: ImportKnowledge = ImportKnowledge(),
        /// The library's counter. The planner hands out numbers from here and
        /// the caller stores the value it ends at.
        startingNumber: Int = 1,
        /// Folder paths already in the library, so a plan can never aim at a
        /// folder that exists. The caller lists them from disk.
        existingFolders: Set<String> = []
    ) -> ImportPlan {
        var operations: [ImportOperation] = []
        var skipped: [SkippedImport] = []
        var number = max(1, startingNumber)
        // Case-insensitively, because APFS is: two books whose folders differ
        // only in case would be one folder on a normal Mac.
        var takenFolders = Set(existingFolders.map { $0.lowercased() })

        // What this very import has already decided, so a drop that contains
        // both the EPUB and the AZW3 of one book creates one book with two
        // formats rather than two books.
        var plannedBooks: [String: (id: UUID, folder: String, title: String)] = [:]
        var plannedFormats: [UUID: Set<BookFileFormat>] = [:]
        var plannedDigests: Set<String> = []

        // The order decides two things, so it is chosen rather than incidental.
        //
        // *Preferred format first*: when one drop holds a book's EPUB and its
        // AZW3, whichever comes first becomes the new book, and its metadata
        // and its cover are the ones kept. EPUB is the format Shelf can
        // actually read metadata out of in Sprint 1, so letting an AZW3 win
        // would mean a book named after its file for no reason.
        //
        // *Then by path*: a stable tiebreak, so two runs over the same folder
        // produce the same numbers and the same report.
        let ordered = candidates.sorted {
            $0.format.preferenceRank == $1.format.preferenceRank
                ? $0.source.path < $1.source.path
                : $0.format.preferenceRank < $1.format.preferenceRank
        }
        for candidate in ordered {
            let path = candidate.source.path

            // 1. The same bytes. Nothing else needs asking.
            if let existing = knowledge.digests[candidate.sha256] {
                skipped.append(
                    .init(path: path, reason: .sameContent, existingTitle: title(of: existing, in: knowledge)))
                continue
            }
            if plannedDigests.contains(candidate.sha256) {
                skipped.append(.init(path: path, reason: .duplicateWithinImport))
                continue
            }

            // 2. The same book, by ISBN and then by title + author.
            let key = DuplicateKey.titleAuthor(for: candidate.book)
            let match = existingBook(for: candidate, key: key, knowledge: knowledge, planned: plannedBooks)

            if let match {
                let alreadyHas =
                    (knowledge.formatsByBook[match.id] ?? []).union(plannedFormats[match.id] ?? [])
                if alreadyHas.contains(candidate.format) {
                    skipped.append(
                        .init(path: path, reason: match.reason, existingTitle: match.title))
                    continue
                }
                // Same book, new format: one more file in the folder it
                // already has. Never a second folder – that is what makes
                // "Add Format…" and a drag of a second file the same thing.
                operations.append(
                    .addFormat(
                        .init(
                            candidate: candidate, bookID: match.id, folder: match.folder,
                            fileName: BookFolderName.fileName(for: candidate.book, format: candidate.format))))
                plannedFormats[match.id, default: []].insert(candidate.format)
                plannedDigests.insert(candidate.sha256)
                continue
            }

            // 3. A book the library does not have.
            let assigned = number
            number += 1
            let folder = uniqueFolder(for: candidate.book, number: assigned, avoiding: &takenFolders)
            operations.append(
                .newBook(
                    .init(
                        candidate: candidate, number: assigned, folder: folder,
                        fileName: BookFolderName.fileName(for: candidate.book, format: candidate.format))))
            plannedBooks[key] = (candidate.book.id, folder, candidate.book.title)
            if let isbn = candidate.book.isbn {
                plannedBooks["isbn:\(isbn)"] = (candidate.book.id, folder, candidate.book.title)
            }
            plannedFormats[candidate.book.id, default: []].insert(candidate.format)
            plannedDigests.insert(candidate.sha256)
        }

        return ImportPlan(
            operations: operations,
            skipped: skipped.sorted { $0.path < $1.path })
    }

    /// The book this candidate belongs to, if any – in the library or already
    /// planned in this run.
    ///
    /// ISBN before title, because an ISBN names an edition and a title does
    /// not: "Dune" by Frank Herbert is one title and a dozen editions, and the
    /// ISBN is the only one of the two that can tell them apart.
    private static func existingBook(
        for candidate: ImportCandidate,
        key: String,
        knowledge: ImportKnowledge,
        planned: [String: (id: UUID, folder: String, title: String)]
    ) -> (id: UUID, folder: String, title: String?, reason: SkippedImport.Reason)? {
        if let isbn = candidate.book.isbn {
            if let planned = planned["isbn:\(isbn)"] {
                return (planned.id, planned.folder, planned.title, .duplicateWithinImport)
            }
            if let id = knowledge.isbns[isbn] {
                return (id, "", title(of: id, in: knowledge), .sameISBN)
            }
        }
        if let planned = planned[key] {
            return (planned.id, planned.folder, planned.title, .duplicateWithinImport)
        }
        // Only an unambiguous match counts. Two library books with the same
        // title and author and no ISBN are a mess Shelf must not make worse by
        // picking one of them; the new file becomes its own book, and the
        // "Duplicates" smart collection is where that gets sorted out.
        if let ids = knowledge.titleKeys[key], ids.count == 1, let id = ids.first {
            return (id, "", title(of: id, in: knowledge), .sameTitleAndAuthor)
        }
        return nil
    }

    private static func title(of id: UUID, in knowledge: ImportKnowledge) -> String? {
        // The snapshot carries no titles – naming the book in the report is the
        // caller's job, which has the index open. Kept as a hook so the report
        // wording does not have to change when it does.
        _ = (id, knowledge)
        return nil
    }

    /// The folder for a new book, guaranteed not to collide.
    ///
    /// The number already makes the title unique, so a collision means the
    /// folder is genuinely there – a leftover from a deleted book, or a library
    /// whose counter was reset. A suffix is added rather than reusing the
    /// folder: writing into a folder with somebody else's files in it is the
    /// one thing an import must not do.
    private static func uniqueFolder(for book: Book, number: Int, avoiding taken: inout Set<String>) -> String {
        let base = BookFolderName.relativePath(for: book, number: number)
        guard taken.contains(base.lowercased()) else {
            taken.insert(base.lowercased())
            return base
        }
        var attempt = 2
        while taken.contains("\(base)-\(attempt)".lowercased()) { attempt += 1 }
        let folder = "\(base)-\(attempt)"
        taken.insert(folder.lowercased())
        return folder
    }
}

/// Byte counts in the words the interface uses.
///
/// One place, because a report that says "1.4 GB" and a status bar that says
/// "1468 MB" about the same number is a bug report waiting to happen.
public enum ByteCount {
    public static func format(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[unit])
    }
}
