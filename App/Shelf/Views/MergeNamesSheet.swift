import ShelfCore
import SlateKit
import SwiftUI

/// `Rename…` and `Merge into…` from a sidebar row: one spelling corrected, or
/// several folded into one.
///
/// The sheet, rather than marking rows in the sidebar, because the sidebar
/// shows **twelve** rows per section (`SidebarView.maximumRowsPerSection`) and
/// a real library has hundreds of authors. Marking three spellings of one
/// person would mean finding three rows that are mostly not on screen. Here
/// every spelling of the kind is in one searchable list with its book count
/// beside it, which is also the only view in Shelf that shows a mess of
/// spellings as a mess.
///
/// It shows the count before anything happens and nothing is written until the
/// button is pressed — and Shelf proposes nothing: which spellings are the same
/// person is a decision, and it is not this program's to make (ADR 0018).
struct MergeNamesSheet: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    let kind: NameKind
    /// The spelling the context menu was opened on. It starts ticked.
    let startingFrom: String

    @State private var chosen: Set<String> = []
    @State private var target = ""
    @State private var search = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3)
                .foregroundStyle(Slate.textPrimary)

            Text(explanation)
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            spellings
            targetField
            outcome
            buttons
        }
        .padding(20)
        .frame(width: 560)
        .background(Slate.windowBackground)
        .onAppear {
            chosen = [startingFrom]
            // A rename opens with the name itself, because it is a correction;
            // a merge opens with the spelling that was clicked, because it is
            // usually the one being kept.
            target = startingFrom
        }
    }

    private var title: String {
        chosen.count > 1
            ? Loc.string("Merge %@", Loc.core(kind.pluralLabel))
            : Loc.string("Rename %@", Loc.core(kind.label))
    }

    private var explanation: String {
        Loc.string(
            "Tick every spelling that is the same %1$@ and type the one they should all have. "
                + "Shelf changes the metadata of every book concerned, as one step you can undo. "
                + "It does not move any folder — “%2$@” does that, and it asks first.",
            Loc.core(kind.label).lowercased(), Loc.string("Organize Library…"))
    }

    // MARK: The list

    private var allNames: [LibraryIndex.Facet] {
        let all = model.allNames(of: kind)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        // A ticked spelling stays visible whatever is typed, or a search would
        // silently drop it out of the merge the moment the list was narrowed.
        return all.filter { $0.name.lowercased().contains(needle) || chosen.contains($0.name) }
    }

    private var spellings: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(Loc.string("Search these %@", Loc.core(kind.pluralLabel).lowercased()), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Loc.string("Search these %@", Loc.core(kind.pluralLabel).lowercased()))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allNames) { facet in
                        Toggle(
                            isOn: Binding(
                                get: { chosen.contains(facet.name) },
                                set: { on in
                                    if on { chosen.insert(facet.name) } else { chosen.remove(facet.name) }
                                })
                        ) {
                            HStack(spacing: 8) {
                                Text(facet.name)
                                    .font(.callout)
                                    .foregroundStyle(Slate.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Loc.count("%lld books", facet.count))
                                    .font(.caption2)
                                    .foregroundStyle(Slate.textSecondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 220)
            .accessibilityLabel(Loc.string("Spellings"))
        }
    }

    // MARK: The target

    private var targetField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Loc.string("They all become"))
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
            TextField(Loc.string("The spelling to keep"), text: $target)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Loc.string("The spelling to keep"))
            // The quickest way to pick a target is one of the ticked
            // spellings, so they are buttons rather than something to retype.
            if chosen.count > 1 {
                HStack(spacing: 6) {
                    ForEach(chosen.sorted(), id: \.self) { name in
                        Button(name) { target = name }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: What it would do

    private var merge: NameMerge {
        NameMerge(kind: kind, sources: Array(chosen), target: target)
    }

    @ViewBuilder
    private var outcome: some View {
        if let refusal = merge.refusal {
            Text(Loc.core(refusal))
                .font(.caption)
                .foregroundStyle(Slate.accent)
        } else {
            // The count is computed from the very value the button executes,
            // so what is promised and what happens cannot differ.
            Text(model.plan(for: merge).summary())
                .font(.caption)
                .foregroundStyle(Slate.textSecondary)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(Loc.string("Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(chosen.count > 1 ? Loc.string("Merge") : Loc.string("Rename")) {
                isWorking = true
                Task {
                    await model.applyMerge(merge, undoManager: undoManager)
                    isWorking = false
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(merge.refusal != nil || isWorking || model.plan(for: merge).isEmpty)
        }
    }
}
