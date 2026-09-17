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
    /// The window's one focus binding. The grid has to hold it to see key
    /// presses at all, and a click on a cell asks the model for it back.
    @FocusState.Binding var focus: WindowFocus?

    var body: some View {
        Group {
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
                            BookCell(entry: entry, side: model.coverSide)
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
                .focused($focus, equals: .grid)
            }
        }
    }

    /// How many cells fit, at least one. The padding and spacing are the ones
    /// the grid above uses, so the count is right rather than approximately right.
    static func columns(for width: CGFloat, side: CGFloat) -> Int {
        let usable = width - 40  // the grid's own padding
        guard usable > side else { return 1 }
        return max(1, Int((usable + 16) / (side + 16)))
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
    @FocusState.Binding var focus: WindowFocus?

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
            .focused($focus, equals: .search)
            // ⏎ and Escape both hand the keyboard to the grid rather than
            // merely dropping it. Dropping it leaves the window with no focused
            // view, and then the arrow keys move nothing: the person is out of
            // the search box and still cannot reach their books.
            .onSubmit { model.focusGrid() }
            // Escape also empties the field, which is what every search box on
            // this platform does and what makes it the reliable way back to the
            // whole library.
            .onExitCommand {
                model.filter.searchText = ""
                model.focusGrid()
            }
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
        .help("Search titles, authors, series, tags and descriptions (⌘F); Escape clears it")
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
            // ⇧ extends, ⌘ adds or removes, neither replaces. Read off
            // `NSEvent` rather than through a gesture modifier because
            // SwiftUI's `.modifiers(_:)` on macOS swallows the plain click
            // when a modified variant is also attached.
            let flags = NSEvent.modifierFlags
            model.select(entry, extending: flags.contains(.shift), toggling: flags.contains(.command))
            // A click on a book is a statement about where the keyboard belongs.
            // Without this the search field keeps it and pressing 3 types a "3"
            // into the box instead of rating the book — measured in Sprint 2b,
            // where the library filtered to "anc1".
            model.focusGrid()
        }
        // A dragged book is its id, plain. A dragged *shelf* carries a prefix
        // (`ShelvesSection.shelfDragPrefix`), which is how one drop target on a
        // shelf row can tell "put this book here" from "put this shelf inside".
        .draggable(entry.id.uuidString) {
            // What the pointer carries. The title, because a dragged rectangle
            // with nothing in it says nothing about what is being moved.
            Text(entry.book.title).font(.caption).padding(6).background(Slate.panelBackground)
        }
        .contextMenu { BookMenu(entry: entry) }
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

/// The sort menu above the grid.
///
/// Six fields, each available both ways round, with the current one ticked. A
/// menu rather than a `Picker` because a picker of twelve entries — six fields
/// times two directions — is a list nobody can scan; a field picked twice
/// simply turns round, which is what a table header does when you click it
/// again, and the menu says so.
struct SortMenu: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        Menu {
            ForEach(BookSort.allCases, id: \.self) { field in
                Button {
                    // The same field again reverses it; a new field arrives the
                    // way round it is usually wanted — names A–Z, dates newest
                    // first.
                    model.order = model.order.field == field ? model.order.reversed : BookOrder(field)
                } label: {
                    Label(
                        field.label,
                        systemImage: model.order.field == field
                            ? (model.order.ascending ? "arrow.up" : "arrow.down") : "")
                }
            }
        } label: {
            Text(model.order.label)
                .font(.callout)
                .foregroundStyle(Slate.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 150)
        .help("How the library is ordered — the same field again turns it round")
        .accessibilityLabel("Sort order")
        .accessibilityValue(model.order.label)
    }
}
