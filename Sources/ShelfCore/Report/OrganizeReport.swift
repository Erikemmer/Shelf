import Foundation

/// What a finished organise says for itself.
///
/// Written into the library, in `.shelf/Organize-Report.txt`, appended to like
/// the import's — a library carries the history of what has been done to its
/// folders. Plain text, so it is readable in ten years without this app.
///
/// The headline is deliberately the same shape as the transfer's, because it
/// answers the same question: **what was verified, what was left alone, and
/// what went wrong.** "Moved" here means the digests of every file in the
/// folder were compared after the move and agreed — not that a rename returned
/// success (ADR 0002, decision 2).
public struct OrganizeReport: Equatable, Sendable {
    public static let fileName = "Organize-Report.txt"

    public struct Failure: Equatable, Sendable {
        public var title: String
        public var path: String
        public var message: String

        public init(title: String, path: String, message: String) {
            self.title = title
            self.path = path
            self.message = message
        }
    }

    public var libraryName: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var moved: [OrganizeMove]
    public var alreadyInPlace: Int
    public var blocked: [BlockedBook]
    public var failures: [Failure]
    /// Author folders this run emptied and then removed. Named rather than
    /// counted, because removing anything is worth reading by name.
    public var emptiedFolders: [String]
    /// Set when this report is of an `Undo Organize` rather than an organise,
    /// so a person reading the file can tell the two apart.
    public var isUndo: Bool

    public init(
        libraryName: String, startedAt: Date, duration: TimeInterval, moved: [OrganizeMove],
        alreadyInPlace: Int, blocked: [BlockedBook], failures: [Failure],
        emptiedFolders: [String] = [], isUndo: Bool = false
    ) {
        self.libraryName = libraryName
        self.startedAt = startedAt
        self.duration = duration
        self.moved = moved
        self.alreadyInPlace = alreadyInPlace
        self.blocked = blocked
        self.failures = failures
        self.emptiedFolders = emptiedFolders
        self.isUndo = isUndo
    }

    /// "Moved · 37 folders · Already right: 4 959 · Could not: 2 · Failed: 0".
    public var headline: String {
        "Moved · \(moved.count) folder\(moved.count == 1 ? "" : "s") · "
            + "Already right: \(alreadyInPlace) · Could not: \(blocked.count) · "
            + "Failed: \(failures.count)"
    }

    public func rendered() -> String {
        var lines: [String] = []
        lines.append(isUndo ? "Shelf organise report — undo" : "Shelf organise report")
        lines.append(headline)
        lines.append("")
        lines.append("Library:  \(libraryName)")
        lines.append("Started:  \(ImportReport.timestamp(startedAt))")
        lines.append("Duration: \(ImportReport.duration(duration))")
        lines.append("")
        lines.append("Moved and verified: \(moved.count)")
        for move in moved {
            lines.append("  \(move.from)")
            lines.append("    → \(move.to)")
        }

        if !blocked.isEmpty {
            lines.append("")
            lines.append("Left where they are: \(blocked.count)")
            for reason in BlockedBook.Reason.allCases {
                let group = blocked.filter { $0.reason == reason }
                guard !group.isEmpty else { continue }
                lines.append("  \(reason.label): \(group.count)")
                for entry in group { lines.append("    \(entry.title) → \(entry.wantedPath)") }
            }
        }

        if !emptiedFolders.isEmpty {
            lines.append("")
            lines.append("Author folders left empty by the moves above, and removed: \(emptiedFolders.count)")
            for name in emptiedFolders { lines.append("  \(name)") }
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("NOT MOVED – these are where they were:")
            for failure in failures { lines.append("  \(failure.title): \(failure.message)") }
        }

        lines.append("")
        lines.append(
            emptiedFolders.isEmpty
                ? "No book file was written, and nothing was deleted."
                : "No book file was written. The only things removed were the empty folders listed above.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends the report to the library's own, next to the import's.
    public func append(in library: Library) throws {
        try FileManager.default.createDirectory(
            at: library.privateFolder, withIntermediateDirectories: true)
        let url = library.privateFolder.appendingPathComponent(Self.fileName)
        let separator = "\n" + String(repeating: "─", count: 72) + "\n\n"
        let text = (FileManager.default.fileExists(atPath: url.path) ? separator : "") + rendered()

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            try Data(text.utf8).write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
