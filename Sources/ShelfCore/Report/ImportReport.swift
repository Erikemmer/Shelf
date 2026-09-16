import Foundation

/// What a finished import says for itself.
///
/// Written into `.shelf/Import-Report.txt` and summarised in the window,
/// because this is the text the user reads to find out what happened to files
/// they care about. It therefore leads with what was taken over, names every
/// file that was not, and ends by saying the source is untouched – which is
/// true, and is the sentence the whole design exists to earn.
///
/// The wording follows Selector's `IngestReport` on purpose ("verified" /
/// "NOT VERIFIED"), so a user of both apps reads the same words for the same
/// guarantee.
public struct ImportReport: Equatable, Sendable {
    public static let fileName = "Import-Report.txt"

    public struct Failure: Equatable, Sendable {
        public var path: String
        public var message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    /// Something imperfect about a book that was still imported – no cover, no
    /// author, an OPF that would not parse. Never a reason to skip a file.
    public struct Warning: Equatable, Sendable {
        public var path: String
        public var message: String

        public init(path: String, message: String) {
            self.path = path
            self.message = message
        }
    }

    public var libraryName: String
    public var sourceDescription: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var newBooks: Int
    public var addedFormats: Int
    public var copiedByFormat: [BookFileFormat: Int]
    public var copiedBytes: Int64
    public var skipped: [SkippedImport]
    public var warnings: [Warning]
    public var failures: [Failure]

    public init(
        libraryName: String,
        sourceDescription: String,
        startedAt: Date = Date(),
        duration: TimeInterval = 0,
        newBooks: Int = 0,
        addedFormats: Int = 0,
        copiedByFormat: [BookFileFormat: Int] = [:],
        copiedBytes: Int64 = 0,
        skipped: [SkippedImport] = [],
        warnings: [Warning] = [],
        failures: [Failure] = []
    ) {
        self.libraryName = libraryName
        self.sourceDescription = sourceDescription
        self.startedAt = startedAt
        self.duration = duration
        self.newBooks = newBooks
        self.addedFormats = addedFormats
        self.copiedByFormat = copiedByFormat
        self.copiedBytes = copiedBytes
        self.skipped = skipped
        self.warnings = warnings
        self.failures = failures
    }

    public var copiedCount: Int { copiedByFormat.values.reduce(0, +) }

    /// Whether every file that was meant to come over did, and verified.
    public var everythingVerified: Bool { failures.isEmpty }

    /// The one line shown in the window and at the top of the file.
    public var headline: String {
        guard everythingVerified else {
            return "FAILED: \(failures.count) file\(failures.count == 1 ? "" : "s") not verified"
        }
        var parts = ["Verified · \(copiedCount) file\(copiedCount == 1 ? "" : "s")"]
        if newBooks > 0 { parts.append("\(newBooks) new book\(newBooks == 1 ? "" : "s")") }
        if addedFormats > 0 { parts.append("\(addedFormats) new format\(addedFormats == 1 ? "" : "s")") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        return parts.joined(separator: " · ")
    }

    /// The file written into `.shelf/`. Plain text on purpose – it has to be
    /// readable in ten years without this app.
    public func rendered() -> String {
        var lines: [String] = []
        lines.append("Shelf import report")
        lines.append(headline)
        lines.append("")
        lines.append("Library:  \(libraryName)")
        lines.append("Source:   \(sourceDescription)")
        lines.append("Started:  \(Self.timestamp(startedAt))")
        lines.append("Duration: \(Self.duration(duration))")
        lines.append("")
        lines.append("Copied and verified: \(copiedCount) files, \(ByteCount.format(copiedBytes))")
        for format in BookFileFormat.allCases where (copiedByFormat[format] ?? 0) > 0 {
            lines.append("  \(format.rawValue.uppercased()): \(copiedByFormat[format] ?? 0)")
        }
        lines.append("  new books: \(newBooks)")
        lines.append("  formats added to existing books: \(addedFormats)")

        if !skipped.isEmpty {
            lines.append("")
            lines.append("Skipped: \(skipped.count)")
            for reason in SkippedImport.Reason.allCases {
                let group = skipped.filter { $0.reason == reason }
                guard !group.isEmpty else { continue }
                lines.append("  \(reason.label): \(group.count)")
                // Named, not just counted: a skipped file is a decision the
                // user may disagree with, and they cannot if they cannot see it.
                for entry in group {
                    lines.append("    \(entry.path)")
                }
            }
        }

        if !warnings.isEmpty {
            lines.append("")
            lines.append("Imported with something missing: \(warnings.count)")
            lines.append(contentsOf: warnings.map { "  \($0.path): \($0.message)" })
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("NOT VERIFIED – these files were not taken over:")
            lines.append(contentsOf: failures.map { "  \($0.path): \($0.message)" })
        }

        lines.append("")
        lines.append("Nothing at the source was changed, moved or deleted.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends the report to the library's report file.
    ///
    /// Appends rather than replaces: the history of what came into a library
    /// and what was skipped is worth more than the last run alone, and it is
    /// small – a few hundred bytes per import.
    public func append(to library: Library) throws {
        let separator = "\n" + String(repeating: "─", count: 72) + "\n\n"
        let text = (FileManager.default.fileExists(atPath: library.reportURL.path) ? separator : "") + rendered()
        try FileManager.default.createDirectory(at: library.privateFolder, withIntermediateDirectories: true)

        guard let handle = FileHandle(forWritingAtPath: library.reportURL.path) else {
            try Data(text.utf8).write(to: library.reportURL, options: .atomic)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: Formatting
    //
    // Fixed formats, not the user's locale: this file is a record, and a record
    // that reads differently on another Mac is a worse record.

    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        return minutes > 0 ? "\(minutes) min \(total % 60) s" : "\(total) s"
    }
}
