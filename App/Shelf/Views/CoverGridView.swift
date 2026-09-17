import AppKit
import ShelfCore
import SlateKit
import SwiftUI

/// The middle column: the covers.
///
/// A `LazyVGrid` inside a `ScrollView`, which is what makes 8 000 books
/// possible – only the cells on screen exist. Each cell asks the loader for its
/// cover and shows whatever is already in memory first, so scrolling shows
/// pictures rather than placeholders.
struct CoverGridView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    /// The grid has to hold focus to see key presses at all. It takes focus
    /// when it appears and takes it back whenever a cell is clicked.
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Slate.separator).frame(height: 1)
            if model.visible.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .background(Slate.contentBackground)
    }

    // MARK: The grid

    private var grid: some View {
        GeometryReader { geometry in
            let columns = Self.columns(for: geometry.size.width, side: model.coverSide)
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(model.coverSide), spacing: 16), count: columns),
                        spacing: 20
                    ) {
                        ForEach(model.visible) { entry in
                            BookCell(entry: entry, side: model.coverSide) { takeFocus() }
                                .id(entry.id)
                        }
                    }
                    .padding(20)
                    // The grid needs to know its own width to move the
                    // selection a whole row at a time.
                    .onAppear { model.gridColumns = columns }
                    .onChange(of: columns) { _, new in model.gridColumns = new }
                }
                // Keyboard navigation has to bring the selection into view, or
                // holding an arrow key scrolls nothing and looks broken.
                .onChange(of: model.selectedBookID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.1)) { scroller.scrollTo(id, anchor: .center) }
                }
                // Trackpad scrolling is deliberately *not* treated as an
                // interaction that pauses warming. `onScrollPhaseChange` needs
                // macOS 15 and Shelf targets 14, and the obvious substitute –
                // noting an interaction whenever a cell appears – turned out to
                // be a feedback loop: warming updated its progress, the progress
                // invalidated the sidebar, cells re-appeared, that counted as an
                // interaction, and warming paused. Measured at 285 ms per cover
                // instead of about 3 ms. See ADR 0005.
                //
                // What pauses warming instead is what the user actually does:
                // moving the selection, dragging the size slider, typing in the
                // search field. A cover decode is ~3 ms where Selector's RAW
                // decode was 600 ms, so the gate's background limit (half the
                // slots) is enough on its own here.
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onKeyPress(phases: .down) { press in editingKey(press) }
            }
        }
    }

    /// Brings the keyboard back to the grid after a click on a cover.
    ///
    /// Not simply `isFocused = true`, and the difference is the whole point.
    /// Once a text field in the inspector has been typed in and given focus up,
    /// the accessibility tree reports the *window* as focused and no control at
    /// all — but the grid's own `@FocusState` still says `true`. Assigning the
    /// value it already holds is not a change, so nothing happens, and 1–5, 0,
    /// R and T stay dead until the window is closed and opened again.
    ///
    /// Clearing it first is what makes the second assignment a change. The hop
    /// through the main queue is needed too: both assignments in one turn of the
    /// run loop collapse into "no change" again.
    ///
    /// Sprint 2a had the same line for the same reason ("otherwise clicking a
    /// book and pressing 3 does nothing") and it worked, because the only other
    /// focusable thing was the search field and clicking a cover really did take
    /// focus from it. Sprint 2b put nine text fields in the inspector and the
    /// state got out of step; found by pressing 3 after typing a tag and
    /// watching the rating stay at 0.
    private func takeFocus() {
        isFocused = false
        DispatchQueue.main.async { isFocused = true }
    }

    /// The editing keys: 1–5 rate, 0 clears, R marks read or unread, T puts the
    /// keyboard in the inspector's tag field (CONCEPT §3.3).
    ///
    /// Handled here and *not* as menu key equivalents, which is how the arrow
    /// keys are done. A menu key equivalent goes through
    /// `-[NSMenu performKeyEquivalent:]`, and a `sample` of a held arrow key
    /// showed what that costs: 31 % of the run inside
    /// `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` calling `usleep`
    /// on the main thread, and another 27 % highlighting and unhighlighting the
    /// menu bar, which drags a full window layout behind it each time. A plain
    /// digit would also be swallowed before the search field ever saw it, so
    /// "1984" could not be typed into it.
    private func editingKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.selectedEntry != nil else { return .ignored }
        switch press.characters.lowercased() {
        case "0":
            model.clearRating(undoManager: undoManager)
        case let digit where ("1"..."5").contains(digit):
            model.setStars(Int(digit) ?? 0, undoManager: undoManager)
        case "r":
            model.toggleRead(undoManager: undoManager)
        case "t":
            // Focus, not a write: T opens the tag field and the person types.
            // It also shows the inspector if it is hidden, because asking for a
            // field in a hidden panel can only mean "show me the panel".
            model.focusTagField()
        default:
            return .ignored
        }
        model.noteInteraction()
        return .handled
    }

    /// How many cells fit, at least one. The padding and spacing are the ones
    /// the grid above uses, so the count is right rather than approximately right.
    static func columns(for width: CGFloat, side: CGFloat) -> Int {
        let usable = width - 40  // the grid's own padding
        guard usable > side else { return 1 }
        return max(1, Int((usable + 16) / (side + 16)))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(get: { model.sort }, set: { model.sort = $0 })) {
                ForEach(BookSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 160)
            .help("How the grid is ordered")

            Spacer(minLength: 8)

            Text(model.filter.title)
                .font(.callout)
                .foregroundStyle(Slate.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Slider(
                value: Binding(get: { model.coverSide }, set: { model.coverSide = $0 }),
                in: LibraryModel.coverSideRange
            )
            .frame(width: 110)
            .help("Cover size (⌘+ / ⌘−)")

            SearchField()
                .frame(width: 200)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Slate.panelBackground)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(Slate.textSecondary.opacity(0.5))
            Text(model.entries.isEmpty ? "This library is empty." : "Nothing matches.")
                .foregroundStyle(Slate.textSecondary)
            if model.entries.isEmpty {
                SlatePrimaryButton("Add Books…") { model.presentAddBooksPanel() }
                Text("Or drop books anywhere in the window.")
                    .font(.caption)
                    .foregroundStyle(Slate.textSecondary)
            } else {
                SlateSecondaryButton("Show All Books") { model.filter = .everything }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The search field. Its own view so typing re-renders the field and not the
/// whole grid.
struct SearchField: View {
    @Environment(LibraryModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(Slate.textSecondary)
            TextField(
                "Search",
                text: Binding(
                    get: { model.filter.searchText },
                    set: { model.filter.searchText = $0 })
            )
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit { isFocused = false }
            if !model.filter.searchText.isEmpty {
                Button {
                    model.filter.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Slate.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Slate.contentBackground, in: RoundedRectangle(cornerRadius: Slate.cornerRadius))
        .help("Search titles, authors, series, tags and descriptions (⌘F)")
        .onReceive(of: model.focusSearchRequest) { isFocused = true }
    }
}

/// One cover in the grid.
///
/// The cover is fetched in a task keyed on the book *and* the size, so changing
/// the slider re-asks at the new size and scrolling away cancels the request.
struct BookCell: View {
    @Environment(LibraryModel.self) private var model
    let entry: LibraryEntry
    let side: CGFloat
    /// Called after a click, so the grid can take focus back from the search
    /// field – otherwise clicking a book and pressing 3 does nothing.
    var onSelect: () -> Void = {}

    @State private var cover: NSImage?

    var body: some View {
        SlateGridCell(
            side: side,
            title: entry.book.title,
            isSelected: model.selectedBookID == entry.id
        ) {
            coverImage
        } topLeading: {
            EmptyView()
        } topTrailing: {
            if entry.book.isRead {
                SlateBadgePlate { Image(systemName: "checkmark").font(.caption2) }
            }
        } bottomLeading: {
            if let drm = entry.drm {
                SlateBadgePlate { Text(drm.label).font(.caption2) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(entry)
            onSelect()
        }
        .help(help)
        .task(id: TaskKey(book: entry.id, size: size)) {
            await loadCover()
        }
    }

    /// Both halves of the key matter: the book, and the size asked for.
    private struct TaskKey: Equatable {
        let book: UUID
        let size: CoverSize
    }

    private var size: CoverSize {
        CoverSize.forCell(points: side, scale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    @ViewBuilder
    private var coverImage: some View {
        if let cover {
            Image(nsImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // A cover-shaped placeholder rather than a spinner: with a disk
            // cache the wait is a few milliseconds, and a spinner that flashes
            // is worse than a quiet rectangle.
            VStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: max(16, side / 6)))
                    .foregroundStyle(Slate.textSecondary.opacity(0.35))
                Text(entry.book.authorLine)
                    .font(.caption2)
                    .foregroundStyle(Slate.textSecondary.opacity(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var help: String {
        var lines = [entry.book.title, entry.book.authorLine]
        if let series = entry.book.series { lines.append(series.display) }
        lines.append(entry.formatLine)
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func loadCover() async {
        TimingLog.shared.cellAppeared(entry.id)
        // Whatever happens below, this cell is finished when it returns: a book
        // with no cover shows its placeholder and the user is not waiting for
        // anything more.
        defer { TimingLog.shared.coverSettled(entry.id) }
        guard let loader = model.loader else { return }
        // Whatever is in memory first, so a scrolled-to cell is not blank while
        // it waits for its own request.
        if let cached = await loader.cached(for: entry.id, size: size) {
            cover = cached
            return
        }
        cover = await loader.cover(for: entry, size: size, priority: .interactive)
    }
}

extension View {
    /// Runs `action` whenever `value` changes, for the model's one-shot
    /// requests (focus the search field). A counter rather than a Bool, so two
    /// presses in a row both arrive.
    func onReceive(of value: Int, perform action: @escaping () -> Void) -> some View {
        onChange(of: value) { _, _ in action() }
    }
}
