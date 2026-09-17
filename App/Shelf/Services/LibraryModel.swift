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
    var sort: BookSort = .titleSort {
        didSet { if sort != oldValue { reloadEntries() } }
    }
    /// The books the grid shows: `entries` after the filter and the search.
    private(set) var visible: [LibraryEntry] = []
    var selectedBookID: UUID? {
        didSet { if selectedBookID != oldValue { selectionChanged() } }
    }

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
        warmer.reset()
    }

    // MARK: Reading the index

    /// Everything the window shows about a library, in one pass.
    func reload() async {
        guard let index else { return }
        do {
            entries = try await index.allEntries(sortedBy: sort)
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            tagFacets = try await index.tagFacets()
            authorFacets = try await index.authorFacets()
            seriesFacets = try await index.seriesFacets()
            formatFacets = try await index.formatFacets()
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
        let shelved = Set<UUID>()
        visible = entries.filter { entry in
            if let ids, !ids.contains(entry.id) { return false }
            return filter.matches(entry, coversOnDisk: coversOnDisk, shelvedBooks: shelved)
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

    func select(_ entry: LibraryEntry) {
        selectedBookID = entry.id
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
        guard let entry = selectedEntry else { return }
        let wanted = entry.book.stars == stars ? 0 : stars
        apply(MetadataChange.make(from: entry.book) { $0.stars = wanted }, to: entry, undoManager: undoManager)
    }

    /// The 0 key: unrated, whatever it was.
    func clearRating(undoManager: UndoManager?) {
        guard let entry = selectedEntry else { return }
        apply(MetadataChange.make(from: entry.book) { $0.stars = 0 }, to: entry, undoManager: undoManager)
    }

    /// R, and the checkbox in the inspector.
    func toggleRead(undoManager: UndoManager?) {
        guard let entry = selectedEntry else { return }
        apply(
            MetadataChange.make(from: entry.book) { $0.isRead.toggle() }, to: entry,
            undoManager: undoManager)
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
        guard let entry = selectedEntry else { return }
        handle(field.apply(typed, to: entry.book), key: field.rawValue, entry: entry, undoManager: undoManager)
    }

    func commitIdentifier(scheme: String, value: String, undoManager: UndoManager?) {
        guard let entry = selectedEntry else { return }
        handle(
            IdentifierEdit.set(scheme: scheme, value: value, in: entry.book),
            key: "identifier:\(scheme.lowercased())", entry: entry, undoManager: undoManager)
    }

    func addTag(_ name: String, undoManager: UndoManager?) {
        guard let entry = selectedEntry else { return }
        handle(
            TagEdit.add(name, to: entry.book, knownTags: knownTags), key: "tags", entry: entry,
            undoManager: undoManager)
        tagDraft = ""
    }

    func removeTag(_ name: String, undoManager: UndoManager?) {
        guard let entry = selectedEntry else { return }
        handle(TagEdit.remove(name, from: entry.book), key: "tags", entry: entry, undoManager: undoManager)
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
        TagEdit.completions(
            for: tagDraft, among: knownTags, excluding: selectedEntry?.book.tags ?? [])
    }

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
            try await index.save(result.entries)
            if var descriptor {
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
