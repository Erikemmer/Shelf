import ShelfCore
import SlateKit
import SwiftUI

/// "Merge Books…" and "Merge All Safe Groups…" — the preview of every group
/// that would merge, and only then a button that merges one.
///
/// The same two-step shape `OrganizeSheet` has, for the same reason: this
/// moves files between folders and takes books out of the library
/// (ADR 0018). What it shows is the `BookMergePlan` the runner is then
/// handed — one value, so the list somebody agreed to and the work that
/// happens cannot differ.
struct MergeSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.string("Merge Books…"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            switch model.mergePhase {
            case .planning, .none:
                planning
            case .ready(let plan):
                preview(plan)
            case .running(let progress):
                running(progress)
            case .done(let groupCount, let bookCount):
                finished(groupCount: groupCount, bookCount: bookCount)
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
            Text(Loc.string("Working out which books are the same work. Nothing is being merged."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    @ViewBuilder
    private func preview(_ plan: BookMergePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Loc.string(plan.summary()))
                .foregroundStyle(Slate.textPrimary)

            Text(
                Loc.string(
                    "Files move into the surviving book's folder; the absorbed folders go to the "
                        + "Trash, empty. Every file is hashed before and after, and there is a way back.")
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if plan.isEmpty {
                Text(Loc.string("No group of books here is safe enough to merge on its own."))
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.groups) { group in
                        groupRow(group)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func groupRow(_ group: BookMergeGroupPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                Loc.string(
                    "“%1$@” — %2$lld books become one", group.survivingTitle,
                    group.absorbedIDs.count + 1)
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(Slate.textPrimary)
            if !group.moves.isEmpty {
                Text(
                    Loc.string(
                        "Adding: %@", group.moves.map { $0.format.fileName }.sorted().joined(separator: ", "))
                )
                .font(.caption2).foregroundStyle(Slate.textSecondary)
            }
            if !group.discards.isEmpty {
                Text(
                    Loc.string(
                        "To the Trash: %@",
                        group.discards.map { $0.format.fileName }.sorted().joined(separator: ", "))
                )
                .font(.caption2).foregroundStyle(Slate.textSecondary)
            }
            if !group.conflicts.isEmpty {
                Text(
                    Loc.count(
                        "%lld field(s) disagree; the surviving book's own value is kept", group.conflicts.count)
                )
                .font(.caption2).foregroundStyle(Slate.accent)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func running(_ progress: BookMergeRunner.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text(progress.currentTitle.isEmpty ? Loc.string("Merging…") : progress.currentTitle)
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    private func finished(groupCount: Int, bookCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Loc.string("%1$lld groups merged, %2$lld books became one each", groupCount, bookCount))
                .foregroundStyle(Slate.textPrimary)
        }
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            // Offered whenever there is a manifest, including before a run:
            // a merge from an earlier session is still undoable, the same
            // way `Undo Organize` reaches past the window's own undo stack.
            if model.canUndoMerge, !isRunning {
                Button(Loc.string("Undo Merge")) { model.undoMerge() }
            }
            Spacer()
            Button(isFinished ? Loc.string("Done") : Loc.string("Cancel")) {
                model.mergePhase = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let plan) = model.mergePhase, !plan.isEmpty {
                Button(Loc.count("Merge %lld Groups", plan.groups.count)) {
                    model.runMerge(plan)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = model.mergePhase { return true }
        if case .planning = model.mergePhase { return true }
        return false
    }

    private var isFinished: Bool {
        if case .done = model.mergePhase { return true }
        return false
    }
}
