import ShelfCore
import SlateKit
import SwiftUI

/// "Standardize Fields…" — Teil C3. Unlike "Similar Spellings…", nothing
/// here is a guess: every rule (title trimmed, language folded, ISBN
/// standardized or dropped, a tag's case/whitespace variants folded) is a
/// pure function with exactly one right answer, so there is one preview and
/// one button, not a checkbox per row. What runs is exactly the plan shown
/// (ADR 0018) — `model.beginFieldStandardization()` computed it once, and
/// this sheet never recomputes it.
struct FieldStandardizationSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.string("Standardize Fields…"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            switch model.fieldStandardizationPhase {
            case .ready(let plan):
                preview(plan)
            case .done(let count):
                finished(count: count)
            case nil:
                EmptyView()
            }

            buttons
        }
        .padding(20)
        .frame(width: 640)
        .background(Slate.windowBackground)
    }

    @ViewBuilder
    private func preview(_ plan: FieldStandardizationPlan) -> some View {
        if plan.isEmpty {
            Text(Loc.string("Every title, language, ISBN and tag already reads the standardized way."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        } else {
            Text(Loc.count("%lld book(s) would change", plan.bookCount))
                .foregroundStyle(Slate.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.changes, id: \.entry.id) { entry, change in
                        bookRow(entry, change)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func bookRow(_ entry: LibraryEntry, _ change: MetadataChange) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.book.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Slate.textPrimary)
            ForEach(change.fields, id: \.self) { field in
                Text(fieldLine(field, change))
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary)
            }
        }
    }

    /// "Title: “Sturmlicht (Kindle Edition)” → “Sturmlicht”" — the exact
    /// value the field held and the exact value it will hold, per field.
    private func fieldLine(_ field: MetadataChange.Field, _ change: MetadataChange) -> String {
        switch field {
        case .title:
            return line(Loc.string("Title"), change.before.title, change.after.title)
        case .language:
            return line(Loc.string("Language"), change.before.language ?? "–", change.after.language ?? "–")
        case .identifiers:
            let before = change.before.identifiers["isbn"] ?? "–"
            let after = change.after.identifiers["isbn"] ?? Loc.string("dropped")
            return line(Loc.string("ISBN"), before, after)
        case .tags:
            return line(
                Loc.string("Tags"), change.before.tags.joined(separator: ", "),
                change.after.tags.joined(separator: ", "))
        default:
            return field.label
        }
    }

    private func line(_ label: String, _ before: String, _ after: String) -> String {
        Loc.string("%1$@: “%2$@” → “%3$@”", label, before, after)
    }

    private func finished(count: Int) -> some View {
        Text(Loc.count("%lld book(s) standardized", count))
            .foregroundStyle(Slate.textPrimary)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            Button(isFinished ? Loc.string("Done") : Loc.string("Cancel")) {
                model.fieldStandardizationPhase = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let plan) = model.fieldStandardizationPhase, !plan.isEmpty {
                Button(Loc.count("Standardize %lld Book(s)", plan.bookCount)) {
                    model.applyFieldStandardization(plan, undoManager: undoManager)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var isFinished: Bool {
        if case .done = model.fieldStandardizationPhase { return true }
        return false
    }
}
