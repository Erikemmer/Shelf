import Foundation

/// What a finished transfer says for itself.
///
/// The headline the brief asks for is one line — **"Verified · n books ·
/// Skipped: n · Failed: n"** — and the rest of the file exists so that each of
/// those numbers can be checked against a name. A count with nothing behind it
/// is a count nobody can act on, and "Skipped: 7" is exactly the number
/// somebody wants the seven titles for.
///
/// Written to the *device*, in `.shelf/Send-Report.txt`, next to the manifest.
/// On the device rather than in the library because that is where it is about:
/// a card taken to another Mac still says what is on it and how it got there.
/// Plain text, so it is readable in ten years without this app.
public struct TransferReport: Equatable, Sendable {
    public static let fileName = "Send-Report.txt"

    /// One book that arrived and was read back.
    public struct Sent: Equatable, Sendable {
        public var title: String
        public var author: String
        public var format: BookFileFormat
        public var path: String
        public var byteSize: Int64

        public init(title: String, author: String, format: BookFileFormat, path: String, byteSize: Int64) {
            self.title = title
            self.author = author
            self.format = format
            self.path = path
            self.byteSize = byteSize
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

    public var deviceName: String
    public var profileName: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var sent: [Sent]
    public var skipped: [SkippedTransfer]
    public var failures: [Failure]
    public var copiedBytes: Int64

    public init(
        deviceName: String, profileName: String, startedAt: Date, duration: TimeInterval,
        sent: [Sent], skipped: [SkippedTransfer], failures: [Failure], copiedBytes: Int64
    ) {
        self.deviceName = deviceName
        self.profileName = profileName
        self.startedAt = startedAt
        self.duration = duration
        self.sent = sent
        self.skipped = skipped
        self.failures = failures
        self.copiedBytes = copiedBytes
    }

    /// The one line the sheet shows, in the words CONCEPT §8.2 asks for.
    ///
    /// "Verified" leads, and it means what it says: every book counted here was
    /// read back off the device and its digest compared. A book that failed is
    /// in the third number and never in the first.
    public var headline: String {
        "Verified · \(sent.count) book\(sent.count == 1 ? "" : "s") · Skipped: \(skipped.count) · "
            + "Failed: \(failures.count)"
    }

    public func rendered() -> String {
        var lines: [String] = []
        lines.append("Shelf transfer report")
        lines.append(headline)
        lines.append("")
        lines.append("Device:   \(deviceName) (\(profileName))")
        lines.append("Started:  \(ImportReport.timestamp(startedAt))")
        lines.append("Duration: \(ImportReport.duration(duration))")
        lines.append("")
        lines.append("Copied and verified: \(sent.count) files, \(ByteCount.format(copiedBytes))")
        for book in sent {
            lines.append("  \(book.format.label)  \(book.path)  (\(ByteCount.format(book.byteSize)))")
        }

        if !skipped.isEmpty {
            lines.append("")
            lines.append("Skipped: \(skipped.count)")
            for reason in SkippedTransfer.Reason.allCases {
                let group = skipped.filter { $0.reason == reason }
                guard !group.isEmpty else { continue }
                lines.append("  \(reason.label): \(group.count)")
                for entry in group { lines.append("    \(entry.title)") }
            }
        }

        if !failures.isEmpty {
            lines.append("")
            lines.append("NOT VERIFIED – these books are not on the device:")
            for failure in failures { lines.append("  \(failure.title): \(failure.message)") }
        }

        lines.append("")
        lines.append("Nothing in the library was changed, and nothing on the device was deleted.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Appends the report to the device's own report file, next to the
    /// manifest. Appending, so a card carries the history of what went onto it.
    public func append(toVolume volume: URL) throws {
        let folder = volume.appendingPathComponent(DeviceManifest.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName)
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
