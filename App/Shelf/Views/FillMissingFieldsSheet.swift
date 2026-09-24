import ShelfCore
import SlateKit
import SwiftUI

/// "Fill Missing Fields…" — Teil C4. One combined preview across the whole
/// library, built entirely from `MetadataMerge`'s existing field-trust rules
/// run over every book with a valid ISBN, plus the narrow `DescriptionFill`
/// exception (ADR 0015's addendum). Nothing is asked over the network until
/// this sheet opens, and nothing is written until its own button is pressed.
struct FillMissingFieldsSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.string("Fill Missing Fields…"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            switch model.fillMissingFields?.phase {
            case .searching(let done, let total):
                searching(done: done, total: total)
            case .ready(let result):
                preview(result)
            case .done(let booksFilled, let coversFilled):
                finished(booksFilled: booksFilled, coversFilled: coversFilled)
            case nil:
                EmptyView()
            }

            buttons
        }
        .padding(20)
        .frame(width: 680)
        .background(Slate.windowBackground)
        .onAppear {
            if model.fillMissingFields?.phase == nil {
                model.beginFillMissingFieldsSearch()
            }
        }
    }

    private func searching(done: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text(Loc.string("Asking Open Library and Google Books — book %1$lld of %2$lld…", done, total))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    @ViewBuilder
    private func preview(_ result: FillMissingFields.Result) -> some View {
        if result.plans.isEmpty {
            Text(Loc.string("Nothing came back that the library did not already have."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        } else {
            Text(Loc.count("%lld book(s) would gain a field", result.plans.count))
                .foregroundStyle(Slate.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.plans, id: \.entry.id) { plan in
                        bookRow(plan)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        if !result.problems.isEmpty {
            Text(result.problems.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    private func bookRow(_ plan: FillMissingFields.BookPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(plan.entry.book.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Slate.textPrimary)
            ForEach(Array(plan.proposals.enumerated()), id: \.offset) { _, proposal in
                Text(line(proposal))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
    }

    /// "Publisher: “–” → “Verlag X” (ISBN)" — the exact value that would be
    /// written, and who it came from, so the brief's own requirement — the
    /// source shown separately for a Title+Author line — is met in the one
    /// place a person can see it before pressing anything.
    private func line(_ proposal: FillMissingFields.Proposal) -> String {
        let sourceLabel: String
        switch proposal.source {
        case .isbn: sourceLabel = "ISBN"
        case .titleAuthor: sourceLabel = Loc.string("Title+Author")
        }
        let current = proposal.current.isEmpty ? "–" : proposal.current
        let change = "“\(current)” → “\(proposal.proposed)”"
        return Loc.string("%1$@: %2$@ (%3$@)", proposal.label, change, sourceLabel)
    }

    private func finished(booksFilled: Int, coversFilled: Int) -> some View {
        Text(Loc.string("%1$lld books changed, %2$lld covers added", booksFilled, coversFilled))
            .foregroundStyle(Slate.textPrimary)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            Button(isFinished ? Loc.string("Done") : Loc.string("Cancel")) {
                model.isFillMissingFieldsSheetPresented = false
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let result) = model.fillMissingFields?.phase {
                Button(Loc.string("Apply")) {
                    isApplying = true
                    Task {
                        await model.applyFillMissingFields(result, undoManager: undoManager)
                        isApplying = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
            }
        }
    }

    private var isFinished: Bool {
        if case .done = model.fillMissingFields?.phase { return true }
        return false
    }
}
