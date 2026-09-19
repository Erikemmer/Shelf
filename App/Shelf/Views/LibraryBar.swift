import ShelfCore
import SlateKit
import SwiftUI

/// The strip above the content: what is being shown, in what order, at what
/// size, and the search field.
///
/// Its own view because the grid and the table sit under the *same* strip. Two
/// copies of it would be two places for the sort menu to drift out of step with
/// the table's own header — and the point of `BookSort` is that there is one
/// answer to "how is this sorted".
struct LibraryBar: View {
    @Environment(LibraryModel.self) private var model
    @FocusState.Binding var focus: WindowFocus?

    /// What the window says it is showing.
    ///
    /// Only a *collection's* name is a word Shelf chose — "Unread", "Missing
    /// Cover" — and only that is translated. A tag, an author, a series or a
    /// shelf is the library's own name for something, and translating one of
    /// those would rename somebody's data on the screen.
    private var filterTitle: String {
        model.filter.isNarrowed ? model.filter.title : Loc.core(model.filter.collection.title)
    }

    var body: some View {
        HStack(spacing: 12) {
            modeToggle
            SortMenu()

            Spacer(minLength: 8)

            Text(filterTitle)
                .font(.callout)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)
                // Otherwise it is a bare word in the middle of a strip full of
                // controls, and nothing says it is what the window is showing.
                .accessibilityLabel(Loc.string("Showing"))
                .accessibilityValue(filterTitle)

            Spacer(minLength: 8)

            // Only where there is a cover to size. A slider that does nothing
            // is worse than no slider: it invites the one gesture the view
            // cannot answer.
            if model.viewMode == .grid {
                Slider(
                    value: Binding(get: { model.coverSide }, set: { model.coverSide = $0 }),
                    in: LibraryModel.coverSideRange
                )
                .frame(width: 110)
                .help(Loc.string("Cover size (⌘+ / ⌘−)"))
                // A slider with no name reads as "45 percent" and nothing
                // else. The value is a fraction of the range and means
                // nothing to anybody, so the size in points is what it says.
                .accessibilityLabel(Loc.string("Cover size"))
                .accessibilityValue(Loc.count("%lld points", Int(model.coverSide.rounded())))
            }

            SearchField(focus: $focus)
                .frame(width: 200)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Slate.panelBackground)
    }

    /// Grid or table, as two segments. Left of the sort menu because it decides
    /// what the rest of the strip means.
    private var modeToggle: some View {
        Picker("", selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })) {
            ForEach(LibraryViewSettings.Mode.allCases, id: \.self) { mode in
                Image(systemName: mode.icon)
                    .tag(mode)
                    // `Loc.core`, not the bare label: `mode.label` is one of
                    // the core's English words, and a `String` handed to
                    // `accessibilityLabel` is drawn verbatim. A German window
                    // said "Grid" and "Table".
                    .accessibilityLabel(Loc.core(mode.label))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 72)
        .help(Loc.string("Covers (⌘1) or a table (⌘2)"))
        .accessibilityLabel(Loc.string("Show as"))
    }
}
