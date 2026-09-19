import ShelfCore
import SlateKit
import SwiftUI

/// `Library ▸ Organize Library…` — the preview of every folder that would move,
/// and only then a button that moves one.
///
/// Two steps on purpose, the same shape `OrphanSheet` has and for the same
/// reason: this is the one operation in Shelf that moves a book's folder, and
/// Shelf's idea of where a book belongs is an idea. The person whose books
/// these are gets to read the list first.
///
/// What it shows is the `OrganizePlan` the runner is then handed — one value,
/// so the list somebody agreed to and the work that happens cannot differ
/// (ADR 0002, decision 6).
struct OrganizeSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.string("Organize Library…"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            switch model.organizePhase {
            case .planning, .none:
                planning
            case .ready(let plan):
                preview(plan)
            case .running(let progress):
                running(progress)
            case .done(let report):
                finished(report)
            }

            buttons
        }
        .padding(20)
        .frame(width: 640)
        .background(Slate.windowBackground)
    }

    // MARK: States

    private var planning: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView().progressViewStyle(.linear)
            Text(Loc.string("Working out where every book's folder should be. Nothing is being moved."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    @ViewBuilder
    private func preview(_ plan: OrganizePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Loc.core(plan.summary()))
                .foregroundStyle(Slate.textPrimary)

            Text(
                Loc.string(
                    "Folders are moved; the books inside them are not touched. Every folder is "
                        + "hashed before and after, and there is a way back afterwards.")
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if plan.moves.isEmpty && plan.blocked.isEmpty {
                Text(Loc.string("Every folder in this library already matches its book."))
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.moves) { move in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(move.from)
                                .font(.caption)
                                .foregroundStyle(Slate.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(verbatim: "→ \(move.to)")
                                .font(.caption)
                                .foregroundStyle(Slate.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    blocked(plan)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            .accessibilityLabel(Loc.string("Folders that would move"))
        }
    }

    /// What it cannot touch, by reason and by name. Never folded into a count:
    /// "2 cannot be" is exactly the number somebody wants the two titles for.
    @ViewBuilder
    private func blocked(_ plan: OrganizePlan) -> some View {
        ForEach(BlockedBook.Reason.allCases, id: \.self) { reason in
            let group = plan.blocked(for: reason)
            if !group.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Loc.core(reason.label))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Slate.accent)
                        .padding(.top, 6)
                    ForEach(group) { book in
                        Text(verbatim: "\(book.title) → \(book.wantedPath)")
                            .font(.caption2)
                            .foregroundStyle(Slate.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func running(_ progress: OrganizeRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
            )
            .progressViewStyle(.linear)
            Text(
                Loc.string(
                    "%1$@ of %2$@ · %3$@", "\(progress.done)", "\(progress.total)",
                    progress.currentTitle)
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            .lineLimit(1)
        }
    }

    private func finished(_ report: OrganizeReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.core(report.headline))
                .foregroundStyle(Slate.textPrimary)
            if !report.emptiedFolders.isEmpty {
                Text(
                    Loc.count(
                        "%lld author folders were left empty by the moves and removed",
                        report.emptiedFolders.count)
                )
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
            }
            if !report.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.failures, id: \.path) { failure in
                            Text(verbatim: "\(failure.title): \(failure.message)")
                                .font(.caption2)
                                .foregroundStyle(Slate.accent)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            Text(Loc.string("The full report is in .shelf/Organize-Report.txt inside the library."))
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            // Offered whenever there is a manifest, including before a run:
            // an organise from an earlier session is still undoable, because
            // the way back is a file and not the window's undo stack.
            if model.canUndoOrganize, !isRunning {
                Button(Loc.string("Undo Organize")) { model.undoOrganize() }
            }
            Spacer()
            Button(isFinished ? Loc.string("Done") : Loc.string("Cancel")) {
                model.organizePhase = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let plan) = model.organizePhase, !plan.moves.isEmpty {
                Button(Loc.count("Move %lld Folders", plan.moves.count)) {
                    model.runOrganize(plan)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = model.organizePhase { return true }
        if case .planning = model.organizePhase { return true }
        return false
    }

    private var isFinished: Bool {
        if case .done = model.organizePhase { return true }
        return false
    }
}
