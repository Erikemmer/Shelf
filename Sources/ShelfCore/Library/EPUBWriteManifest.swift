import Foundation

/// A record of every book "Write into the Book File" has actually written,
/// appended to as it goes — the way back after the window has closed, the
/// app has quit, or the Trash this ADR relies on (0021) has since been
/// emptied by hand.
///
/// **Never read back by `run` itself.** Resuming an interrupted run does not
/// need this file at all: a fresh plan, recomputed from the files as they
/// now stand, already shows a book this run already wrote as having no
/// change left to make (`BookPlan.hasChange`), the same way `Organize`'s own
/// "25 books were already at their new folder" repairs itself from the
/// folders rather than from a manifest (`docs/RUNBOOK.md` §13). So this type
/// is a report, never a second source of truth — the same reasoning ADR
/// 0001 gives for the index being a cache: what can be re-derived from the
/// files is, and what cannot (here, only *where the original went*) is
/// written down.
///
/// Appended to, one line per book, never overwritten — the same shape
/// `Import-Report.txt` already uses and for the same reason
/// (`docs/RUNBOOK.md` §10): a record that a later run could silently
/// truncate is not a record.
public enum EPUBWriteManifest {
    public static let fileName = "epub-write-report.txt"

    public static func url(in library: Library) -> URL {
        library.privateFolder.appendingPathComponent(fileName)
    }

    /// Appends one line for a book `run` actually wrote into. Does nothing
    /// for any other outcome — a book left unchanged or never attempted has
    /// nothing to record, and a failure has no original displaced to say
    /// where it went.
    ///
    /// **Never throws.** By the time this is called the book itself is
    /// already correct — the write already succeeded — so losing the
    /// ability to note it down costs only the report, never the book,
    /// exactly the tolerance `OrganizeManifest.read` already extends to a
    /// manifest it cannot read at all.
    public static func append(_ outcome: EPUBWrite.BookOutcome, in library: Library, at date: Date = Date()) {
        guard let line = Self.line(for: outcome, at: date) else { return }
        let fileURL = url(in: library)
        do {
            try FileManager.default.createDirectory(
                at: library.privateFolder, withIntermediateDirectories: true)
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Deliberately swallowed — see the doc comment above.
        }
    }

    /// One tab-separated line: when, which book, the hash it had, the hash
    /// it has now, and where the original the book had before went. `nil`
    /// for anything that is not `.wrote` — nothing else belongs in a record
    /// of what was actually written.
    static func line(for outcome: EPUBWrite.BookOutcome, at date: Date) -> String? {
        guard case .wrote(let beforeSHA256, let afterSHA256, let disposal) = outcome.result else { return nil }
        let wentTo: String
        switch disposal {
        case .trashed(let at): wentTo = at.map { "Trash: \($0.path)" } ?? "Trash (location not reported)"
        case .leftAsDebris(let name, let reason): wentTo = "left beside the book as \"\(name)\" — \(reason)"
        }
        let title = outcome.title.replacingOccurrences(of: "\t", with: " ")
        return [Self.dateFormatter.string(from: date), title, beforeSHA256, afterSHA256, wentTo]
            .joined(separator: "\t")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
