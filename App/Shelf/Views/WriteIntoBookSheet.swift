import ShelfCore
import SlateKit
import SwiftUI

/// `Write into the Book File…` — the one place the rule that a book file is
/// never written gives way, and only after this sheet
/// (`docs/adr/0021-metadata-and-a-cover-may-be-written-into-an-epub.md`).
///
/// The same two-step shape `OrganizeSheet` has, for the same reason: nothing
/// changes until the plan somebody has read is handed back to `run`
/// unchanged, so the list agreed to and the work that happens cannot differ
/// (ADR 0002, decision 6). Three things this sheet is not allowed to do
/// quietly: it never summarises the list of fields, it never invents a
/// title or an author, and it never lets PDF, MOBI or AZW3 anywhere near a
/// write.
struct WriteIntoBookSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Ticked by hand before the button does anything — the same second
    /// deliberate act `DeleteFromDeviceSheet` asks for its one irreversible
    /// thing. This is Shelf's other one: no ⌘Z, the Trash is the way back.
    @State private var hasUnderstood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.string("Write into the Book File"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            switch model.epubWritePhase {
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
            Text(Loc.string("Working out what would change in each book's own file. Nothing is written yet."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    @ViewBuilder
    private func preview(_ plan: EPUBWrite.Plan) -> some View {
        if plan.books.isEmpty && plan.skipped.isEmpty {
            Text(Loc.string("Nothing is selected.")).foregroundStyle(Slate.textSecondary)
        } else if plan.books.isEmpty {
            Text(Loc.string("None of this can be written into.")).foregroundStyle(Slate.textPrimary)
            skippedSection(plan.skipped)
        } else {
            Text(Loc.count("%lld books will have their EPUB file replaced.", plan.books.count))
                .foregroundStyle(Slate.textPrimary)
            Text(
                Loc.string(
                    "Only the EPUB is written into — PDF, MOBI and AZW3 are left exactly as they are. "
                        + "Each book's current file goes to the Trash, not away for good, but there is "
                        + "no ⌘Z for this: look in the Trash if you need one back.")
            )
            .font(.caption)
            .foregroundStyle(Slate.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Every book, in full — a list that only shows the first
                    // few is a list somebody agrees to without having read.
                    ForEach(plan.books) { bookSection($0) }
                    if !plan.skipped.isEmpty { skippedSection(plan.skipped) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .accessibilityLabel(Loc.string("Books that will be written into"))

            Toggle(Loc.string("I have read the list above"), isOn: $hasUnderstood)
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    private func running(_ progress: EPUBWrite.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(
                value: progress.total > 0 ? Double(progress.done) / Double(progress.total) : 0
            )
            .progressViewStyle(.linear)
            Text(Loc.string("%1$@ of %2$@ · %3$@", "\(progress.done)", "\(progress.total)", progress.currentTitle))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
        }
    }

    private func finished(_ report: EPUBWrite.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Loc.count("%lld books were written into.", report.succeeded))
                .foregroundStyle(Slate.textPrimary)
            let failed = report.outcomes.filter {
                if case .failed = $0.result { return true }
                return false
            }
            if !failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(failed, id: \.entryID) { outcome in
                            if case .failed(let why) = outcome.result {
                                Text(verbatim: "\(outcome.title): \(why)")
                                    .font(.caption2)
                                    .foregroundStyle(Slate.accent)
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            if report.succeeded > 0 {
                Text(Loc.string("No ⌘Z for this. Each original is in the Trash and can be dragged back from there."))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
    }

    // MARK: One book, one field

    private func bookSection(_ plan: EPUBWrite.BookPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Slate.textPrimary)
            Text(plan.fileName)
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            ForEach(plan.changes, id: \.field) { fieldRow($0) }
        }
        .textSelection(.enabled)
    }

    private func fieldRow(_ change: EPUBWrite.FieldChange) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(Loc.label(for: change.field))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                // Old above new, struck through only when it would actually
                // be replaced — the same shape `FetchMetadataSheet` uses.
                if !change.before.isEmpty {
                    Text(change.before)
                        .font(.caption2)
                        .foregroundStyle(Slate.textSecondary)
                        .strikethrough(change.changed && change.willBeWritten)
                        .lineLimit(2)
                }
                Text(change.after.isEmpty ? Loc.string("Not set") : change.after)
                    .font(.caption)
                    .foregroundStyle(change.changed ? Slate.textPrimary : Slate.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            // Marked here, never dropped: a field Shelf cannot place still
            // belongs on this list (Sprint 10 part 2's own lesson).
            if !change.willBeWritten {
                Text(Loc.string("cannot be written"))
                    .font(.caption2)
                    .foregroundStyle(Slate.accent)
            } else if !change.changed {
                Text(Loc.string("already the same"))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: change))
    }

    private static func accessibilityLabel(for change: EPUBWrite.FieldChange) -> String {
        let field = Loc.label(for: change.field)
        if !change.willBeWritten {
            return Loc.string("%@ cannot be written", field)
        }
        if !change.changed {
            return Loc.string("%@ is already the same", field)
        }
        let before = change.before.isEmpty ? Loc.string("nothing") : change.before
        return Loc.string("%1$@ changes from %2$@ to %3$@", field, before, change.after)
    }

    /// What it cannot touch, by book and by reason. Never folded into a
    /// count: "3 skipped" is exactly the three titles somebody wants named.
    private func skippedSection(_ skipped: [EPUBWrite.Plan.Skipped]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Loc.string("Left alone"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Slate.accent)
                .padding(.bottom, 2)
            ForEach(Array(skipped.enumerated()), id: \.offset) { _, item in
                Text(verbatim: "\(item.title): \(Loc.message(for: item.failure))")
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
        .textSelection(.enabled)
    }

    // MARK: Buttons

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            Button(isFinished ? Loc.string("Close") : Loc.string("Cancel")) {
                model.epubWritePhase = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let plan) = model.epubWritePhase, !plan.books.isEmpty {
                Button(Loc.string("Write into the Book File")) { model.runEPUBWrite(plan) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasUnderstood)
            }
        }
    }

    private var isFinished: Bool {
        if case .done = model.epubWritePhase { return true }
        return false
    }
}
