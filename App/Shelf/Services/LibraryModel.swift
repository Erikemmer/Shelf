import AppKit
import Observation
import ShelfCore
import os

/// What in the window has the keyboard.
///
/// One value for the whole window rather than a `Bool` per control: see
/// `LibraryModel.focusTarget`.
enum WindowFocus: Hashable {
    case grid
    case search
    /// Something that owns its own focus — the inspector's fields and its tag
    /// field. Naming it is what lets the window's binding step aside instead of
    /// claiming a focus it is not holding.
    case elsewhere
}

/// What the window is looking at, and every action it can take.
///
/// `@MainActor` throughout, with the work handed to actors (`LibraryIndex`,
/// `CoverLoader`) and detached tasks. The rule from Selector: the view model
/// holds state and orchestrates; nothing slow happens on the main actor.
@MainActor
@Observable
final class LibraryModel {
    private static let logger = Logger(subsystem: "de.erikemmer.shelf", category: "library")

    // MARK: What is open

    private(set) var library: Library?
    private(set) var descriptor: LibraryDescriptor?
    /// Every book in the library, in the current sort order. Held whole: 8 000
    /// entries are a few megabytes, and filtering them in memory is under a
    /// millisecond where a query per sidebar click would be a round trip.
    private(set) var entries: [LibraryEntry] = []
    private(set) var isLoading = false
    /// Books whose cover is in the cache – what "Missing Cover" is answered from.
    private(set) var coversOnDisk: Set<UUID> = []

    // MARK: What is being shown

    var filter = LibraryFilter.everything {
        didSet { if filter != oldValue { refilter() } }
    }
    /// How the library is ordered, and what the table's header arrow points at.
    ///
    /// Written back to `library.json` whenever it changes, so a library opens
    /// the way it was left. The re-sort is a query rather than a sort in
    /// memory: `BookSort` owns the SQL order, and a second sort here would be a
    /// second answer to "what does by author mean".
    var order: BookOrder = .byTitle {
        didSet {
            guard order != oldValue else { return }
            rememberView()
            reloadEntries()
        }
    }

    /// Grid or table. The same selection, the same keys, the same inspector –
    /// only the drawing differs.
    var viewMode: LibraryViewSettings.Mode = .grid {
        didSet { if viewMode != oldValue { rememberView() } }
    }

    /// SwiftUI's own record of which table columns are hidden and how wide they
    /// are. Kept opaque – see `LibraryViewSettings.tableColumns`.
    var tableColumns: String? {
        didSet { if tableColumns != oldValue { rememberView() } }
    }

    /// Saves how the library is being looked at, without touching anything
    /// else in the descriptor.
    private func rememberView() {
        guard var descriptor, let library else { return }
        let settings = LibraryViewSettings(mode: viewMode, order: order, tableColumns: tableColumns)
        guard descriptor.view != settings else { return }
        descriptor.view = settings
        try? library.write(descriptor)
        self.descriptor = descriptor
    }
    /// The books the grid shows: `entries` after the filter and the search.
    private(set) var visible: [LibraryEntry] = []
    /// The book the inspector shows and the arrow keys move from.
    ///
    /// Also the *anchor* of a multiple selection: ⇧-click selects from here to
    /// there, and every selection has exactly one of these, so "the book being
    /// looked at" is never ambiguous even when twelve are highlighted.
    var selectedBookID: UUID? {
        didSet {
            guard selectedBookID != oldValue else { return }
            // A plain move of the anchor — arrow keys, a filter hiding the old
            // one — is a selection of one. Anything that means otherwise goes
            // through `select(_:extending:toggling:)` and sets both.
            selection = selectedBookID.map { [$0] } ?? []
            selectionChanged()
        }
    }

    /// Every selected book, the anchor included.
    ///
    /// A set and not an array: the order of a selection carries no meaning —
    /// what carries meaning is the order of the grid, which `selectedEntries`
    /// reads back off `visible`. Keeping an order here would invent a second
    /// one that only the selection knows about.
    private(set) var selection: Set<UUID> = []

    /// Cover size in points, driven by the slider and ⌘±.
    var coverSide: CGFloat = 160 {
        didSet { noteInteraction() }
    }
    static let coverSideRange: ClosedRange<CGFloat> = 90...320
    static let coverSideStep: CGFloat = 30

    var isInspectorShown = true

    // MARK: Who has the keyboard

    /// Where the keyboard should go. The window keeps *one* focus state and
    /// this is how anything asks it to move.
    ///
    /// Two independent `@FocusState` bindings — one on the grid, one on the
    /// search field — cannot hand the keyboard to each other: setting the
    /// grid's to `true` while the field's is still `true` asks SwiftUI to
    /// focus two things, and which one wins is a race. Sprint 2b lost that
    /// race often enough to ship with "clicking a cover does not reliably take
    /// the keyboard from the search field" in the backlog. One binding with an
    /// enum value has no such state: `.grid` is not `.search`, so moving to one
    /// *is* leaving the other.
    ///
    /// A counter beside it, because "focus the search field" has to work twice
    /// in a row — pressing ⌘F while the field already holds the keyboard is a
    /// request, not a no-op, and a value that is already what it should be
    /// produces no `onChange`.
    private(set) var focusTarget: WindowFocus = .grid
    private(set) var focusRequest = 0

    func focusSearch() {
        focusTarget = .search
        focusRequest += 1
    }

    /// Clicking a cover, Escape in the search field, ⏎ in the search field.
    /// After this the editing keys land on the book rather than in the box.
    func focusGrid() {
        focusTarget = .grid
        focusRequest += 1
    }

    // MARK: The sidebar's contents

