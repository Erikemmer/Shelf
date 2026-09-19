import ShelfCore
import SwiftUI

/// The one-line counts a sheet shows, in the reader's language.
///
/// **Why these are not in the core.** Every plan and every report already has a
/// `summary()` or a `headline`, and those stay exactly as they are: they are
/// written into `Import-Report.txt`, `Send-Report.txt`, `Organize-Report.txt`
/// and `Shelf-Export-Report.txt`, and those files are **English on purpose** —
/// a report has to be readable in ten years by whoever opens it, and a
/// half-German plain-text file helps nobody. ADR 0016's rule is the same one:
/// the core answers in English and the window translates.
///
/// Until this file the window simply drew the core's English. A German window
/// showed "Moved · 8 folders · Already right: 7 · Could not: 1 · Failed: 0"
/// above a sheet whose every other word was German, and "FAILED: 3 files not
/// verified" as the loudest line in the import. It was found by photographing
/// the Sprint 8 sheets in German and looking at them, which is exactly what
/// looking at them is for.
///
/// Each of these is built the way every other count in the window is built —
/// `Loc.count` per piece, joined — so the catalogue does the pluralising and
/// German gets "1 Buch" and "2 Bücher" without a `== 1` anywhere in here.
enum Summaries {
    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Adding books

    static func line(for plan: ImportPlan) -> String {
        guard !plan.operations.isEmpty || !plan.skipped.isEmpty else {
            return Loc.string("Nothing to import")
        }
        var parts: [String] = []
        if plan.newBookCount > 0 { parts.append(Loc.count("%lld new books", plan.newBookCount)) }
        if plan.addedFormatCount > 0 {
            parts.append(Loc.count("%lld new formats", plan.addedFormatCount))
        }
        if !plan.skipped.isEmpty { parts.append(Loc.count("%lld skipped", plan.skipped.count)) }
        parts.append(Loc.size(plan.totalBytes))
        return joined(parts)
    }

    static func line(for report: ImportReport) -> String {
        guard report.everythingVerified else {
            return Loc.count("FAILED: %lld files not verified", report.failures.count)
        }
        var parts = [Loc.string("Verified · %@", Loc.count("%lld files", report.copiedCount))]
        if report.newBooks > 0 { parts.append(Loc.count("%lld new books", report.newBooks)) }
        if report.addedFormats > 0 {
            parts.append(Loc.count("%lld new formats", report.addedFormats))
        }
        if !report.skipped.isEmpty { parts.append(Loc.count("%lld skipped", report.skipped.count)) }
        if !report.orphanedFolders.isEmpty {
            parts.append(Loc.count("%lld orphaned folders", report.orphanedFolders.count))
        }
        return joined(parts)
    }

    // MARK: Sending to a device

    static func line(for plan: TransferPlan) -> String {
        guard !plan.operations.isEmpty || !plan.skipped.isEmpty else {
            return Loc.string("Nothing to send")
        }
        var parts: [String] = []
        if !plan.operations.isEmpty {
            parts.append(Loc.count("%lld books", plan.operations.count))
            for format in BookFileFormat.allCases.sorted() where plan.count(of: format) > 0 {
                parts.append("\(format.label) \(plan.count(of: format))")
            }
        }
        let cannot = plan.skipped.count { $0.reason != .alreadyOnDevice }
        if cannot > 0 { parts.append(Loc.count("%lld cannot be sent", cannot)) }
        let already = plan.skipped(for: .alreadyOnDevice).count
        if already > 0 { parts.append(Loc.count("%lld already there", already)) }
        if !plan.operations.isEmpty { parts.append(Loc.size(plan.totalBytes)) }
        return joined(parts)
    }

    static func line(for report: TransferReport) -> String {
        joined([
            Loc.string("Verified · %@", Loc.count("%lld books", report.sent.count)),
            Loc.count("Skipped: %lld", report.skipped.count),
            Loc.count("Failed: %lld", report.failures.count),
        ])
    }

    // MARK: Renaming and merging (Sprint 8)

    static func line(for plan: NameMergePlan) -> String {
        guard !plan.isEmpty else {
            if plan.carrying == 0 {
                return plan.merge.isRename
                    ? Loc.string("No book carries that spelling")
                    : Loc.string("No book carries any of those spellings")
            }
            return Loc.count("%lld books already read that way — nothing to change", plan.carrying)
        }
        var parts = [Loc.count("%lld books", plan.bookCount)]
        if !plan.merge.isRename {
            parts.append(Loc.count("%lld spellings", plan.merge.sources.count))
        }
        parts.append(Loc.string("→ “%@”", plan.merge.trimmedTarget))
        return joined(parts)
    }

    // MARK: Organising (Sprint 8)

    static func line(for plan: OrganizePlan) -> String {
        var parts = [
            Loc.count("%lld to move", plan.moves.count),
            Loc.count("%lld already right", plan.alreadyInPlace),
        ]
        if !plan.blocked.isEmpty { parts.append(Loc.count("%lld cannot be", plan.blocked.count)) }
        return joined(parts)
    }

    static func line(for report: OrganizeReport) -> String {
        joined([
            Loc.string("Moved · %@", Loc.count("%lld folders", report.moved.count)),
            Loc.count("Already right: %lld", report.alreadyInPlace),
            Loc.count("Could not: %lld", report.blocked.count),
            Loc.count("Failed: %lld", report.failures.count),
        ])
    }

    // MARK: Exporting (Sprint 8)

    static func line(for plan: ExportPlan) -> String {
        guard !plan.operations.isEmpty else { return Loc.string("Nothing to export") }
        var parts = [Loc.count("%lld books", plan.bookCount)]
        if plan.count(of: .new) > 0 { parts.append(Loc.count("%lld new", plan.count(of: .new))) }
        if plan.count(of: .changed) > 0 {
            parts.append(Loc.count("%lld changed", plan.count(of: .changed)))
        }
        if plan.count(of: .unchanged) > 0 {
            parts.append(Loc.count("%lld unchanged", plan.count(of: .unchanged)))
        }
        if plan.bytesToWrite > 0 {
            parts.append(Loc.string("%@ to write", Loc.size(plan.bytesToWrite)))
        }
        if !plan.stale.isEmpty {
            parts.append(Loc.count("%lld no longer wanted", plan.stale.count))
        }
        if !plan.skipped.isEmpty { parts.append(Loc.count("%lld left out", plan.skipped.count)) }
        return joined(parts)
    }

    static func line(for report: ExportReport) -> String {
        let new = report.written.count { $0.state == .new }
        let changed = report.written.count { $0.state == .changed }
        return joined([
            Loc.string("Written · %@", Loc.count("%lld new", new)),
            Loc.count("%lld changed", changed),
            Loc.count("%lld unchanged", report.unchanged),
            Loc.count("Failed: %lld", report.failures.count),
        ])
    }
}
