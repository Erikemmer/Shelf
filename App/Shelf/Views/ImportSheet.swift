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
            Text("Add Books")
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            if let importModel = model.importModel {
                content(importModel)
            } else {
                Text("No library open.").foregroundStyle(Slate.textSecondary)
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
                progressRow("Reading \(done) of \(total) files", fraction: fraction(done, total))
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
        Text("Choose books or a folder, or drop them on the window.")
            .foregroundStyle(Slate.textSecondary)
    }

    private func plan(_ importModel: ImportModel) -> some View {
        let plan = importModel.plan
        return VStack(alignment: .leading, spacing: 10) {
            Text(plan.summary())
                .font(.headline)
                .foregroundStyle(Slate.textPrimary)

            VStack(alignment: .leading, spacing: 3) {
                SlateValueRow(name: "New books", value: "\(plan.newBookCount)")
                SlateValueRow(name: "Formats added to existing books", value: "\(plan.addedFormatCount)")
                ForEach(BookFileFormat.allCases.filter { plan.count(of: $0) > 0 }, id: \.self) { format in
                    SlateValueRow(
                        name: format.rawValue.uppercased(), value: "\(plan.count(of: format))")
                }
                SlateValueRow(name: "To copy", value: ByteCount.format(plan.totalBytes))
                SlateValueRow(name: "Room needed", value: ByteCount.format(plan.requiredBytes))
            }

            // Skipped files are named, not only counted: a skip is a decision
            // the user may disagree with, and they cannot if they cannot see it.
            if !plan.skipped.isEmpty {
                SlateInspectorSection("Will be skipped") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SkippedImport.Reason.allCases, id: \.self) { reason in
                            let group = plan.skipped(for: reason)
                            if !group.isEmpty {
                                SlateValueRow(name: reason.label, value: "\(group.count)")
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

            Text("The files you chose are only read. Nothing there is changed, moved or deleted.")
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    private func running(_ progress: ImportRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            progressRow(
                "Copying and verifying \(progress.filesDone) of \(progress.filesTotal)",
                fraction: progress.fractionDone)
            Text(progress.currentTitle)
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
            if let remaining = progress.estimatedRemaining {
                Text("about \(ImportReport.duration(remaining)) left")
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
    }

    private func finished(_ report: ImportReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.headline)
                .font(.headline)
                .foregroundStyle(report.everythingVerified ? Slate.affirm : Slate.deny)
            SlateValueRow(name: "Copied", value: ByteCount.format(report.copiedBytes))
            if !report.warnings.isEmpty {
                SlateValueRow(name: "Imported with something missing", value: "\(report.warnings.count)")
            }
            if !report.failures.isEmpty {
                SlateValueRow(name: "Not verified", value: "\(report.failures.count)")
            }
            Text("The full report is in \(Library.privateFolderName)/\(ImportReport.fileName).")
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
                SlatePrimaryButton("Done") {
                    importModel.reset()
                    dismiss()
                }
            case .running:
                SlateSecondaryButton("Cancel") { importModel.cancel() }
            case .ready:
                SlateSecondaryButton("Cancel") {
                    importModel.reset()
                    dismiss()
                }
                SlatePrimaryButton(importModel.plan.isEmpty ? "Nothing to Import" : "Import") {
                    Task { await model.runImport() }
                }
                .disabled(importModel.plan.isEmpty)
            case .idle, .examining:
                SlateSecondaryButton("Cancel") {
                    importModel.cancel()
                    importModel.reset()
                    dismiss()
                }
            }
        }
    }
}