    private(set) var totals = LibraryIndex.Totals()
    private(set) var tagFacets: [LibraryIndex.Facet] = []
    private(set) var authorFacets: [LibraryIndex.Facet] = []
    private(set) var seriesFacets: [LibraryIndex.Facet] = []
    private(set) var formatFacets: [LibraryIndex.Facet] = []
    /// Which books look like copies of another, and by which of the three
    /// rules. Asked of the index once per reload rather than per filter: it is
    /// three queries and a fold over every title, which is worth doing once for
    /// 5 000 books and not once per click.
    private(set) var duplicateReasons: [UUID: Set<DuplicateReason>] = [:]

    // MARK: Messages

    /// Shown as a banner over the content. Cleared by the next successful action.
    private(set) var errorMessage: String?
    /// The warning a library in a synced folder gets (CONCEPT §12).
    private(set) var syncWarning: String?

    // MARK: Import

    var isImportSheetPresented = false
    private(set) var importModel: ImportModel?

    // MARK: Services

    let recents = RecentLibrariesStore()
    let warmer = CoverWarmer()
    private(set) var loader: CoverLoader?
    @ObservationIgnored private var index: LibraryIndex?
    /// Cleared 250 ms after the last scroll or key press, which is when warming
    /// may start again.
    @ObservationIgnored private var interaction = InteractionWindow()
    @ObservationIgnored private var interactionTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    // MARK: Opening and creating

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Library"
        panel.message = "Choose a Shelf library folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func presentNewLibraryPanel() {
        let panel = NSSavePanel()
        panel.prompt = "Create Library"
        panel.message = "Choose where the new library folder goes."
        panel.nameFieldStringValue = "My Library"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createLibrary(at: url)
    }

    func createLibrary(at url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try Library.create(at: url)
            open(url)
        } catch {
            show(error, doing: "create a library at \(url.lastPathComponent)")
        }
    }

    /// Opens a library folder, or offers to make one when the folder is not a
    /// library yet.
    func open(_ url: URL) {
        recents.beginAccess(to: url)
        guard Library.isLibrary(url) else {
            // A plain folder is a reasonable thing to drop; say what is missing
            // and what to do rather than only refusing.
            errorMessage =
                "“\(url.lastPathComponent)” is not a Shelf library. "
                + "Use New Library… to make one there, or open a folder that already holds one."
            return
        }
        Task { await load(url) }
    }

    func open(recent entry: RecentLibrary) {
        guard let url = recents.openable(entry) else {
            errorMessage = "“\(entry.name)” is not available right now. Is the disk connected?"
            return
        }
        open(url)
    }

    private func load(_ url: URL) async {
        isLoading = true
        defer { isLoading = false }
        TimingLog.shared.libraryOpenBegan(url.lastPathComponent)
        do {
            let (library, descriptor) = try Library.open(url)
            let index = try LibraryIndex(library: library)
            let loader = CoverLoader(library: library)

            self.library = library
            self.descriptor = descriptor
            // Before anything is read, so the first query is in the order the
            // library was left in rather than in the default one.
            order = descriptor.view.order
            viewMode = descriptor.view.mode
            tableColumns = descriptor.view.tableColumns
            self.index = index
            self.loader = loader
            importModel = ImportModel(library: library, index: index)
            errorMessage = nil
            syncWarning = library.syncWarning
            warmer.reset()

            coversOnDisk = await loader.cachedBookIDs()
            await reload()
            // A library that has just opened should answer the arrow keys. The
            // grid only becomes focusable once it exists, which is after this
            // load, so the request is made here rather than in an `onAppear`
            // the welcome screen would have swallowed.
            focusGrid()
            TimingLog.shared.entriesReady(entries.count)
            recents.record(library, bookCount: entries.count)

            // Once per open, in the background: a cache over its limit is
            // trimmed oldest first.
            Task.detached(priority: .background) { await loader.trimDiskCache() }
        } catch {
            show(error, doing: "open \(url.lastPathComponent)")
        }
    }

    func closeLibrary() {
        library = nil
        descriptor = nil
        index = nil
        loader = nil
        importModel = nil
        entries = []
        visible = []
        selectedBookID = nil
        totals = LibraryIndex.Totals()
        tagFacets = []
        authorFacets = []
        seriesFacets = []
        formatFacets = []
        duplicateReasons = [:]
        warmer.reset()
    }

    // MARK: Reading the index

    /// Everything the window shows about a library, in one pass.
    func reload() async {
        guard let index else { return }
        do {
            entries = try await index.allEntries(sortedBy: order)
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            tagFacets = try await index.tagFacets()
            authorFacets = try await index.authorFacets()
            seriesFacets = try await index.seriesFacets()
            formatFacets = try await index.formatFacets()
            duplicateReasons = try await index.duplicates()
            totals.duplicates = duplicateReasons.count
            refilter()
        } catch {
            show(error, doing: "read the library index")
        }
    }

    private func reloadEntries() {
        Task { await reload() }
    }

    /// Applies the filter and the search to `entries`.
    ///
    /// The facets are matched in memory; only the text search goes to the index,
    /// because only FTS5 can answer it.
    private func refilter() {
        let text = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            applyFilter(matching: nil)
            return
        }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self, let index = self.index else { return }
            // Debounced: the field re-queries on every keystroke, and FTS5 is
            // fast but not free.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let ids = (try? await index.search(text)) ?? []
            guard !Task.isCancelled else { return }
            self.applyFilter(matching: Set(ids))
        }
    }

    private func applyFilter(matching ids: Set<UUID>?) {
        let duplicates = filter.collection == .duplicates ? Set(duplicateReasons.keys) : []
        visible = entries.filter { entry in
            if let ids, !ids.contains(entry.id) { return false }
            return filter.matches(entry, coversOnDisk: coversOnDisk, duplicateBooks: duplicates)
        }
        // Narrowed to one series, the grid is in series order, whatever the
        // sort menu says. A series has exactly one order that means anything,
        // and "Mistborn 3.5 between 3 and 4" is the reason the index is a
        // `Double`. Sorted in memory rather than by asking the index again:
        // a few thousand rows sort in well under a millisecond, where a query
        // per sidebar click is a round trip.
        if filter.series != nil {
            visible.sort { left, right in
                let ours = left.book.series?.index ?? .greatestFiniteMagnitude
                let theirs = right.book.series?.index ?? .greatestFiniteMagnitude
                if ours != theirs { return ours < theirs }
                return left.book.titleSort.localizedCaseInsensitiveCompare(right.book.titleSort)
                    == .orderedAscending
            }
        }
        // A selection the filter just hid is not kept: the inspector would show
        // a book that is not on screen.
        if let selected = selectedBookID, !visible.contains(where: { $0.id == selected }) {
            selectedBookID = visible.first?.id
        } else if selectedBookID == nil {
            selectedBookID = visible.first?.id
        }
        warmVisible()
    }

    // MARK: Selection

    var selectedEntry: LibraryEntry? {
        guard let selectedBookID else { return nil }
        return visible.first { $0.id == selectedBookID } ?? entries.first { $0.id == selectedBookID }
    }

    var selectedIndex: Int? {
        guard let selectedBookID else { return nil }
        return visible.firstIndex { $0.id == selectedBookID }
    }

    /// The books an action applies to, in the order they are on screen.
    ///
    /// `visible` first so a rating applied to twelve books happens in the order
    /// somebody sees them, and `entries` afterwards for a book the filter has
    /// since hidden — a selection outliving a filter change is better than an
    /// action silently skipping part of it.
    var selectedEntries: [LibraryEntry] {
        guard !selection.isEmpty else { return [] }
        var found = visible.filter { selection.contains($0.id) }
        if found.count < selection.count {
            let missing = selection.subtracting(found.map(\.id))
            found += entries.filter { missing.contains($0.id) }
        }
        return found
    }

    /// Whether more than one book is selected — what the inspector asks before
    /// it decides between a value and "Mixed".
    var hasMultipleSelection: Bool { selection.count > 1 }

    func select(_ entry: LibraryEntry) {
        selectedBookID = entry.id
    }

    /// A click, with whatever was held down.
    ///
    /// ⇧ extends from the anchor, ⌘ adds or removes one, neither replaces the
    /// selection — the three gestures every list on this platform has. The
    /// anchor moves to the clicked book in all three cases: it is the book the
    /// inspector shows, and clicking a book while holding ⌘ is still a
    /// statement about which book you mean.
    func select(_ entry: LibraryEntry, extending: Bool, toggling: Bool) {
        if extending, let anchor = selectedBookID,
            let from = visible.firstIndex(where: { $0.id == anchor }),
            let to = visible.firstIndex(where: { $0.id == entry.id })
        {
            let range = from <= to ? from...to : to...from
            selection = Set(visible[range].map(\.id))
            // Set directly: going through `selectedBookID` would reset the
            // selection to one book, because that is what a plain move means.
            setAnchorKeepingSelection(entry.id)
            return
        }
        if toggling {
            if selection.contains(entry.id), selection.count > 1 {
                selection.remove(entry.id)
                if selectedBookID == entry.id {
                    setAnchorKeepingSelection(selection.first)
                }
                return
            }
            selection.insert(entry.id)
            setAnchorKeepingSelection(entry.id)
            return
        }
        selectedBookID = entry.id
    }

    /// The whole selection at once — what a table's own selection binding sets.
    ///
    /// The anchor is kept if it is still in there, and otherwise moved to
    /// whichever of the selected books comes first on screen: the inspector has
    /// to show one of the books that are selected, not one that is not.
    func replaceSelection(_ ids: Set<UUID>) {
        guard ids != selection else { return }
        if let anchor = selectedBookID, ids.contains(anchor) {
            selection = ids
            return
        }
        let first = visible.first { ids.contains($0.id) }?.id ?? ids.first
        selection = ids
        setAnchorKeepingSelection(first)
    }

    func selectAll() {
        guard !visible.isEmpty else { return }
        selection = Set(visible.map(\.id))
        if selectedBookID == nil || !selection.contains(selectedBookID ?? UUID()) {
            setAnchorKeepingSelection(visible.first?.id)
        }
    }

    /// Moves the anchor without collapsing the selection to it.
    ///
    /// `selectedBookID`'s own `didSet` means "one book is selected now", which
    /// is right for an arrow key and wrong for a ⇧-click. Both are needed, so
    /// the selection is put back after the anchor moves.
    private func setAnchorKeepingSelection(_ id: UUID?) {
        let keep = selection
        selectedBookID = id
        selection = keep.isEmpty ? (id.map { [$0] } ?? []) : keep
    }

    func selectNext() {
        move(by: 1)
    }

    func selectPrevious() {
        move(by: -1)
    }

    /// One row down or up in the grid. The columns are decided by the view, so
    /// it tells the model how wide a row is.
    var gridColumns = 1

    func selectRowBelow() {
        move(by: max(1, gridColumns))
    }

    func selectRowAbove() {
        move(by: -max(1, gridColumns))
    }

    func selectFirst() {
        selectedBookID = visible.first?.id
    }

    func selectLast() {
        selectedBookID = visible.last?.id
    }

    private func move(by offset: Int) {
        guard !visible.isEmpty else { return }
        noteInteraction()
        let current = selectedIndex ?? 0
        let next = min(max(current + offset, 0), visible.count - 1)
        selectedBookID = visible[next].id
    }

    private func selectionChanged() {
        warmVisible()
    }

    // MARK: Warming and interaction

    /// Called on every scroll, key repeat and slider drag.
    ///
    /// Warming stands still while this window is open: a decode cannot be
    /// called back once started, so not starting one is the only lever there is
    /// (Selector's ADR 0003, follow-up).
    func noteInteraction() {
        interaction.note()
        guard let loader else { return }
        interactionTask?.cancel()
        interactionTask = Task { [weak self] in
            await loader.setInteracting(true)
            guard let remaining = self?.interaction.remainingQuietTime() else {
                await loader.setInteracting(false)
                return
            }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled, self?.interaction.isActive() == false else { return }
            await loader.setInteracting(false)
        }
    }

    private func warmVisible() {
        guard let loader else { return }
        warmer.warm(visible, around: selectedIndex ?? 0, using: loader)
    }

    // MARK: Cover size

    func enlargeCovers() {
        coverSide = min(Self.coverSideRange.upperBound, coverSide + Self.coverSideStep)
    }

    func shrinkCovers() {
        coverSide = max(Self.coverSideRange.lowerBound, coverSide - Self.coverSideStep)
    }

    // MARK: Adding books

    func presentAddBooksPanel() {
        guard let importModel else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose books or a folder of books to add."
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        isImportSheetPresented = true
        Task { await importModel.examine(panel.urls) }
    }

    /// Books dropped on the window. The same path as the panel, so the counting
    /// protocol appears either way – nothing is copied without being shown first.
    func handleDrop(_ urls: [URL]) {
        guard let importModel else {
            // Dropping a library folder onto the welcome screen opens it.
            if let first = urls.first, first.hasDirectoryPath { open(first) }
            return
        }
        guard !urls.isEmpty else { return }
        isImportSheetPresented = true
        Task { await importModel.examine(urls) }
    }

    /// Runs the import the sheet is showing, then reloads.
    func runImport() async {
        guard let importModel, let library, let index else { return }
        await importModel.run()
        // The descriptor's counter moved on, so it has to be written back.
        if var descriptor {
            descriptor.nextBookNumber = importModel.nextBookNumber
            try? library.write(descriptor)
            self.descriptor = descriptor
        }
        if let loader { coversOnDisk = await loader.cachedBookIDs() }
        _ = index
        await reload()
    }

    // MARK: Editing metadata

    /// Applies a change: register the undo first, then write the file, then the
    /// index.
    ///
    /// The order is Selector's, and the reason Sprint 2 starts here rather than
    /// bolting undo on afterwards. The *previous value* goes on the undo stack
    /// before anything is written, because once the file is written nobody can
    /// ask it what it used to say. Registering the inverse from inside the undo
    /// block is what gives redo for nothing: `UndoManager` records whatever is
    /// registered while undoing as the redo action.
    ///
    /// `undoManager` is the window's, handed in by the view from
    /// `@Environment(\.undoManager)` – so ⌘Z belongs to the window the change
    /// was made in, the way every other document app behaves.
    func apply(_ change: MetadataChange, to entry: LibraryEntry, undoManager: UndoManager?) {
        guard !change.isEmpty else { return }
        let startedAt = ContinuousClock.now

        undoManager?.registerUndo(withTarget: self) { model in
            // `UndoManager` calls this on the thread that registered it, which
            // is the main thread; nothing here hops queues.
            MainActor.assumeIsolated {
                model.apply(change.inverse, to: entry, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(change.actionName)

        Task { await write(change, to: entry, startedAt: startedAt) }
    }

    private func write(_ change: MetadataChange, to entry: LibraryEntry, startedAt: ContinuousClock.Instant) async {
        guard let library, let index else { return }
        let editor = MetadataEditor(library: library)
        do {
            let updated = try await editor.apply(change, to: entry, in: index)
            TimingLog.shared.metadataWritten(change.actionName, since: startedAt)
            replace(updated)
            // The sidebar's "Unread" has to be right the moment R is pressed;
            // it is one query, not a reload of 5 000 entries.
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            if change.fields.contains(.tags) { tagFacets = try await index.tagFacets() }
            if change.fields.contains(.authors) { authorFacets = try await index.authorFacets() }
            if change.fields.contains(.series) { seriesFacets = try await index.seriesFacets() }
            // So a book that has just been marked read leaves "Unread" at once.
            refilter()
            errorMessage = nil
        } catch {
            show(error, doing: "save the change to “\(entry.book.title)”")
        }
    }

    /// Replaces one entry in place.
    ///
    /// Not a reload: reading 5 000 entries back takes about 350 ms, and a key
    /// held down would queue one of those per press. The index is the authority
    /// and it has just been written; the row in memory is brought level with it.
    private func replace(_ updated: LibraryEntry) {
        if let position = entries.firstIndex(where: { $0.id == updated.id }) {
            entries[position] = updated
        }
        if let position = visible.firstIndex(where: { $0.id == updated.id }) {
            visible[position] = updated
        }
    }

    /// Stars from the inspector and from the keys 1–5. Clicking or pressing the
    /// rating a book already has clears it, which is how every rating control
    /// that is worth using behaves – otherwise there is no way back to unrated.
    func setStars(_ stars: Int, undoManager: UndoManager?) {
        let books = selectedEntries
        guard !books.isEmpty else { return }
        // Clicking the rating a book already has clears it, which is how every
        // rating control worth using behaves — otherwise there is no way back
        // to unrated. Across a selection the *shared* rating decides: twelve
        // books already at three stars go to unrated, a mixed twelve go to
        // three, because "make these all three" is the useful half.
        let shared = AcrossBooks.sharedStars(books.map(\.book))
        let wanted = shared == stars ? 0 : stars
        edit(books, actionName: "Rating", undoManager: undoManager) { $0.stars = wanted }
    }

    /// The 0 key: unrated, whatever it was.
    func clearRating(undoManager: UndoManager?) {
        edit(selectedEntries, actionName: "Rating", undoManager: undoManager) { $0.stars = 0 }
    }

    /// R, and the checkbox in the inspector.
    func toggleRead(undoManager: UndoManager?) {
        let books = selectedEntries
        guard !books.isEmpty else { return }
        let wanted = AcrossBooks.readStatusAfterToggle(books.map(\.book))
        edit(books, actionName: "Read Status", undoManager: undoManager) { $0.isRead = wanted }
    }

    // MARK: Editing the text fields

    /// Why the last edit was refused, and which field refused it.
    ///
    /// Held here rather than in the view so the message survives the field
    /// losing focus — which is exactly when it appears.
    struct FieldRejection: Equatable {
        /// `BookField.rawValue`, or `identifier:<scheme>`.
        var key: String
        var message: String
    }

    private(set) var fieldRejection: FieldRejection?

    /// A finished field: ⏎ or focus lost.
    ///
    /// One write per completion, which is the whole of the debouncing this
    /// sprint needs. Sprint 2a measured 5–8 ms for a write and decided a rating
    /// did not need debouncing; a text field would have written a file per
    /// keystroke, and the answer is not a timer but the right event. A timer
    /// would still write a file in the middle of a word, and it would have to
    /// be flushed before the window closed.
    ///
    /// The rules are the core's (`BookField.apply`), so nothing about what an
    /// empty value means or how authors are separated is decided here.
    func commit(_ field: BookField, _ typed: String, undoManager: UndoManager?) {
        // One book at a time. A title, a series or a description typed once and
        // written to twelve books is not an edit, it is a mistake with twelve
        // copies — so the inspector draws these read-only when several books
        // are selected, and this refuses them even if something else asks.
        guard !hasMultipleSelection, let entry = selectedEntry else { return }
        handle(field.apply(typed, to: entry.book), key: field.rawValue, entry: entry, undoManager: undoManager)
    }

    func commitIdentifier(scheme: String, value: String, undoManager: UndoManager?) {
        // An ISBN belongs to one edition. Twelve books with the same one would
        // be twelve duplicates of each other.
        guard !hasMultipleSelection, let entry = selectedEntry else { return }
        handle(
            IdentifierEdit.set(scheme: scheme, value: value, in: entry.book),
            key: "identifier:\(scheme.lowercased())", entry: entry, undoManager: undoManager)
    }

    /// Adds a tag to every selected book, in one undo step.
    ///
    /// Through `TagEdit` per book, so the canonical spelling of an existing tag
    /// wins ("Sci-Fi" typed where the library says "sci-fi") and a book that
    /// already has it is left alone rather than rewritten.
    func addTag(_ name: String, undoManager: UndoManager?) {
        let books = selectedEntries
        guard !books.isEmpty else { return }
        fieldRejection = nil
        // `TagEdit.add` per book, not a canonical spelling worked out once: the
        // rule for what a tag becomes ("Sci-Fi" typed where the library says
        // "sci-fi") lives there, and a second copy of it here would be a second
        // rule. A book that already has the tag comes back `.unchanged` and is
        // not rewritten.
        let known = knownTags
        edit(books, actionName: "Tags", undoManager: undoManager) { book in
            if case .changed(let edited) = TagEdit.add(name, to: book, knownTags: known) {
                book = edited
            }
        }
        tagDraft = ""
    }

    func removeTag(_ name: String, undoManager: UndoManager?) {
        edit(selectedEntries, actionName: "Tags", undoManager: undoManager) { book in
            book.tags.removeAll { $0 == name }
        }
    }

    /// Turns one outcome into a change, a message, or nothing at all.
    private func handle(
        _ outcome: BookFieldOutcome, key: String, entry: LibraryEntry, undoManager: UndoManager?
    ) {
        switch outcome {
        case .unchanged:
            // Not an error and not a write. Clearing the note is right: the
            // field now holds something acceptable.
            if fieldRejection?.key == key { fieldRejection = nil }
        case .rejected(let why):
            fieldRejection = FieldRejection(key: key, message: why.message)
        case .changed(let edited):
            fieldRejection = nil
            apply(
                MetadataChange.make(from: entry.book) { $0 = edited }, to: entry,
                undoManager: undoManager)
        }
    }

    /// Whether a field should show a note, and what it says.
    func rejection(for key: String) -> String? {
        fieldRejection?.key == key ? fieldRejection?.message : nil
    }

    // MARK: The tag field

    /// Every tag in the library, which is what completion is drawn from. The
    /// sidebar's facets already hold them, so this is not a second query.
    var knownTags: [String] { tagFacets.map(\.name) }

    /// What is being typed in the tag field. Held here because the completions
    /// are computed from it and the view should not own two copies.
    private(set) var tagDraft = ""

    func updateTagDraft(_ text: String) {
        tagDraft = text
    }

    var tagCompletions: [String] {
        // Excluding what *every* selected book already has: a tag only some of
        // them carry is still worth offering, because adding it is what
        // finishes the job.
        TagEdit.completions(
            for: tagDraft, among: knownTags,
            excluding: AcrossBooks.sharedTags(selectedEntries.map(\.book)))
    }

    // MARK: What a selection of several books shows

    /// The value every selected book shows, or `nil` for "Mixed".
    func sharedText(_ field: BookField) -> String? {
        field.sharedText(across: selectedEntries.map(\.book))
    }

    /// The rating every selected book has, or `nil` when they differ.
    var sharedStars: Int? { AcrossBooks.sharedStars(selectedEntries.map(\.book)) }

    var sharedReadStatus: Bool? { AcrossBooks.sharedReadStatus(selectedEntries.map(\.book)) }

    /// Tags on every selected book — removing one of these acts on all of them.
    var sharedTags: [String] { AcrossBooks.sharedTags(selectedEntries.map(\.book)) }

    /// Tags on some of them. Drawn apart from the shared ones, or removing one
    /// would quietly do nothing to most of the books.
    var mixedTags: [String] { AcrossBooks.mixedTags(selectedEntries.map(\.book)) }

    var sharedShelves: [String] { AcrossBooks.sharedShelves(selectedEntries.map(\.book)) }

    var mixedShelves: [String] { AcrossBooks.mixedShelves(selectedEntries.map(\.book)) }

    /// Bumped by T. A counter, so pressing T twice focuses twice (the same
    /// reason `focusSearchRequest` is one).
    private(set) var focusTagFieldRequest = 0

    func focusTagField() {
        // The inspector has to be open for its tag field to take focus, and T
        // is a reasonable way to ask for both at once.
        isInspectorShown = true
        // The tag field lives in the inspector and owns its own focus state,
        // so the window's binding has to let go or SwiftUI is being asked for
        // two focused fields again.
        focusTarget = .elsewhere
        focusRequest += 1
        focusTagFieldRequest += 1
    }

    // MARK: Shelves

    /// The shelves, as `library.json` holds them.
    ///
    /// Derived from the descriptor rather than kept beside it: two copies of a
    /// tree are two trees that will differ, and the descriptor is the one that
    /// gets written to disk.
    var shelfTree: ShelfTree { ShelfTree(descriptor?.shelves ?? []) }

    /// Shelves whose children are folded away. Collapsed rather than expanded
    /// so a new shelf's children are visible the moment it has any.
    var collapsedShelves: Set<UUID> = []

    func toggleCollapsed(_ id: UUID) {
        if collapsedShelves.contains(id) {
            collapsedShelves.remove(id)
        } else {
            collapsedShelves.insert(id)
        }
    }

    /// The rows the sidebar draws: every shelf whose parents are all open.
    var visibleShelfRows: [(shelf: Shelf, depth: Int, hasChildren: Bool)] {
        let tree = shelfTree
        var hidden: Set<UUID> = []
        return tree.inDrawnOrder().compactMap { row in
            if let parent = row.shelf.parentID, hidden.contains(parent) {
                hidden.insert(row.shelf.id)
                return nil
            }
            if collapsedShelves.contains(row.shelf.id) { hidden.insert(row.shelf.id) }
            return (row.shelf, row.depth, !tree.children(of: row.shelf.id).isEmpty)
        }
    }

    /// How many books stand on a shelf, counting the shelves inside it.
    ///
    /// Counted over the entries in memory rather than asked of the index. Every
    /// book already carries its shelves, so this is one pass over a few
    /// thousand values — measured well under a millisecond at 5 000 books — and
    /// it cannot lag behind an edit the way a cached count can. The sidebar's
    /// number is therefore right the moment a book is dropped on a shelf, which
    /// is the whole point of drawing it.
    func shelfCount(_ path: String) -> Int {
        entries.count { LibraryFilter.stands($0.book, on: path) }
    }

    func shelfCount(_ shelf: Shelf) -> Int {
        shelfTree.storedPath(of: shelf.id).map(shelfCount) ?? 0
    }

    /// Adds a shelf and answers its id, so the sidebar can put the new row
    /// straight into its rename field — the Finder's "untitled folder" gesture,
    /// and the reason there is no dialog to fill in first.
    ///
    /// `nil` when the name was refused; the reason is in `errorMessage`.
    @discardableResult
    func addShelf(named name: String, under parent: UUID? = nil) -> UUID? {
        switch ShelfEdit.add(name: name, under: parent, to: shelfTree) {
        case .failure(let why):
            errorMessage = why.message
            return nil
        case .success(let made):
            // A new shelf inside a folded one would be invisible, which reads
            // as "nothing happened".
            if let parent { collapsedShelves.remove(parent) }
            write(made.tree)
            errorMessage = nil
            return made.id
        }
    }

    /// "New Shelf", "New Shelf 2", … – the first name that is free among the
    /// shelf's sisters, so adding two in a row is not a refusal.
    func freeShelfName(under parent: UUID?) -> String {
        let base = "New Shelf"
        let tree = shelfTree
        if ShelfEdit.check(name: base, under: parent, in: tree) == nil { return base }
        for number in 2...99 where ShelfEdit.check(name: "\(base) \(number)", under: parent, in: tree) == nil {
            return "\(base) \(number)"
        }
        return base
    }

    /// Renames a shelf, and rewrites every book that stands on it or on one of
    /// its children.
    ///
    /// The books have to be rewritten because a stored path is only a name:
    /// nothing in `Fiction/Sci-Fi` says *which* shelf it is, so a rename that
    /// only changed `library.json` would leave every book pointing at a shelf
    /// that no longer exists — and the next rebuild would put them all back on
    /// the old one.
    func renameShelf(_ id: UUID, to name: String, undoManager: UndoManager?) {
        let before = shelfTree
        switch ShelfEdit.rename(id, to: name, in: before) {
        case .failure(let why):
            errorMessage = why.message
        case .success(let after):
            apply(before, after, moving: id, actionName: "Rename Shelf", undoManager: undoManager)
        }
    }

    func moveShelf(_ id: UUID, under parent: UUID?, undoManager: UndoManager?) {
        let before = shelfTree
        switch ShelfEdit.move(id, under: parent, in: before) {
        case .failure(let why):
            errorMessage = why.message
        case .success(let after):
            apply(before, after, moving: id, actionName: "Move Shelf", undoManager: undoManager)
        }
    }

    /// What a confirmation has to say before a shelf is removed: its name and
    /// how many books would come off it. **No book is deleted** — a shelf is a
    /// grouping, and removing one removes the grouping.
    func removalWarning(for id: UUID) -> (name: String, path: String, books: Int)? {
        let tree = shelfTree
        guard let shelf = tree.shelf(id), let path = tree.storedPath(of: id) else { return nil }
        return (shelf.name, path, shelfCount(path))
    }

    func removeShelf(_ id: UUID, undoManager: UndoManager?) {
        let before = shelfTree
        let after = ShelfEdit.remove(id, from: before)
        let affected = entries.filter { entry in
            ShelfEdit.pathsAfterRemoving(id, from: entry.book.shelves, in: before) != entry.book.shelves
        }
        let changes = affected.map { entry in
            (
                entry,
                MetadataChange.make(from: entry.book) {
                    $0.shelves = ShelfEdit.pathsAfterRemoving(id, from: $0.shelves, in: before)
                }
            )
        }
        commitShelfChange(
            tree: after, previousTree: before, changes: changes, actionName: "Delete Shelf",
            undoManager: undoManager)
    }

    /// A rename or a move: the tree changes, and every book whose path changed
    /// is rewritten with it.
    private func apply(
        _ before: ShelfTree, _ after: ShelfTree, moving id: UUID, actionName: String,
        undoManager: UndoManager?
    ) {
        let changes =
            entries
            .compactMap { entry -> (LibraryEntry, MetadataChange)? in
                let moved = ShelfEdit.pathsAfterMoving(
                    id, from: entry.book.shelves, before: before, after: after)
                guard moved != entry.book.shelves else { return nil }
                return (entry, MetadataChange.make(from: entry.book) { $0.shelves = moved })
            }
        commitShelfChange(
            tree: after, previousTree: before, changes: changes, actionName: actionName,
            undoManager: undoManager)
    }

    /// The tree and the books it moved, as one thing on the undo stack.
    ///
    /// One ⌘Z has to put both back. Undoing the tree without the books would
    /// leave the books on a shelf that is there again under a different name;
    /// undoing the books without the tree would leave them pointing at a shelf
    /// that is not.
    private func commitShelfChange(
        tree: ShelfTree, previousTree: ShelfTree, changes: [(LibraryEntry, MetadataChange)],
        actionName: String, undoManager: UndoManager?
    ) {
        undoManager?.beginUndoGrouping()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.write(previousTree) }
        }
        write(tree)
        for (entry, change) in changes {
            apply(change, to: entry, undoManager: undoManager)
        }
        undoManager?.setActionName(
            changes.count > 1 ? "\(actionName) (\(changes.count) books)" : actionName)
        undoManager?.endUndoGrouping()
        errorMessage = nil
    }

    /// `library.json` first, then the index — the same order as everything
    /// else, because the file is the truth and the index is a cache of it.
    private func write(_ tree: ShelfTree) {
        guard var descriptor, let library else { return }
        descriptor.shelves = tree.shelves
        do {
            try library.write(descriptor)
        } catch {
            show(error, doing: "save the shelves")
            return
        }
        self.descriptor = descriptor
        Task { [index] in
            try? await index?.saveShelves(tree.shelves)
        }
    }

    // MARK: Putting books on shelves

    /// Adds books to a shelf. One undo step for however many books it is.
    func addToShelf(_ shelfID: UUID, books: [LibraryEntry], undoManager: UndoManager?) {
        guard let path = shelfTree.storedPath(of: shelfID) else { return }
        edit(books, actionName: "Add to Shelf", undoManager: undoManager) { book in
            guard !book.shelves.contains(path) else { return }
            book.shelves = (book.shelves + [path]).sorted()
        }
    }

    func removeFromShelf(_ path: String, books: [LibraryEntry], undoManager: UndoManager?) {
        edit(books, actionName: "Remove from Shelf", undoManager: undoManager) { book in
            book.shelves.removeAll { $0 == path }
        }
    }

    /// One edit across any number of books, as one thing on the undo stack.
    ///
    /// The shape every multiple-selection action uses: build a change per book,
    /// skip the ones it changes nothing for, and wrap the lot in an undo group
    /// named for how many books it touched — "Add to Shelf (12 books)" says
    /// what ⌘Z is about to undo.
    func edit(
        _ books: [LibraryEntry], actionName: String, undoManager: UndoManager?,
        _ change: (inout Book) -> Void
    ) {
        let changes = books.compactMap { entry -> (LibraryEntry, MetadataChange)? in
            let made = MetadataChange.make(from: entry.book, change)
            return made.isEmpty ? nil : (entry, made)
        }
        guard !changes.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        for (entry, made) in changes { apply(made, to: entry, undoManager: undoManager) }
        undoManager?.setActionName(
            changes.count > 1 ? "\(actionName) (\(changes.count) books)" : actionName)
        undoManager?.endUndoGrouping()
    }

    /// Why this book is in *Duplicates*, in one line — or nothing when it is
    /// not. The best-founded rule when several matched: identical bytes is a
    /// fact and identical title-and-author is a guess, and the guess is the one
    /// somebody might act on by deleting a book.
    func duplicateReason(for id: UUID) -> DuplicateReason? {
        DuplicateReason.strongest(of: duplicateReasons[id] ?? [])
    }

    /// How many books the selected book's series holds – the "of 7" in
    /// "Book 3 of 7". Read off the sidebar's facets, which are already loaded.
    func seriesCount(named name: String) -> Int? {
        seriesFacets.first { $0.name == name }?.count
    }

    // MARK: Actions on the selection

    func revealSelectedInFinder() {
        guard let library, let entry = selectedEntry else { return }
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// Opens the book in whatever app the system uses for its format.
    ///
    /// Shelf is not a reader (CONCEPT §1), so this hands the file to Books,
    /// Preview or whatever the user prefers. The file is opened, never modified.
    func openSelectedInDefaultApp() {
        guard let library, let entry = selectedEntry, let format = entry.preferredFormat else { return }
        let url = library.root
            .appendingPathComponent(entry.folder, isDirectory: true)
            .appendingPathComponent(format.fileName)
        NSWorkspace.shared.open(url)
    }

    // MARK: The cover cache

    private(set) var coverCacheBytes: Int64 = 0

    func refreshCoverCacheSize() async {
        guard let loader else { return }
        coverCacheBytes = await loader.diskCacheBytes()
    }

    func clearCoverCache() async {
        guard let loader else { return }
        await loader.clearDiskCache()
        coversOnDisk = []
        coverCacheBytes = 0
        warmer.reset()
        await reload()
    }

    // MARK: Rebuilding

    /// Throws the index away and rebuilds it from the folders.
    ///
    /// Offered in the menu because it is the answer to every "the index and the
    /// folders disagree" – and it is safe to offer precisely because the folder
    /// is the truth (ADR 0001). It never writes or deletes a book file.
    func rebuildIndex() async {
        guard let library, let index else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let rebuilder = IndexRebuilder(makeHasher: SHA256Hasher.factory)
            // Reuse the digests of files that have not changed: hashing a whole
            // library again is minutes of disk for no new information.
            var known: [String: String] = [:]
            for entry in entries {
                for format in entry.formats {
                    known[
                        IndexRebuilder.digestKey(
                            folder: entry.folder, fileName: format.fileName, byteSize: format.byteSize,
                            modifiedAt: format.modifiedAt)] = format.sha256
                }
            }
            let result = try await Task.detached(priority: .userInitiated) {
                try rebuilder.rebuild(library, knownDigests: known)
            }.value

            try await index.eraseAll()
            // The tree first, and every path any book named made sure of.
            //
            // This is what makes a shelf survive a lost index (ADR 0008). The
            // shape comes from `library.json`; a path a book claims that the
            // file has lost — a backup restored without its `.shelf` folder, a
            // library copied by hand — is created rather than dropped, because
            // the book said where it stands and the folder is the truth. The
            // books are saved *after*, so the index has a shelf to file each
            // one under; the other order silently loses every membership.
            var tree = ShelfTree(descriptor?.shelves ?? [])
            for path in result.shelfPathsSeen.sorted() { _ = tree.ensure(path: path) }
            try await index.saveShelves(tree.shelves)
            // The columns' definitions travel with the tree and for the same
            // reason: `library.json` is the authority for both shapes, and the
            // index is a cache of them. Without this a rebuild leaves every column
            // named after its own label, because a book's OPF carries the values
            // and never the names — which is what a proof run found.
            try await index.saveCustomColumns(descriptor?.customColumns ?? [])
            try await index.save(result.entries)
            if var descriptor {
                descriptor.shelves = tree.shelves
                descriptor.nextBookNumber = max(descriptor.nextBookNumber, result.highestNumber + 1)
                try? library.write(descriptor)
                self.descriptor = descriptor
            }
            warmer.reset()
            await reload()

            if !result.unreadableFolders.isEmpty {
                errorMessage =
                    "\(result.unreadableFolders.count) folder(s) hold no readable book. "
                    + "Nothing was changed or removed – see \(ImportReport.fileName)."
            }
        } catch {
            show(error, doing: "rebuild the index")
        }
    }

    // MARK: Errors

    /// Says what happened and what to do, never only that something failed.
    private func show(_ error: any Error, doing what: String) {
        let detail: String
        switch error {
        case let failure as Library.Failure:
            detail = Self.describe(failure)
        case let failure as LibraryIndex.Failure:
            detail = Self.describe(failure)
        case let failure as ImportRunner.Failure:
            detail = Self.describe(failure)
        default:
            detail = (error as NSError).localizedDescription
        }
        errorMessage = "Could not \(what): \(detail)"
        Self.logger.error("\(self.errorMessage ?? "", privacy: .public)")
    }

    private static func describe(_ failure: Library.Failure) -> String {
        switch failure {
        case .notALibrary(let name):
            return "“\(name)” is not a Shelf library. Use New Library… to make one there."
        case .alreadyALibrary(let name):
            return "“\(name)” already holds a library. Open it instead."
        case .cannotCreate(let name):
            return "the folder “\(name)” could not be created. Is the disk writable?"
        case .cannotWriteDescriptor(let name):
            return "library.json in “\(name)” could not be written. Is the disk full or read-only?"
        case .newerSchema(let found, let supported):
            return "it was written by a newer Shelf (format \(found); this one reads \(supported)). "
                + "Update Shelf to open it."
        }
    }

    private static func describe(_ failure: LibraryIndex.Failure) -> String {
        switch failure {
        case .cannotOpen(let name, let reason):
            return "the index of “\(name)” could not be opened (\(reason)). "
                + "The books are safe – the index can be rebuilt from the folders."
        }
    }

    private static func describe(_ failure: ImportRunner.Failure) -> String {
        switch failure {
        case .notEnoughSpace(let needed, let available):
            return "there is not enough room: \(ByteCount.format(needed)) needed, "
                + "\(ByteCount.format(available)) free. Nothing was copied."
        case .cannotCreateFolder(let name):
            return "the folder for “\(name)” could not be created."
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissSyncWarning() {
        syncWarning = nil
    }

    // MARK: What the status bar says

    var statusLine: String {
        guard library != nil else { return "" }
        var parts: [String] = []
        if filter.isNarrowed || visible.count != entries.count {
            parts.append("\(grouped(visible.count)) of \(grouped(entries.count)) books")
        } else {
            parts.append("\(grouped(entries.count)) book\(entries.count == 1 ? "" : "s")")
        }
        if !authorFacets.isEmpty { parts.append("\(grouped(authorFacets.count)) authors") }
        if !seriesFacets.isEmpty { parts.append("\(grouped(seriesFacets.count)) series") }
        return parts.joined(separator: " · ")
    }

    /// The same grouping SwiftUI gives `Text("\(count)")`, which is what the
    /// sidebar's counts go through. Without it the accessibility tree showed
    /// "4.996" in the sidebar and "4996 books" in the status bar one line
    /// below – two number formats in one window.
    private func grouped(_ count: Int) -> String {
        count.formatted(.number)
    }
}
