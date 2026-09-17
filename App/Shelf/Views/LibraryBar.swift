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

    var body: some View {
        HStack(spacing: 12) {
            modeToggle
            SortMenu()

            Spacer(minLength: 8)

            Text(model.filter.title)
                .font(.callout)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)

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
                .help("Cover size (⌘+ / ⌘−)")
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
                    .accessibilityLabel(mode.label)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 72)
        .help("Covers (⌘1) or a table (⌘2)")
    }
}
