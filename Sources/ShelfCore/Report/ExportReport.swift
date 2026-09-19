import Foundation

/// What a finished export says for itself, written at the destination.
///
/// At the destination rather than in the library, for the same reason the
/// transfer's report lives on the card: it is about what is *there*. A folder
/// handed to somebody else still says what it holds, where it came from and
/// what was deliberately left out of it — and says it in plain text, readable
/// in ten years without this app, which is the whole point of an export.
public struct ExportReport: Equatable, Sendable {
    public static let fileName = "Shelf-Export-Report.txt"

    public struct Written: Equatable, Sendable {
        public var title: String
        public var kind: ExportOperation.Kind
        public var state: ExportOperation.State
        public var path: String
        public var byteSize: Int64
        public var isHardLink: Bool

        public init(
            title: String, kind: ExportOperation.Kind, state: ExportOperation.State, path: String,
            byteSize: Int64, isHardLink: Bool
        ) {
            self.title = title
            self.kind = kind
            self.state = state
            self.path = path
            self.byteSize = byteSize
            self.isHardLink = isHardLink
        }
    }

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
    public var destination: URL
    public var startedAt: Date
    public var duration: TimeInterval
    public var written: [Written]
    public var unchanged: Int
    public var skipped: [SkippedExport]
    public var failures: [Failure]
    public var copiedBytes: Int64
    public var hardLinkCount: Int
    public var options: ExportOptions
    /// Files an earlier run of this export wrote that this one replaced with
    /// differently named ones, and took away.
    public var removed: [String]
    /// Ones it would have taken away and did not, because they are no longer
    /// the size it wrote them — somebody has changed them.
    public var keptBack: [String]

    public init(
        libraryName: String, destination: URL, startedAt: Date, duration: TimeInterval,
        written: [Written], unchanged: Int, skipped: [SkippedExport], failures: [Failure],
        copiedBytes: Int64, hardLinkCount: Int, options: ExportOptions,
        removed: [String] = [], keptBack: [String] = []
    ) {
        self.libraryName = libraryName
        self.destination = destination
        self.startedAt = startedAt
        self.duration = duration
        self.written = written
        self.unchanged = unchanged
        self.skipped = skipped
        self.failures = failures
        self.copiedBytes = copiedBytes
        self.hardLinkCount = hardLinkCount
        self.options = options
        self.removed = removed
        self.keptBack = keptBack
    }

    public var bookCount: Int {
        Set(written.filter { $0.kind == .bookFile }.map(\.path)).count
    }

    /// "Written · 37 new · 4 changed · 371 unchanged · Failed: 0".
    public var headline: String {
        let new = written.count { $0.state == .new }
        let changed = written.count { $0.state == .changed }
        return "Written · \(new) new · \(changed) changed · \(unchanged) unchanged · "
            + "Failed: \(failures.count)"
    }

    public func rendered() -> String {
        var lines: [String] = []
        lines.append("Shelf export report")
        lines.append(headline)
        lines.append("")
        lines.append("Library:  \(libraryName)")
        lines.append("Written:  \(ImportReport.timestamp(startedAt))")
        lines.append("Duration: \(ImportReport.duration(duration))")
        lines.append("")
        lines.append("Structure:     \(options.structure.label)")
        lines.append("Name pattern:  \(options.namePattern)")
        lines.append(
            "Formats:       "
                + (options.formats.map { $0.map(\.label).sorted().joined(separator: ", ") } ?? "all"))
        lines.append("cover:         \(options.includesCover ? "yes" : "no")")
        lines.append("metadata.opf:  \(options.includesOPF ? "yes" : "no")")
        if options.mapsShelvesToTags {
            lines.append(
                "Calibre tags:  shelves as “\(CalibreTagMapping.shelfPrefix)/…” and "
                    + "“\(CalibreTagMapping.readTag)” for a book that has been read. A mapping, "
                    + "written beside Shelf's own fields and not instead of them.")
        }
        lines.append("")

        for kind in ExportOperation.Kind.allCases {
            let group = written.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            lines.append("\(kind.label): \(group.count)")
        }
        lines.append("")
        lines.append("Copied: \(ByteCount.format(copiedBytes))")
        if hardLinkCount > 0 {
            lines.append(
                "Hard links: \(hardLinkCount) — the same bytes as in the library, on the same "
                    + "volume, taking no extra room. Safe because Shelf never writes a book file.")
        }

        // The honest part, and the reason this file exists at all.
        if !options.includesOPF {
            lines.append("")
            lines.append("NOT in this export, because no metadata.opf was written:")
            lines.append("  the rating, the read status, the tags and the shelves.")
            lines.append("  They are in the library's own OPFs and nowhere else.")
        }

        if !removed.isEmpty {
            lines.append("")
            lines.append(
                "Written by an earlier run of this export and no longer wanted — taken away: \(removed.count)")
            lines.append("  (a book whose title has changed has a new file name; the old one would")
            lines.append("   otherwise be imported back in preference to it)")
            for path in removed.prefix(50) { lines.append("  \(path)") }
        }

        if !keptBack.isEmpty {
            lines.append("")
            lines.append("Left alone, because they are not the size this export wrote them: \(keptBack.count)")
            for path in keptBack { lines.append("  \(path)") }
        }

        if !skipped.isEmpty {
            lines.append("")
            lines.append("Left out: \(skipped.count)")
            for reason in SkippedExport.Reason.allCases {
                let group = skipped.filter { $0.reason == reason }
                guard !group.isEmpty else { continue }
                lines.append("  \(reason.label): \(group.count)")
                for entry in group.prefix(50) { lines.append("    \(entry.title)") }
            }
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("NOT WRITTEN – these are not in this folder:")
            for failure in failures { lines.append("  \(failure.title): \(failure.message)") }
        }

        lines.append("")
        lines.append("Nothing in the library was changed. This folder is a copy.")
        return lines.joined(separator: "\n") + "\n"
    }

    public func append(at destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appendingPathComponent(Self.fileName)
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
