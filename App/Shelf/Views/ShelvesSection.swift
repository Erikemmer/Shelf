import ShelfCore
import SlateKit
import SwiftUI

/// The sidebar's "Shelves" section: the tree, its counts, and everything that
/// can be done to it without leaving the sidebar.
///
/// Its own file because it is the only part of the sidebar that is *editable*.
/// The other sections draw facts the index counted; this one creates, renames,
/// moves and removes — and takes books dropped on it. Mixed into `SidebarView`
/// it would have doubled that file and buried the four-line sections that are
/// only a list.
///
/// What it does **not** decide: whether a name is allowed, whether a shelf may
/// go inside another, what happens to the books on a shelf that is renamed.
/// Those are rules, they can be wrong, and they live in `ShelfEdit` in the core.
struct ShelvesSection: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    /// The shelf whose row is currently a text field. One at a time, and it is
    /// the sidebar's business rather than the model's: a half-typed name is not
    /// something the library needs to know about.
    @State private var renaming: UUID?
    @State private var draft = ""
    @State private var pendingDeletion: UUID?
    @FocusState private var isRenaming: Bool

    var body: some View {
        Group {
            header
            if model.shelfTree.isEmpty {
                empty
            } else {
                ForEach(model.visibleShelfRows, id: \.shelf.id) { row in
                    shelfRow(row)
                }
            }
        }
        .confirmationDialog(
            deletionQuestion, isPresented: isAskingAboutDeletion, titleVisibility: .visible
        ) {
            Button(Loc.string("Remove Shelf"), role: .destructive) {
                if let pendingDeletion { model.removeShelf(pendingDeletion, undoManager: undoManager) }
                pendingDeletion = nil
            }
            Button(Loc.string("Cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            // Says what is *not* happening, because "delete" beside a list of
            // books is the one word that makes people hesitate.
            Text(Loc.string("The books stay in the library. Only the shelf goes."))
        }
    }

    // MARK: The section's own row

    private var header: some View {
        HStack(spacing: 4) {
            SlateSidebarSection(SidebarSection.shelves.title)
            Spacer(minLength: 0)
            Button {
                addShelf(under: nil)
            } label: {
                Image(systemName: "plus").font(.caption2)
            }
            .buttonStyle(.plain)
            .focusable()
            .foregroundStyle(Slate.textSecondary)
            .help(Loc.string("New shelf"))
            .accessibilityLabel(Loc.string("New shelf"))
            .padding(.trailing, 12)
        }
        // A shelf dragged onto the heading comes out of whatever it was in.
        .dropDestination(for: String.self) { items, _ in
            takeShelf(from: items, under: nil)
        }
    }

    private var empty: some View {
        Text(Loc.string("No shelves yet — use + to make one"))
            .font(.caption2)
            .foregroundStyle(Slate.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
    }

    // MARK: One shelf

    @ViewBuilder
    private func shelfRow(_ row: (shelf: Shelf, depth: Int, hasChildren: Bool)) -> some View {
        let path = model.shelfTree.storedPath(of: row.shelf.id) ?? row.shelf.name
        SlateSidebarRow(
            icon: row.hasChildren ? "folder" : "books.vertical.fill",
            count: model.shelfCount(path),
            isActive: model.filter.shelfPath == path,
            help: Loc.string("Show %@ — drop books here to shelve them", path),
            title: {
                HStack(spacing: 2) {
                    // The indent is drawn here rather than by padding the whole
                    // row, so the accent wash of an active row still runs the
                    // full width of the sidebar.
                    Color.clear.frame(width: CGFloat(row.depth) * 12, height: 1)
                    disclosure(row)
                    if renaming == row.shelf.id {
                        nameField(row.shelf)
                    } else {
                        SlateSidebarTitle(row.shelf.name)
                    }
                }
            },
            // No action at all while the row is being renamed, and not merely
            // an action that does nothing. `SlateSidebarRow` makes itself
            // focusable and claims ⏎ and Space whenever it has one — so with an
            // action in place, ⏎ in the name field was swallowed by the row and
            // the rename never finished. Measured: the field showed "Fiction"
            // and the shelf stayed "New Shelf" however often ⏎ was pressed.
            action: renaming == row.shelf.id
                ? nil
                : { _ in
                    model.filter = LibraryFilter(collection: model.filter.collection, shelfPath: path)
                }
        )
        // The row's title is a stack with an indent and a triangle in it, which
        // leaves the accessibility tree with an element that has no name of its
        // own. Said here rather than left to SwiftUI to guess.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Loc.string("%1$@, %2$@", row.shelf.name, Self.books(model.shelfCount(path)))
        )
        .draggable(Self.shelfDragPrefix + row.shelf.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // One drop target, two kinds of thing: books land *on* the shelf,
            // a shelf lands *inside* it. Told apart by a prefix rather than by
            // two overlapping targets, because two targets on one row is a
            // coin toss about which one the pointer is over.
            if takeShelf(from: items, under: row.shelf.id) { return true }
            return takeBooks(from: items, onto: row.shelf.id)
        }
        .contextMenu { menu(for: row.shelf) }
    }

    @ViewBuilder
    private func disclosure(_ row: (shelf: Shelf, depth: Int, hasChildren: Bool)) -> some View {
        if row.hasChildren {
            Button {
                model.toggleCollapsed(row.shelf.id)
            } label: {
                Image(systemName: model.collapsedShelves.contains(row.shelf.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .focusable()
            .foregroundStyle(Slate.textSecondary)
            .accessibilityLabel(
                model.collapsedShelves.contains(row.shelf.id)
                    ? Loc.string("Show what is in %@", row.shelf.name)
                    : Loc.string("Fold %@ away", row.shelf.name))
        } else {
            // Holds the place of the triangle, so names line up whether or not
            // a shelf has anything in it.
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func nameField(_ shelf: Shelf) -> some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(Slate.textPrimary)
            .focused($isRenaming)
            .onSubmit { finishRenaming(shelf) }
            .onExitCommand { renaming = nil }
            // Clicking elsewhere finishes it too – the same rule as every other
            // field in this app (SlateKit's editable fields), so a name is
            // never lost by looking away.
            .onChange(of: isRenaming) { wasEditing, nowEditing in
                if wasEditing, !nowEditing { finishRenaming(shelf) }
            }
            .onAppear {
                draft = shelf.name
                // Not in the same turn of the run loop. A `@FocusState` set
                // while the field is still being inserted is set on a field
                // SwiftUI has not finished placing, and it is dropped – the row
                // turns into a text field nobody can type into, which looks
                // exactly like the rename having failed. Measured: a shelf made
                // with + came out called "New Shelf" however fast you typed.
                DispatchQueue.main.async { isRenaming = true }
            }
    }

    @ViewBuilder
    private func menu(for shelf: Shelf) -> some View {
        Button(Loc.string("Rename")) {
            draft = shelf.name
            renaming = shelf.id
        }
        Button(Loc.string("New Shelf Inside")) { addShelf(under: shelf.id) }
        Divider()
        if let path = model.shelfTree.storedPath(of: shelf.id), !model.selection.isEmpty {
            Button(addLabel(for: path)) {
                model.addToShelf(shelf.id, books: model.selectedEntries, undoManager: undoManager)
            }
        }
        Divider()
        Button(Loc.string("Remove Shelf…"), role: .destructive) { pendingDeletion = shelf.id }
    }

    private func addLabel(for path: String) -> String {
        let count = model.selection.count
        return count == 1
            ? Loc.string("Add the Selected Book")
            : Loc.string("Add the %lld Selected Books", count)
    }

    // MARK: Doing things

    private func addShelf(under parent: UUID?) {
        guard let id = model.addShelf(named: model.freeShelfName(under: parent), under: parent) else { return }
        draft = ""
        renaming = id
    }

    private func finishRenaming(_ shelf: Shelf) {
        defer { renaming = nil }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != shelf.name else { return }
        model.renameShelf(shelf.id, to: typed, undoManager: undoManager)
    }

    /// A shelf dragged onto another shelf, or onto the section heading.
    private func takeShelf(from items: [String], under parent: UUID?) -> Bool {
        guard let dragged = items.first(where: { $0.hasPrefix(Self.shelfDragPrefix) }),
            let id = UUID(uuidString: String(dragged.dropFirst(Self.shelfDragPrefix.count)))
        else { return false }
        model.moveShelf(id, under: parent, undoManager: undoManager)
        return true
    }

    /// Books dragged onto a shelf.
    private func takeBooks(from items: [String], onto shelfID: UUID) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:))
        let books = model.entries.filter { ids.contains($0.id) }
        guard !books.isEmpty else { return false }
        model.addToShelf(shelfID, books: books, undoManager: undoManager)
        return true
    }

    /// "1 book", "12 books". Spelt out because this is read aloud, and
    /// "1 books" is the kind of thing a screen reader makes very obvious.
    static func books(_ count: Int) -> String {
        Loc.count("%lld books", count)
    }

    /// What marks a dragged shelf apart from a dragged book. A plain UUID
    /// string is what a book drags, so a shelf needs something a book cannot
    /// accidentally be.
    static let shelfDragPrefix = "shelf:"

    private var isAskingAboutDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var deletionQuestion: String {
        guard let pendingDeletion, let warning = model.removalWarning(for: pendingDeletion) else {
            return Loc.string("Remove this shelf?")
        }
        switch warning.books {
        case 0: return Loc.string("Remove “%@”? It holds no books.", warning.name)
        case 1: return Loc.string("Remove “%@”? One book comes off it.", warning.name)
        default:
            return Loc.string(
                "Remove “%1$@”? %2$lld books come off it.", warning.name, warning.books)
        }
    }
}

/// The context menu on a book: which shelves it can go on, and which it is on.
///
/// Its own view so the grid and the table show the same menu. It acts on the
/// *selection* rather than on the book under the pointer whenever that book is
/// part of one — right-clicking one of twelve highlighted books and being given
/// a menu about one of them is the kind of thing that quietly loses an
/// afternoon's filing.
struct BookMenu: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let entry: LibraryEntry

    var body: some View {
        let books = subject
        if model.shelfTree.isEmpty {
            Text(Loc.string("No shelves yet"))
        } else {
            Menu(Loc.string("Add to Shelf")) {
                ForEach(model.shelfTree.inDrawnOrder(), id: \.shelf.id) { row in
                    Button(indented(row)) {
                        model.addToShelf(row.shelf.id, books: books, undoManager: undoManager)
                    }
                }
            }
        }
        if !shelvesOf(books).isEmpty {
            Menu(Loc.string("Remove from Shelf")) {
                ForEach(shelvesOf(books), id: \.self) { path in
                    Button(path) { model.removeFromShelf(path, books: books, undoManager: undoManager) }
                }
            }
        }
        Divider()
        Button(
            model.selection.count > 1
                ? Loc.string("Mark %lld Read", model.selection.count)
                : Loc.string("Toggle Read")
        ) {
            model.toggleRead(undoManager: undoManager)
        }
        Divider()
        Button(Loc.string("Show in Finder")) { model.revealSelectedInFinder() }
    }

    /// The books the menu acts on: the whole selection when this book is in it,
    /// otherwise just this book.
    private var subject: [LibraryEntry] {
        model.selection.contains(entry.id) && model.selection.count > 1 ? model.selectedEntries : [entry]
    }

    private func shelvesOf(_ books: [LibraryEntry]) -> [String] {
        Array(Set(books.flatMap(\.book.shelves))).sorted()
    }

    /// A submenu cannot nest arbitrarily deep without becoming a maze, so the
    /// hierarchy is drawn with spaces instead — the same shape the sidebar has,
    /// flattened.
    private func indented(_ row: (shelf: Shelf, depth: Int)) -> String {
        String(repeating: "    ", count: row.depth) + row.shelf.name
    }
}
