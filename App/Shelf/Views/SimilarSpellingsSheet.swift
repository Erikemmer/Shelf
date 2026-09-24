import ShelfCore
import SlateKit
import SwiftUI

/// "Ähnliche Schreibweisen…" — every group `SimilarSpellings` proposes,
/// which spelling wins, and a checkbox per group so an uncertain one can be
/// left out. Nothing merges until "Merge N…" is pressed, and what merges is
/// exactly the `NameMerge` a checked group's `asMerge` already is (ADR
/// 0018) — the same "Merge into…" a person would have typed by hand.
struct SimilarSpellingsSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    @State private var accepted: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(Loc.string("Similar Spellings…"))
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            switch model.similarSpellingsPhase {
            case .ready(let groups):
                preview(groups)
            case .done(let mergedGroups, let mergedBooks):
                finished(mergedGroups: mergedGroups, mergedBooks: mergedBooks)
            case nil:
                EmptyView()
            }

            buttons
        }
        .padding(20)
        .frame(width: 640)
        .background(Slate.windowBackground)
        .onAppear {
            if case .ready(let groups) = model.similarSpellingsPhase {
                accepted = Set(groups.map(\.id))
            }
        }
    }

    @ViewBuilder
    private func preview(_ groups: [SimilarSpellingGroup]) -> some View {
        if groups.isEmpty {
            Text(Loc.string("Nothing looks like the same author or publisher spelled differently."))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        } else {
            Text(
                Loc.count("%lld group(s) proposed, checked ones merge into their winning spelling", groups.count)
            )
            .foregroundStyle(Slate.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        groupRow(group)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

    private func groupRow(_ group: SimilarSpellingGroup) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { accepted.contains(group.id) },
                    set: { isOn in
                        if isOn { accepted.insert(group.id) } else { accepted.remove(group.id) }
                    })
            )
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    Loc.string(
                        "%1$@: “%2$@” wins", group.kind == .author ? Loc.string("Author") : Loc.string("Publisher"),
                        group.winner)
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(Slate.textPrimary)
                Text(
                    group.spellings
                        .map { "\($0) (\(group.bookCounts[$0] ?? 0))" }
                        .joined(separator: ", ")
                )
                .font(.caption2)
                .foregroundStyle(Slate.textSecondary)
            }
        }
    }

    private func finished(mergedGroups: Int, mergedBooks: Int) -> some View {
        Text(Loc.string("%1$lld groups merged, %2$lld books changed", mergedGroups, mergedBooks))
            .foregroundStyle(Slate.textPrimary)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            Button(isFinished ? Loc.string("Done") : Loc.string("Cancel")) {
                model.similarSpellingsPhase = nil
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            if case .ready(let groups) = model.similarSpellingsPhase, !groups.isEmpty {
                Button(Loc.count("Merge %lld Group(s)", accepted.count)) {
                    model.applySimilarSpellings(groups.filter { accepted.contains($0.id) }, undoManager: undoManager)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(accepted.isEmpty)
            }
        }
    }

    private var isFinished: Bool {
        if case .done = model.similarSpellingsPhase { return true }
        return false
    }
}
