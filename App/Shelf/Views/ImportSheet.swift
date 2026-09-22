import ShelfCore
import SlateKit
import SwiftUI

/// The counting protocol, and the button that acts on it.
///
/// Nothing is copied until the user has seen these numbers: how many new books,
/// how many new formats, how much will be skipped and why, and how many bytes
/// it will take (Leitlinie: "Importe idempotent mit Zählprotokoll"). What the
/// user confirms here is the exact `ImportPlan` the runner is handed.
struct ImportSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The sheet is one flow with two sources, and it says which one it
            // is looking at: a person who chose Import from Calibre and is then
            // asked to confirm something headed "Add Books" has to check.
            Text(model.importModel?.calibreCensus == nil ? Loc.string("Add Books") : Loc.string("Import from Calibre"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            if let importModel = model.importModel {
                content(importModel)
            } else {
                Text(Loc.string("No library open.")).foregroundStyle(Slate.textSecondary)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Slate.windowBackground)
    }

    @ViewBuilder
    private func content(_ importModel: ImportModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(importModel.sourceDescription)
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(2)

            switch importModel.phase {
            case .idle:
                idle(importModel)
            case .examining(let done, let total):
                progressRow(
                    Loc.string("Reading %1$@ of %2$@ files", Loc.number(done), Loc.number(total)),
                    fraction: fraction(done, total))
            case .ready:
                plan(importModel)
            case .running(let progress):
                running(progress)
            case .finished(let report):
                finished(report)
            }

            if let message = importModel.errorMessage {
                SlateBanner(message)
            }

            buttons(importModel)
        }
    }

    // MARK: Phases

    @ViewBuilder
    private func idle(_ importModel: ImportModel) -> some View {
        Text(Loc.string("Choose books or a folder, or drop them on the window."))
            .foregroundStyle(Slate.textSecondary)
    }

    /// What the Calibre library holds, before a byte of it is copied
    /// (CONCEPT §7.3).
    ///
    /// Above the skipped list and below the plan, because it answers a
    /// different question: the plan says what Shelf will *do*, and this says
    /// what is *there* — including the two things only a Calibre library can
    /// tell you, which are the files its database lists and the disk has not
    /// got, and the files on the disk it has never heard of.
    @ViewBuilder
    private func calibre(_ census: CalibreCensus) -> some View {
        SlateInspectorSection(Loc.string("In the Calibre library")) {
            VStack(alignment: .leading, spacing: 3) {
                SlateValueRow(name: Loc.string("Books"), value: "\(census.books)")
                SlateValueRow(name: Loc.string("Authors"), value: "\(census.authors)")
                SlateValueRow(
                    name: Loc.contextual("Series [counted in a Calibre library]", english: Loc.string("Series")),
                    value: "\(census.series)")
                SlateValueRow(name: Loc.string("Tags"), value: "\(census.tags)")
                ForEach(census.customColumns, id: \.label) { column in
                    SlateValueRow(name: column.hashLabel, value: column.kind.label)
                }
                ForEach(census.unknownColumns, id: \.label) { column in
                    SlateValueRow(
                        name: "#" + column.label,
                        value: Loc.string("%@ – not imported", column.datatype))
                }
                if !census.missingFiles.isEmpty {
                    SlateValueRow(
                        name: Loc.string("Listed in metadata.db, not on the disk"),
                        value: "\(census.missingFiles.count)")
                }
                if !census.orphanFiles.isEmpty {
                    SlateValueRow(
                        name: Loc.string("On the disk, not in metadata.db"), value: "\(census.orphanFiles.count)")
                }
                if census.booksWithoutCover > 0 {
                    SlateValueRow(name: Loc.string("Without a cover"), value: "\(census.booksWithoutCover)")
                }
            }
        }
        if let warning = census.schema.warning {
            SlateFieldNote(warning)
        }
        // Said here and not only in the report: a column Shelf cannot read is a
        // thing to know *before* an import, not after one.
        ForEach(census.warnings.filter { $0 != census.schema.warning }, id: \.self) { warning in
            SlateFieldNote(warning)
        }
        Text(Loc.string("Nothing in the Calibre library is changed, moved or deleted."))
            .font(.caption2)
            .foregroundStyle(Slate.textSecondary)
    }

    private func plan(_ importModel: ImportModel) -> some View {
        let plan = importModel.plan
        return VStack(alignment: .leading, spacing: 10) {
            Text(Summaries.line(for: plan))
                .font(.headline)
                .foregroundStyle(Slate.textPrimary)

            VStack(alignment: .leading, spacing: 3) {
                SlateValueRow(name: Loc.string("New books"), value: "\(plan.newBookCount)")
                SlateValueRow(name: Loc.string("Formats added to existing books"), value: "\(plan.addedFormatCount)")
                ForEach(BookFileFormat.allCases.filter { plan.count(of: $0) > 0 }, id: \.self) { format in
                    SlateValueRow(
                        name: format.rawValue.uppercased(), value: "\(plan.count(of: format))")
                }
                SlateValueRow(name: Loc.string("To copy"), value: ByteCount.format(plan.totalBytes))
                SlateValueRow(name: Loc.string("Room needed"), value: ByteCount.format(plan.requiredBytes))
            }

            if let census = importModel.calibreCensus { calibre(census) }

            // Skipped files are named, not only counted: a skip is a decision
            // the user may disagree with, and they cannot if they cannot see it.
            if !plan.skipped.isEmpty {
                SlateInspectorSection(Loc.string("Will be skipped")) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SkippedImport.Reason.allCases, id: \.self) { reason in
                            let group = plan.skipped(for: reason)
                            if !group.isEmpty {
                                SlateValueRow(name: Loc.core(reason.label), value: Loc.number(group.count))
                            }
                        }
                    }
                }
                if plan.skipped.count <= 12 {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(plan.skipped, id: \.path) { entry in
                            Text((entry.path as NSString).lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(Slate.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            // Only when the Calibre block has not already said it. The promise
            // is worth making once and looks careless twice.
            if importModel.calibreCensus == nil {
                Text(Loc.string("The files you chose are only read. Nothing there is changed, moved or deleted."))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
    }

    private func running(_ progress: ImportRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            progressRow(
                Loc.string(
                    "Copying and verifying %1$@ of %2$@", Loc.number(progress.filesDone),
                    Loc.number(progress.filesTotal)),
                fraction: progress.fractionDone)
            Text(progress.currentTitle)
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
            if let remaining = progress.estimatedRemaining {
                Text(Loc.string("about %@ left", ImportReport.duration(remaining)))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
    }

    private func finished(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Summaries.line(for: report))
                .font(.headline)
                .foregroundStyle(report.everythingVerified ? Slate.affirm : Slate.deny)
            SlateValueRow(name: Loc.string("Copied"), value: ByteCount.format(report.copiedBytes))
            if !report.warnings.isEmpty {
                SlateValueRow(name: Loc.string("Imported with something missing"), value: "\(report.warnings.count)")
            }
            if !report.failures.isEmpty {
                SlateValueRow(name: Loc.string("Not verified"), value: "\(report.failures.count)")
            }
            // What a previous, killed run left and this one took back — the
            // difference between a resume and a second copy of everything.
            if !report.reclaimedFolders.isEmpty {
                SlateValueRow(
                    name: Loc.string("Re-used from an interrupted run"), value: "\(report.reclaimedFolders.count)")
            }
            if !report.orphanedFolders.isEmpty {
                SlateValueRow(name: Loc.string("Orphaned folders"), value: "\(report.orphanedFolders.count)")
                Text(Loc.string("Nothing was removed. Library ▸ Find Orphaned Folders… shows them."))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
            Text(
                Loc.string(
                    "The full report is in %1$@/%2$@.", Library.privateFolderName, ImportReport.fileName)
            )
            .font(.caption2)
            .foregroundStyle(Slate.textSecondary)
        }
    }

    private func progressRow(_ label: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(Slate.textPrimary)
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
        }
    }

    private func fraction(_ done: Int, _ total: Int) -> Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    // MARK: Buttons

    @ViewBuilder
    private func buttons(_ importModel: ImportModel) -> some View {
        HStack {
            Spacer()
            switch importModel.phase {
            case .finished:
                SlatePrimaryButton(Loc.string("Done")) {
                    importModel.reset()
                    dismiss()
                }
            case .running:
                // The real, running `Task` — not `importModel.cancel()`,
                // which cancels nothing: see `LibraryModel.importRunTask`.
                SlateSecondaryButton(Loc.string("Cancel")) { model.cancelImportRun() }
            case .ready:
                SlateSecondaryButton(Loc.string("Cancel")) {
                    importModel.reset()
                    dismiss()
                }
                SlatePrimaryButton(importModel.plan.isEmpty ? Loc.string("Nothing to Import") : Loc.string("Import")) {
                    model.beginImportRun()
                }
                .disabled(importModel.plan.isEmpty)
            case .idle, .examining:
                SlateSecondaryButton(Loc.string("Cancel")) {
                    importModel.cancel()
                    importModel.reset()
                    dismiss()
                }
            }
        }
    }
}
