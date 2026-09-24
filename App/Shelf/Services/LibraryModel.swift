import AppKit
import Dispatch
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
    /// Which books have a **cover file next to them**, which is what `Missing
    /// Cover` means.
    ///
    /// It used to be the books whose *decoded* cover was in the disk cache —
    /// one directory read, which is what made it cheap, and empty until
    /// something had been drawn. A freshly imported library therefore reported
    /// every book as missing a cover and corrected itself as the grid filled
    /// in. `CoverFile.booksWithACover` asks the folders instead.
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
    private(set) var publisherFacets: [LibraryIndex.Facet] = []
    private(set) var formatFacets: [LibraryIndex.Facet] = []
    /// Which books look like copies of another, and by which of the three
    /// rules. Asked of the index once per reload rather than per filter: it is
    /// three queries and a fold over every title, which is worth doing once for
    /// 5 000 books and not once per click.
    private(set) var duplicateReasons: [UUID: Set<DuplicateReason>] = [:]

    /// The same books, sorted into the two collections the sidebar shows:
    /// what is certainly a copy and what only looks like one
    /// (`DuplicateGroups`). Derived from `duplicateReasons` in one place so the
    /// counts and the filter cannot drift apart.
    private(set) var duplicateGroups = DuplicateGroups.none

    // MARK: Messages

    /// Shown as a banner over the content. Cleared by the next successful action.
    private(set) var errorMessage: String?
    /// The warning a library in a synced folder gets (CONCEPT §12).
    private(set) var syncWarning: String?

    // MARK: Import

    var isImportSheetPresented = false
    private(set) var importModel: ImportModel?
    /// True from the moment a quit is asked for, while an import is running,
    /// until its short last batch has actually flushed (or a person has
    /// skipped the wait) — what `ImportSheet` shows in place of the ordinary
    /// running progress. `AppDelegate.performTermination()` is the only
    /// writer (`docs/BACKLOG.md`, Sprint 13, Teil A found the wait itself can
    /// run up to about twenty seconds against a large in-flight backlog, and
    /// a silent one just invites an impatient Force Quit).
    var isWaitingToQuitForImport = false

    // MARK: Online metadata

    var isFetchMetadataSheetPresented = false
    /// Made when a library is opened, because it needs the library's root to
    /// put a fetched cover beside the right book.
    private(set) var onlineMetadata: OnlineMetadataModel?
    /// "Fill Missing Fields…" (Sprint 18, Teil C4). Shares `onlineMetadata`'s
    /// own `MetadataFetcher` rather than opening a second one, so both
    /// features' calls are paced against each other.
    private(set) var fillMissingFields: FillMissingFieldsModel?
    var isFillMissingFieldsSheetPresented = false

    // MARK: Orphaned folders

    /// `Library ▸ Find Orphaned Folders…`. The list is what the sheet shows and
    /// what a confirmation names; it is never acted on by itself.
    // MARK: Devices

    /// What is plugged in, what is on it, and how far a transfer has got.
    ///
    /// Its own model, like `ImportModel`: a device appearing has nothing to do
    /// with the library's state, and a transfer has to survive the sheet being
    /// closed. What this model adds is the joining — a transfer needs the
    /// library's entries and its root, and those are here.
    let devices = DeviceModel()
    var isDeviceContentsSheetPresented = false

    var isOrphanSheetPresented = false
    private(set) var orphanedFolders: [OrphanedFolder] = []
    private(set) var isScanningForOrphans = false

    // MARK: Services

    let recents = RecentLibrariesStore()
    /// `UpdaterModel.availableUpdateVersion`; `Shelf ▸ Check for Updates…`
    /// calls `updater.checkForUpdates()`.
    let updater = UpdaterModel()
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
        panel.prompt = Loc.string("Open Library")
        panel.message = Loc.string("Choose a Shelf library folder.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func presentNewLibraryPanel() {
        let panel = NSSavePanel()
        panel.prompt = Loc.string("Create Library")
        panel.message = Loc.string("Choose where the new library folder goes.")
        panel.nameFieldStringValue = Loc.string("My Library")
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
            show(error, doing: Loc.string("create a library at %@", url.lastPathComponent))
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
                Loc.string(
                    "“%@” is not a Shelf library. Use New Library… to make one there, or open a "
                        + "folder that already holds one.", url.lastPathComponent)
            return
        }
        Task { await load(url) }
    }

    func open(recent entry: RecentLibrary) {
        guard let url = recents.openable(entry) else {
            errorMessage = Loc.string("“%@” is not available right now. Is the disk connected?", entry.name)
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
            onlineMetadata = OnlineMetadataModel(libraryRoot: library.root)
            fillMissingFields = FillMissingFieldsModel(
                fetcher: onlineMetadata!.fetcher, libraryRoot: library.root)
            errorMessage = nil
            syncWarning = library.syncWarning
            warmer.reset()

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

            // A proof script needs to start a real import without driving the
            // Add Books panel through System Events — the same reason
            // `Scripts/smoke.sh` hands a library over on the command line
            // instead of typing into Open Recent. Silent unless
            // `SHELF_AUTO_IMPORT_SOURCE` names a folder (Sprint 13, Teil B/C).
            if let sourcePath = ProcessInfo.processInfo.environment["SHELF_AUTO_IMPORT_SOURCE"] {
                let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
                Task { await self.autoImportForProof(from: source) }
            }
        } catch {
            show(error, doing: Loc.string("open %@", url.lastPathComponent))
        }
    }

    /// Starts watching for devices. Called once, when the window appears: a
    /// reader plugged in before a library is open still belongs in the
    /// sidebar, and the section says so whether or not there is a library.
    func startWatchingDevices() {
        devices.start()
    }

    func stopWatchingDevices() {
        devices.stop()
    }

    // MARK: Sending books to a device

    /// The books the grid dragged onto a device.
    func sendToDevice(bookIDs: Set<UUID>, device: ConnectedDevice) {
        send(entries.filter { bookIDs.contains($0.id) }, to: device)
    }

    /// ⌘⇧S, and the device row's context menu.
    func sendSelectionToDevice(_ device: ConnectedDevice?) {
        guard let device = device ?? devices.selectedDevice else { return }
        send(selectedEntries, to: device)
    }

    private func send(_ books: [LibraryEntry], to device: ConnectedDevice) {
        guard let library, !books.isEmpty else { return }
        devices.selectedDeviceID = device.id
        Task { await devices.prepareTransfer(of: books, to: device, libraryRoot: library.root) }
    }

    /// Runs the transfer the sheet is showing.
    func runTransfer() {
        guard let device = devices.selectedDevice else { return }
        devices.runTransfer(to: device, entries: entries)
    }

    /// "Treat this volume as device…" — remembered for this session only.
    func treatVolumeAsDevice(_ volume: MountedVolume, as profileID: String) {
        devices.treat(volume, as: profileID, entries: entries)
    }

    /// The same, through an open panel — and the only route that works for a
    /// volume the sandbox has not already let Shelf into.
    ///
    /// **Why there is a panel at all.** The app sandbox grants
    /// `files.removable-volumes` for real removable media; it does **not** cover
    /// a mounted disk image, and it is not a promise about every volume a person
    /// might plug in. Measured in Sprint 5: with the entitlement in place, the
    /// app could read a disk image's *name and free space* and could not list
    /// its directory, so a Kobo made out of an image showed "0 books" with five
    /// on it. Choosing the volume in an open panel is what the sandbox takes as
    /// permission, and it is the same act the library folder already needs.
    ///
    /// It is therefore not only the way in when no marker matches. It is also
    /// the way in when the sandbox will not let Shelf look.
    func presentDeviceVolumePanel(as profileID: String) {
        guard let profile = DeviceProfiles.profile(id: profileID) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.prompt = Loc.string("Use as %@", profile.name)
        panel.message = Loc.string("Choose the volume to treat as a %@.", profile.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        devices.treat(DeviceWatcher.volume(at: url), as: profileID, entries: entries)
    }

    func showDeviceContents(_ device: ConnectedDevice?) {
        guard let device = device ?? devices.selectedDevice else { return }
        devices.selectedDeviceID = device.id
        isDeviceContentsSheetPresented = true
    }

    /// Opens the confirmation. Nothing is deleted until its own button is
    /// pressed (ADR 0014).
    func askToDeleteFromDevice(_ files: [DeviceFile], on device: ConnectedDevice) {
        isDeviceContentsSheetPresented = false
        devices.askToDelete(files, on: device, entries: entries)
    }

    func confirmDeleteFromDevice() {
        guard let device = devices.selectedDevice else { return }
        devices.confirmDelete(on: device, entries: entries)
    }

    /// Books that are on a connected device — the grid's badge.
    var booksOnDevice: Set<UUID> { devices.booksOnDevice }

    func closeLibrary() {
        library = nil
        descriptor = nil
        index = nil
        loader = nil
        importModel = nil
        onlineMetadata = nil
        entries = []
        visible = []
        selectedBookID = nil
        totals = LibraryIndex.Totals()
        tagFacets = []
        authorFacets = []
        seriesFacets = []
        publisherFacets = []
        formatFacets = []
        duplicateReasons = [:]
        duplicateGroups = .none
        warmer.reset()
    }

    // MARK: Reading the index

    /// Everything the window shows about a library, in one pass.
    func reload() async {
        guard let index else { return }
        do {
            entries = try await index.allEntries(sortedBy: order)
            // Before the totals and before the filter, because both of them
            // ask it. It was neither: the set came from the cover *cache* and
            // was refreshed at a different moment, so `Missing Cover` counted
            // one thing and showed another until the grid had been looked at.
            await refreshCoversOnDisk()
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            tagFacets = try await index.tagFacets()
            authorFacets = try await index.authorFacets()
            seriesFacets = try await index.seriesFacets()
            publisherFacets = try await index.publisherFacets()
            formatFacets = try await index.formatFacets()
            duplicateReasons = try await index.duplicates()
            duplicateGroups = DuplicateGroups(reasons: duplicateReasons)
            totals.duplicates = duplicateGroups.certain.count
            totals.possibleDuplicates = duplicateGroups.possible.count
            refilter()
            // Which books are on a device depends on the library's books, so
            // the match is made again whenever those change. It reads the
            // devices and never writes to them.
            await devices.refresh(entries: entries)
        } catch {
            show(error, doing: Loc.string("read the library index"))
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
        visible = entries.filter { entry in
            if let ids, !ids.contains(entry.id) { return false }
            return filter.matches(entry, coversOnDisk: coversOnDisk, duplicates: duplicateGroups)
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

    /// Walks the book folders and notes which have a cover file.
    ///
    /// Off the main actor, because it is one or two `stat` calls per book and a
    /// library can hold thousands. Called from `reload`, before the totals and
    /// the filter, which are the two things that read it.
    private func refreshCoversOnDisk() async {
        guard let root = library?.root else {
            coversOnDisk = []
            return
        }
        let books = entries
        coversOnDisk = await Task.detached(priority: .utility) {
            CoverFile.booksWithACover(in: root, entries: books)
        }.value
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
        panel.prompt = Loc.string("Choose")
        panel.message = Loc.string("Choose books or a folder of books to add.")
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        isImportSheetPresented = true
        Task { await importModel.examine(panel.urls) }
    }

    /// Adds another file to the book that is selected.
    ///
    /// The same operation as dragging a second file onto the window, and it
    /// goes through the same `ImportPlanner`: the planner recognises the book
    /// by its ISBN or its title and author and turns the file into an
    /// `.addFormat` into the folder that book already has (ADR 0002, decision
    /// 8). Nothing here writes over a file that is there — a file of the same
    /// name in the folder is refused by the runner, not overwritten.
    ///
    /// A *second copy of a format the book already has* is skipped as a
    /// duplicate, and the sheet says so before anything is copied. That is the
    /// planner's judgement and not this method's, which is the point of not
    /// having a second path for it.
    func presentAddFormatPanel() {
        guard let importModel, selectedEntry != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = Loc.string("Add")
        panel.message = Loc.string(
            "Choose another file for this book. It is copied in beside the ones that are there; "
                + "nothing is written over.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        isImportSheetPresented = true
        Task { await importModel.examine(panel.urls) }
    }

    /// Shows one of a book's files in the Finder – the file, not the folder.
    func revealInFinder(_ format: BookFormat, of entry: LibraryEntry) {
        guard let library else { return }
        let url = library.root
            .appendingPathComponent(entry.folder, isDirectory: true)
            .appendingPathComponent(format.fileName)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Hands one particular file to whatever reads it. Shelf is not a reader
    /// (CONCEPT §1); the file is opened and never modified.
    func open(_ format: BookFormat, of entry: LibraryEntry) {
        guard let library else { return }
        let url = library.root
            .appendingPathComponent(entry.folder, isDirectory: true)
            .appendingPathComponent(format.fileName)
        NSWorkspace.shared.open(url)
    }

    // MARK: Sending one format file to the Trash

    /// What went wrong the last time a format file was sent to the Trash or
    /// brought back, shown under the formats list in the inspector. Cleared
    /// by the next attempt, in either direction.
    private(set) var formatDisposalMessage: (text: String, detail: String?)?

    func clearFormatDisposalMessage() { formatDisposalMessage = nil }

    /// Sends one of a book's format files to the Trash, keeping the book.
    ///
    /// The core refuses on its own when this would take the book's last file
    /// (`FormatDisposal.Refusal.lastFormat`) — the context menu also disables
    /// itself in that case (`InspectorView`), so reaching the refusal here
    /// would mean the two disagreed, not that a person did something wrong.
    /// Unlike a cover, the file's bytes are never held in memory: `restore`
    /// works from the Trash path `FormatDisposal.remove` reports, hashed
    /// before it is trusted (ADR 0002), which is what makes this undoable at
    /// all for a file that can be tens of megabytes.
    func removeFormat(_ format: BookFormat, from entry: LibraryEntry, undoManager: UndoManager?) {
        guard let library else { return }
        formatDisposalMessage = nil
        do {
            let result = try FormatDisposal.remove(format, from: entry, library: library)
            registerFormatRemovalUndo(result, undoManager: undoManager)
            Task { await self.applyFormatRemoval(result, to: entry) }
        } catch let refusal as FormatDisposal.Refusal {
            formatDisposalMessage = (Loc.core(refusal.message), refusal.detail)
        } catch {
            formatDisposalMessage = (error.localizedDescription, nil)
        }
    }

    /// Puts the matching restoration on the opposite stack, named the same
    /// way every other undo in this file is: synchronously, before the write
    /// itself is dispatched (`registerCoverUndo` explains why the order
    /// matters for ⇧⌘Z).
    private func registerFormatRemovalUndo(_ result: FormatDisposal.Result, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.performFormatRestoration(result, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(Loc.string("Move to Trash"))
    }

    /// The write half of `removeFormat`: takes the format out of the index
    /// and out of what the window shows. The file itself is already gone —
    /// `FormatDisposal.remove` moved it synchronously — so registering the
    /// undo before this runs can never race a write that has not happened
    /// yet.
    private func applyFormatRemoval(_ result: FormatDisposal.Result, to entry: LibraryEntry) async {
        guard let index else { return }
        var updated = entry
        updated.formats.removeAll { $0.id == result.format.id }
        do {
            try await index.save(updated)
            replace(updated)
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            refilter()
        } catch {
            show(error, doing: Loc.string("update the index after moving “%@” to the Trash", result.format.fileName))
        }
    }

    /// What the registered undo calls: puts the file back at exactly its old
    /// path, verified by hash against the Trash copy, and puts a matching
    /// redo (removing it again) on the opposite stack.
    private func performFormatRestoration(_ result: FormatDisposal.Result, undoManager: UndoManager?) {
        guard let library else { return }
        formatDisposalMessage = nil
        do {
            try FormatDisposal.restore(result, library: library, makeHasher: PortableSHA256Hasher.factory)
        } catch let failure as FormatDisposal.RestoreFailure {
            formatDisposalMessage = (Loc.core(failure.message), failure.detail)
            return
        } catch {
            formatDisposalMessage = (error.localizedDescription, nil)
            return
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.performFormatRemoval(result, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(Loc.string("Move to Trash"))
        Task { await self.applyFormatRestoration(result) }
    }

    /// The redo half of `performFormatRestoration`: removes the file again,
    /// the same write `removeFormat` does, without re-showing the
    /// confirmation — a redo is not a fresh request.
    private func performFormatRemoval(_ result: FormatDisposal.Result, undoManager: UndoManager?) {
        guard let library, let entry = entries.first(where: { $0.id == result.format.bookID }) else { return }
        formatDisposalMessage = nil
        do {
            let redone = try FormatDisposal.remove(result.format, from: entry, library: library)
            registerFormatRemovalUndo(redone, undoManager: undoManager)
            Task { await self.applyFormatRemoval(redone, to: entry) }
        } catch let refusal as FormatDisposal.Refusal {
            formatDisposalMessage = (Loc.core(refusal.message), refusal.detail)
        } catch {
            formatDisposalMessage = (error.localizedDescription, nil)
        }
    }

    private func applyFormatRestoration(_ result: FormatDisposal.Result) async {
        guard let index, let entry = entries.first(where: { $0.id == result.format.bookID }) else { return }
        var updated = entry
        updated.formats.append(result.format)
        do {
            try await index.save(updated)
            replace(updated)
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            refilter()
        } catch {
            show(error, doing: Loc.string("update the index after bringing back “%@”", result.format.fileName))
        }
    }

    // MARK: Sending a whole book to the Trash

    /// The book a "Move Book to Trash…" was clicked on, while the
    /// confirmation naming it and its files is on screen. `nil` the rest of
    /// the time.
    var pendingBookRemoval: LibraryEntry?

    /// Sends a book's whole folder to the Trash and takes it out of the
    /// index — the deliberate, explicit command CLAUDE.md's own list of what
    /// may ever be removed names narrowly (a duplicate, a stray "My
    /// Clippings", …), never a routine part of looking at a book.
    /// `FormatDisposal.removeFormat` is the other half: it removes one file
    /// and refuses when it would be the book's last one; this removes the
    /// book entirely, on purpose, and never as a side effect of that refusal.
    func removeBook(_ entry: LibraryEntry, undoManager: UndoManager?) {
        guard let library else { return }
        errorMessage = nil
        do {
            let result = try BookDisposal.remove(entry, library: library)
            registerBookRemovalUndo(result, undoManager: undoManager)
            Task { await self.applyBookRemoval(result) }
        } catch let refusal as BookDisposal.Refusal {
            errorMessage = [Loc.core(refusal.message), refusal.detail].compactMap { $0 }.joined(separator: " ")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerBookRemovalUndo(_ result: BookDisposal.Result, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.performBookRestoration(result, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(Loc.string("Move Book to Trash"))
    }

    /// The write half of `removeBook`: takes the book out of the index and
    /// out of what the window shows. The folder itself is already gone —
    /// `BookDisposal.remove` moved it synchronously — so registering the
    /// undo before this runs can never race a write that has not happened
    /// yet.
    private func applyBookRemoval(_ result: BookDisposal.Result) async {
        guard let index else { return }
        do {
            try await index.delete(id: result.entry.id)
            removeEntry(id: result.entry.id)
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            refilter()
        } catch {
            show(error, doing: Loc.string("update the index after moving “%@” to the Trash", result.entry.book.title))
        }
    }

    /// What the registered undo calls: puts the folder back, every file
    /// verified by hash against the Trash copy, and puts a matching redo
    /// (removing it again) on the opposite stack.
    private func performBookRestoration(_ result: BookDisposal.Result, undoManager: UndoManager?) {
        guard let library else { return }
        errorMessage = nil
        do {
            try BookDisposal.restore(result, library: library, makeHasher: PortableSHA256Hasher.factory)
        } catch let failure as BookDisposal.RestoreFailure {
            errorMessage = [Loc.core(failure.message), failure.detail].compactMap { $0 }.joined(separator: " ")
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.performBookRemoval(result, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(Loc.string("Move Book to Trash"))
        Task { await self.applyBookRestoration(result) }
    }

    /// The redo half of `performBookRestoration`: removes the book again,
    /// without re-showing the confirmation — a redo is not a fresh request.
    private func performBookRemoval(_ result: BookDisposal.Result, undoManager: UndoManager?) {
        guard let library else { return }
        errorMessage = nil
        do {
            let redone = try BookDisposal.remove(result.entry, library: library)
            registerBookRemovalUndo(redone, undoManager: undoManager)
            Task { await self.applyBookRemoval(redone) }
        } catch let refusal as BookDisposal.Refusal {
            errorMessage = [Loc.core(refusal.message), refusal.detail].compactMap { $0 }.joined(separator: " ")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyBookRestoration(_ result: BookDisposal.Result) async {
        guard let index else { return }
        do {
            try await index.save(result.entry)
            entries.append(result.entry)
            totals = try await index.totals(coversOnDisk: coversOnDisk)
            refilter()
        } catch {
            show(
                error,
                doing: Loc.string("update the index after bringing back “%@”", result.entry.book.title))
        }
    }

    /// Takes one entry out of both arrays the window reads from. The
    /// opposite of `replace(_:)`, which every write until now only ever
    /// needed the "still here, different values" half of.
    private func removeEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        visible.removeAll { $0.id == id }
        selection.remove(id)
    }

    // MARK: Merging books

    enum MergePhase: Equatable {
        case planning
        /// The preview. Nothing has moved.
        case ready(BookMergePlan)
        case running(BookMergeRunner.Progress)
        case done(groupCount: Int, bookCount: Int)
    }

    var mergePhase: MergePhase?
    /// Whether there is a manifest to undo, so a sheet can offer it.
    private(set) var canUndoMerge = false

    /// Opens the preview for an explicit multi-selection — "Merge Books…".
    /// The lowest book number survives, the same default the bulk command
    /// uses; nothing here yet lets a person choose a different one on
    /// purpose (`docs/BACKLOG.md`).
    func beginMerge(_ selected: [LibraryEntry]) {
        guard selected.count > 1 else { return }
        mergePhase = .planning
        Task { await planMerge(groups: [MergeGroup(bookIDs: selected.map(\.id))]) }
    }

    /// Opens the preview for every group B3's own rule finds safe across the
    /// *whole* library — "Merge All Safe Groups…", offered from the
    /// Duplicates collection.
    func beginMergeAllSafeGroups() {
        mergePhase = .planning
        Task {
            guard let index else {
                mergePhase = nil
                return
            }
            do {
                let allEntries = try await index.allEntries()
                await planMerge(groups: MergeCandidates.certainGroups(among: allEntries))
            } catch {
                mergePhase = nil
                show(error, doing: Loc.string("look for books that are safe to merge"))
            }
        }
    }

    private func planMerge(groups: [MergeGroup]) async {
        guard let library, let index else { return }
        do {
            let allEntries = try await index.allEntries()
            let entriesByID = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
            let plan = await Task.detached(priority: .userInitiated) {
                BookMergePlanner.plan(
                    groups: groups, entries: entriesByID, library: library,
                    quality: { url, format in MergeQuality.probe(url: url, format: format) },
                    hasCover: { folder in CoverFile.url(in: folder) != nil })
            }.value
            canUndoMerge = !BookMergeManifest.read(in: library).isEmpty
            mergePhase = .ready(plan)
        } catch {
            mergePhase = nil
            show(error, doing: Loc.string("work out which books can be merged"))
        }
    }

    /// Carries out the preview exactly as shown (ADR 0018) and writes the
    /// survivors' metadata through `MetadataEditor`, the mechanism already
    /// trusted to merge a change onto whatever is currently in the OPF.
    func runMerge(_ plan: BookMergePlan) {
        guard let library, let index else { return }
        mergePhase = .running(BookMergeRunner.Progress(done: 0, total: plan.groups.count, currentTitle: ""))
        let manifest = BookMergeManifest.read(in: library)
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        Task {
            do {
                let onProgress: @Sendable (BookMergeRunner.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in self?.mergePhase = .running(progress) }
                }
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await BookMergeRunner(makeHasher: SHA256Hasher.factory)
                        .run(
                            .init(library: library, plan: plan, entries: entriesByID, manifest: manifest),
                            progress: onProgress)
                }.value

                try await applyMergeOutcome(outcome.groups, plan: plan, entriesByID: entriesByID, in: index)
                canUndoMerge = !outcome.manifest.isEmpty
                let bookCount = outcome.groups.reduce(0) { $0 + 1 + $1.absorbedIDs.count }
                mergePhase = .done(groupCount: outcome.groups.count, bookCount: bookCount)
                await reload()
            } catch {
                mergePhase = nil
                show(error, doing: Loc.string("merge the books"))
            }
        }
    }

    /// Writes every survivor's merged metadata and complete format list, and
    /// removes every absorbed book from the index — folder first, index
    /// second, as everywhere else (ADR 0001). The runner itself never
    /// touched either.
    private func applyMergeOutcome(
        _ groupOutcomes: [BookMergeRunner.GroupOutcome], plan: BookMergePlan,
        entriesByID: [UUID: LibraryEntry], in index: LibraryIndex
    ) async throws {
        guard let library else { return }
        let editor = MetadataEditor(library: library)
        for groupOutcome in groupOutcomes {
            guard let groupPlan = plan.groups.first(where: { $0.survivingID == groupOutcome.survivingID }),
                let survivorBefore = entriesByID[groupOutcome.survivingID]
            else { continue }
            let absorbedBooks = groupPlan.absorbedIDs.compactMap { entriesByID[$0] }.map { ($0.id, $0.book) }
            let merged = BookMetadataMerge.merge(surviving: survivorBefore.book, absorbed: absorbedBooks)

            var updated = survivorBefore
            updated.formats = groupOutcome.newFormats
            let change = MetadataChange.make(from: survivorBefore.book) { $0 = merged.book }
            try await editor.apply(change, to: updated, in: index)

            for absorbedID in groupOutcome.absorbedIDs {
                try await index.delete(id: absorbedID)
            }
        }
    }

    /// Puts every merged group back: every absorbed book's folder and index
    /// entry, every moved or discarded file, the survivor's own prior
    /// metadata and format list.
    func undoMerge() {
        guard let library, let index else { return }
        mergePhase = .running(BookMergeRunner.Progress(done: 0, total: 0, currentTitle: ""))
        let manifest = BookMergeManifest.read(in: library)
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await BookMergeRunner(makeHasher: SHA256Hasher.factory).undo(manifest, in: library)
                }.value
                for undone in outcome.undone {
                    try await index.save(undone.priorSurvivorEntry)
                    for restored in undone.restoredEntries {
                        try await index.save(restored)
                    }
                }
                canUndoMerge = !outcome.manifest.isEmpty
                mergePhase = nil
                await reload()
            } catch {
                mergePhase = nil
                show(error, doing: Loc.string("bring the merged books back"))
            }
        }
    }

    // MARK: An author's own sort form

    /// What an author's row currently says its sort form is, for an editor
    /// to show as a starting point. Falls back to the derived rule when
    /// nobody has corrected this name yet.
    func authorSort(for name: String) async -> String {
        guard let index else { return AuthorSort.of(name) }
        return (try? await index.authorSort(for: name)) ?? AuthorSort.of(name)
    }

    /// A person's own correction of how an author's name sorts —
    /// `AuthorSort.of` gets a Dutch *van*, a Spanish double surname wrong,
    /// and until this existed there was no way to say so (`docs/BACKLOG.md`).
    ///
    /// Written to `library.json` first — the index is a cache and a rebuild
    /// would otherwise drop the correction silently (ADR 0001) — then to the
    /// live index, so the sidebar and the table sort by it at once, without
    /// waiting for a rebuild nobody asked for.
    func setAuthorSort(_ sortForm: String, for name: String) {
        guard let library, var descriptor else { return }
        let trimmed = sortForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        descriptor.authorSortOverrides[name] = trimmed
        do {
            try library.write(descriptor)
        } catch {
            show(error, doing: Loc.string("save the sort name for “%@”", name))
            return
        }
        self.descriptor = descriptor
        Task {
            guard let index else { return }
            do {
                try await index.applyAuthorSortOverrides([name: trimmed])
                await reload()
            } catch {
                show(error, doing: Loc.string("apply the sort name for “%@”", name))
            }
        }
    }

    /// Choose a Calibre library, count it, and show the counting protocol.
    ///
    /// The folder with `metadata.db` in it, which is what Calibre calls the
    /// library. **Only ever read** — and the database only through a copy
    /// (ADR 0009). Nothing is written anywhere until Import is pressed.
    func presentCalibrePanel() {
        guard let importModel else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = Loc.string("Choose")
        panel.message = Loc.string(
            "Choose your Calibre library – the folder that holds metadata.db. Shelf only reads it.")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        isImportSheetPresented = true
        Task { await importModel.examineCalibre(folder) }
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
        // **Re-read, do not write back what was cached.** The counter moved on
        // and has to be stored, but an import can put things in `library.json`
        // that this window's copy predates: a Calibre import writes the custom
        // columns' definitions there before it copies a single file. Writing
        // the cached copy back erased them — the import worked, the values were
        // in every book's OPF, and the inspector showed nothing because the
        // library no longer knew what the columns were called.
        if var stored = try? library.readDescriptor() {
            stored.nextBookNumber = max(stored.nextBookNumber, importModel.nextBookNumber)
            try? library.write(stored)
            self.descriptor = stored
        }
        _ = index
        // `runImport()` runs inside `importRunTask`, which a Cancel click or a
        // quit may have just cancelled (`cancelImportRun()`). GRDB's async
        // reads cooperatively check `Task.isCancelled` and throw
        // `CancellationError` before touching the database — the same check
        // Sprint 13, Teil C's Bug 3 found silently losing a write
        // (`CHANGELOG.md`). Reloading in that same cancelled task turned a
        // perfectly good index read into a false "Could not read the library
        // index" banner right after a person's own Cancel or Quit
        // (`docs/BACKLOG.md`) — the data were never at risk, only the message
        // was wrong. A detached task starts uncancelled regardless of what
        // cancelled the caller, so a *real* read failure (a locked or corrupt
        // index) still surfaces; only the false one from cancellation does not.
        await Task.detached { [weak self] in
            await self?.reload()
        }.value
    }

    // MARK: Stopping a running import cleanly

    /// The `Task` running `runImport()`, while it is going — `nil` whenever
    /// nothing is copying. Tracked here, rather than left as the bare
    /// `Task { await model.runImport() }` at the call site it was until
    /// Sprint 13, so both the sheet's own Cancel button and the app's
    /// termination handling (`AppDelegate.applicationShouldTerminate`) have a
    /// real `Task` to cancel — before, `ImportModel.cancel()` cancelled a
    /// `task` property nothing had ever assigned, silently.
    @ObservationIgnored private var importRunTask: Task<Void, Never>?

    /// Whether an import is between "Import" and "Done" — the only phase
    /// worth waiting for before the app quits. `.examining` has written
    /// nothing to disk yet; `.idle`, `.ready` and `.finished` have nothing
    /// left to lose either.
    var isImportRunning: Bool { importRunTask != nil }

    /// `ImportModel.copyFinishedSemaphore`, reached through here because
    /// `AppDelegate` only ever holds a `LibraryModel`. See that property's
    /// own comment for why a plain `Task` wait cannot stand in for this.
    var importCopyFinishedSemaphore: DispatchSemaphore? { importModel?.copyFinishedSemaphore }

    /// Starts the sheet's confirmed plan in its own tracked `Task`.
    func beginImportRun() {
        guard importRunTask == nil else { return }
        importRunTask = Task { [weak self] in
            await self?.runImport()
            self?.importRunTask = nil
        }
    }

    /// Cancels a running import the tidy way. `ImportRunner` already writes
    /// its short last batch on a cooperative cancellation
    /// (`ImportRunner.swift`'s own `saveBatch` doc comment), so everything
    /// already copied and verified stays exactly as safe as it was; only the
    /// one file being copied when this is called is not finished.
    func cancelImportRun() {
        importRunTask?.cancel()
    }

    /// Resumed by whichever of two triggers reaches it first: the run
    /// finishing on its own, or `forceQuitNow()`. `nil` whenever nothing is
    /// being waited for. Resuming a `CheckedContinuation` twice is a crash,
    /// and these two triggers genuinely race — both are only ever called on
    /// the main actor, so setting this to `nil` right after the first
    /// `resume()` is enough; no lock is needed.
    @ObservationIgnored private var quitWaitContinuation: CheckedContinuation<Void, Never>?

    /// Waits for a run in flight to actually stop — cancelled or finished on
    /// its own — or for `forceQuitNow()` to be called, whichever comes
    /// first. Returns at once when nothing is running — safe to call
    /// unconditionally.
    ///
    /// The race is the point: `importRunTask?.value` alone can take the
    /// worst case Sprint 13, Teil A measured (up to about twenty seconds
    /// against a large in-flight backlog), and a person watching a stuck
    /// quit should not have to reach for Force Quit to get past it.
    func waitForImportRunToFinishOrForceQuit() async {
        guard let task = importRunTask else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            quitWaitContinuation = continuation
            Task { @MainActor [weak self] in
                await task.value
                self?.resumeQuitWaitIfNeeded()
            }
        }
    }

    /// The escape hatch: whatever is still copying is abandoned exactly as a
    /// hard kill would abandon it — bounded at
    /// `ImportRunner.indexBatchSize - 1` books, found afterwards by `Find
    /// Orphaned Folders…` — a person's own choice instead of an impatient
    /// Force Quit that would leave the very same thing behind anyway.
    func forceQuitNow() {
        resumeQuitWaitIfNeeded()
    }

    private func resumeQuitWaitIfNeeded() {
        quitWaitContinuation?.resume()
        quitWaitContinuation = nil
    }

    /// Test-only automation hook, the same shape as `SHELF_TIMING` and
    /// `SMOKE_LIBRARY`: a proof script needs to start a real import in the
    /// running app without driving the Add Books panel through System
    /// Events. Silent unless `SHELF_AUTO_IMPORT_SOURCE` named a folder.
    private func autoImportForProof(from source: URL) async {
        guard let importModel else { return }
        isImportSheetPresented = true
        await importModel.examine([source])
        guard case .ready = importModel.phase else { return }
        beginImportRun()
    }

    // MARK: Online metadata

    /// ⌘E. Asks both services about the selected books, one at a time.
    ///
    /// A multiple selection walks through the books in order with a decision
    /// for each — there is no automatic bulk match in v1.0, and a "do them all"
    /// button would be one (CONCEPT §9).
    func presentFetchMetadata() {
        guard library != nil, !selectedEntries.isEmpty else { return }
        onlineMetadata?.start(with: selectedEntries)
        isFetchMetadataSheetPresented = true
    }

    /// Takes over the ticked fields, as one step on the undo stack.
    ///
    /// Through the very same `apply` an inspector edit goes through: undo
    /// registered from the *old* book before anything is written, then
    /// `metadata.opf`, then the index. Nothing about a value having come from
    /// the net changes that path — which is why a fetched title can be undone
    /// with ⌘Z like a typed one.
    func applyFetchedMetadata(undoManager: UndoManager?) {
        guard let online = onlineMetadata, let entry = online.currentBook else { return }
        let chosen = online.chosenProposals
        guard !chosen.isEmpty else { return }

        let applied = MetadataMerge.apply(chosen, to: entry.book)
        if let refusal = applied.refused.first {
            // One refused value does not cost the others: the rest is applied
            // and the refusal is said out loud.
            fieldRejection = FieldRejection(key: "online", message: Loc.message(for: refusal.why))
        }
        let change = MetadataChange.make(from: entry.book) { $0 = applied.book }
        apply(change, to: entry, undoManager: undoManager)
    }

    /// The name ⌘Z will show afterwards, and the sheet's own button label.
    func fetchedMetadataSummary() -> String? {
        guard let online = onlineMetadata else { return nil }
        let count = online.chosenProposals.count
        guard count > 0 else { return nil }
        return Loc.count("%lld fields", count)
    }

    // MARK: Fill missing fields (Sprint 18, Teil C4)

    /// Opens the batch preview across every book in the library — not only
    /// the selection, since the whole point is to answer "what is still
    /// missing" for the collection, not for whatever happens to be selected.
    /// Nothing is asked or written until this is confirmed (ADR 0018), and
    /// the network questions run only once the sheet's own button starts them.
    func presentFillMissingFields() {
        guard library != nil else { return }
        isFillMissingFieldsSheetPresented = true
    }

    func beginFillMissingFieldsSearch() {
        fillMissingFields?.begin(over: entries)
    }

    /// Writes every book's plan and fetches every gap's cover, as **one**
    /// undo step — the same discipline `Standardize Fields…` and `Similar
    /// Spellings…` already keep: the value shown is the value written, and
    /// undoing the whole run is one ⌘Z regardless of how many books or
    /// covers it touched.
    func applyFillMissingFields(_ result: FillMissingFields.Result, undoManager: UndoManager?) async {
        guard let fillMissingFields else { return }
        let gaps = fillMissingFields.coverGaps(among: entries)
        let covers = await fillMissingFields.fetchCovers(for: gaps)

        guard !result.plans.isEmpty || !covers.isEmpty else {
            fillMissingFields.markDone(booksFilled: 0, coversFilled: 0)
            return
        }
        undoManager?.beginUndoGrouping()
        for plan in result.plans { apply(plan.change, to: plan.entry, undoManager: undoManager) }
        for cover in covers {
            let current = entries.first { $0.id == cover.entry.id } ?? cover.entry
            await applyCover(cover.data, to: current, undoManager: undoManager)
        }
        undoManager?.setActionName(Loc.string("Fill Missing Fields"))
        undoManager?.endUndoGrouping()
        fillMissingFields.markDone(booksFilled: result.plans.count, coversFilled: covers.count)
    }

    /// Downloads the cover the sheet is showing and puts it beside the book.
    ///
    /// Down the same path as `Set Cover…` and the drop target since Sprint 9:
    /// the online model downloads and this writes, so a cover from the net
    /// goes to the Trash-and-generation chain like any other and is undone
    /// with ⌘Z like any other. Before that it wrote the file itself and could
    /// only ever write into an empty folder, which meant a cover fetched once
    /// could never be corrected.
    func fetchCoverFromTheNet(undoManager: UndoManager?) async {
        guard let online = onlineMetadata, let entry = online.currentBook,
            let data = await online.fetchCoverData()
        else { return }
        switch CoverImage.prepare(data) {
        case .success(let prepared):
            let current = entries.first { $0.id == entry.id } ?? entry
            await applyCover(prepared, to: current, undoManager: undoManager)
            online.coverWasWritten(as: CoverFile.name(for: prepared))
        case .failure(let refusal):
            coverRefusal = refusal
        }
    }

    /// Bumped when a cover has changed under a book, so the views that hold a
    /// decoded image redraw. A counter for the same reason `focusRequest` is
    /// one: two fetches in a row are two events.
    private(set) var coverRefreshRequest = 0

    // MARK: Changing a cover

    /// What went wrong the last time somebody tried to set a cover, shown
    /// under the picture in the inspector. Cleared by the next attempt.
    private(set) var coverRefusal: CoverReplacement.Refusal?

    func clearCoverRefusal() { coverRefusal = nil }

    /// A picture that arrived as bytes rather than as a file: dragged out of a
    /// web page, or out of Preview.
    func setCover(of entry: LibraryEntry, fromImageData data: Data, undoManager: UndoManager?) async {
        switch CoverImage.prepare(data) {
        case .success(let prepared): await applyCover(prepared, to: entry, undoManager: undoManager)
        case .failure(let refusal): coverRefusal = refusal
        }
    }

    /// `Set Cover…`, and an image dropped on the inspector.
    ///
    /// The picture is prepared before anything on disk moves: a 6 000 px
    /// photograph is brought down to `CoverImageRule.maxEdgePixels`, a HEIC or
    /// a TIFF is written again as JPEG because a book folder cannot name
    /// either, and a cover that is already the right size and the right format
    /// comes through byte for byte.
    func setCover(of entry: LibraryEntry, fromFileAt url: URL, undoManager: UndoManager?) async {
        // The open panel hands back a URL the sandbox has opened for us; a URL
        // dropped on the window has to be asked for. Harmless for the first
        // case, which simply answers false.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch CoverImage.prepare(contentsOf: url) {
        case .success(let data): await applyCover(data, to: entry, undoManager: undoManager)
        case .failure(let refusal): coverRefusal = refusal
        }
    }

    /// `Take Cover from Book File` — pull the picture out of the book again.
    ///
    /// Useful twice: when an earlier import took the cover from the wrong one
    /// of a book's formats, and when somebody wants back what the file itself
    /// carries after trying something else.
    ///
    /// The format is chosen, not guessed: a book with an EPUB and a PDF has two
    /// different pictures inside it, so the caller says which. Reading goes
    /// through `FileReader`, the same dispatch the importer uses, so a PDF is
    /// page 1 rendered and a CBZ is its first image without a second code path
    /// that could disagree with the first.
    func takeCoverFromBookFile(
        of entry: LibraryEntry, format: BookFormat, undoManager: UndoManager?
    ) async {
        guard let library else { return }
        let url = library.root
            .appendingPathComponent(entry.folder, isDirectory: true)
            .appendingPathComponent(format.fileName)
        let bookFormat = format.format
        // Off the main actor: a 400 MB PDF rendered on the window's thread is a
        // beach ball, and reading a book file is exactly what `ImportModel`
        // does in a detached task for the same reason.
        let read = await Task.detached(priority: .userInitiated) {
            FileReader.read(url: url, format: bookFormat)
        }.value
        guard let cover = read.cover, !cover.isEmpty else {
            coverRefusal = .notAnImage
            return
        }
        switch CoverImage.prepare(cover) {
        case .success(let data): await applyCover(data, to: entry, undoManager: undoManager)
        case .failure(let refusal): coverRefusal = refusal
        }
    }

    /// The one path every direct cover action goes down — `Set Cover…`, a
    /// drop, `Take Cover from Book File`, a download. Awaited by its caller,
    /// so e.g. `fetchCoverFromTheNet`'s "Saved as…" note is not shown before
    /// the file has actually landed.
    ///
    /// Registers the undo synchronously, then awaits the write. See
    /// `performCoverUndo` for why the synchronous half is the whole of what
    /// makes ⇧⌘Z work at all.
    func applyCover(_ bytes: Data?, to entry: LibraryEntry, undoManager: UndoManager?) async {
        guard let library else { return }
        coverRefusal = nil
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
        guard case .proceed(let previous) = prepareCoverChange(bytes, in: folder) else { return }
        registerCoverUndo(previous: previous, entry: entry, undoManager: undoManager)
        await commitCoverChange(bytes, to: entry)
    }

    /// What a cover action has to decide before either write: whether there is
    /// anything to do, and what to keep in case it has to be undone.
    private enum CoverChangePreparation {
        /// The picture is already what is on disk, or the bytes are refused
        /// outright. `coverRefusal` is already set for the second case.
        case nothingToDo
        case proceed(previous: Data?)
    }

    /// Reads the current cover synchronously — one small file, off the fast
    /// path for every other edit — and refuses before anything moves. Shared
    /// by the awaited entry point and the one `registerUndo` calls, so the
    /// two agree about what counts as a change.
    private func prepareCoverChange(_ bytes: Data?, in folder: URL) -> CoverChangePreparation {
        let previous = CoverFile.url(in: folder).flatMap { try? Data(contentsOf: $0) }
        // Nothing to do, and nothing to put on the undo stack: choosing the
        // picture that is already there is not a change.
        guard previous != bytes else { return .nothingToDo }
        // Before either write, so a dropped text file never moves a generation.
        if let bytes, !CoverReplacement.accepts(bytes) {
            coverRefusal = .notAnImage
            return .nothingToDo
        }
        return .proceed(previous: previous)
    }

    /// What `registerUndo` calls, for both undo and redo. **Synchronous, and
    /// has to be.** The closure AppKit hands an undo/redo action cannot
    /// `await`, and only a `registerUndo` call made *while still inside* the
    /// current undo/redo invocation lands on the opposite stack — one made
    /// after a `Task` has let the run loop turn always goes back onto the
    /// undo stack, however it got there.
    ///
    /// That — and nothing about the write itself — is why ⇧⌘Z never worked
    /// before this: the previous shape wrapped this whole call in
    /// `Task { await model.applyCover(...) }`, which returns before
    /// `registerUndo` inside it ever runs, by which time `isUndoing` has
    /// already gone back to false. Every earlier redo landed on the undo
    /// stack instead — pressing ⌘Z a second time replayed the change forward
    /// again rather than doing nothing or a real redo. Confirmed by driving
    /// the real window before this fix: the Edit menu read a disabled
    /// "Redo", and a second ⌘Z moved the picture forward instead of leaving
    /// it alone.
    ///
    /// So this registers first, synchronously, exactly where `apply(_
    /// change:)` does for every other field, and only *then* fires the write
    /// in a `Task` without waiting for it.
    private func performCoverUndo(_ bytes: Data?, to entry: LibraryEntry, undoManager: UndoManager?) {
        guard let library else { return }
        coverRefusal = nil
        let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
        guard case .proceed(let previous) = prepareCoverChange(bytes, in: folder) else { return }
        registerCoverUndo(previous: previous, entry: entry, undoManager: undoManager)
        Task { await self.commitCoverChange(bytes, to: entry) }
    }

    /// Puts the inverse on the window's undo stack and names it in the Edit
    /// menu. Shared by `applyCover` and `performCoverUndo`, which is what
    /// keeps forwards and backwards agreeing about what the previous picture
    /// was.
    ///
    /// The previous value is the picture itself, held in memory on the undo
    /// stack. That is a few hundred kilobytes per step — a cover is capped at
    /// `CoverImageRule.maxEdgePixels` before it ever gets here — and it is the
    /// only way an undo can restore a file that has gone to the Trash without
    /// going and digging in the Trash for it. `nil` means "no cover", which is
    /// what undoing the *first* cover on a book has to restore. Anything else
    /// would leave the folder saying one thing and the book saying another.
    private func registerCoverUndo(previous: Data?, entry: LibraryEntry, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { model in
            // `UndoManager` calls this on the thread that registered it, which
            // is the main thread; nothing here hops queues.
            MainActor.assumeIsolated {
                // The entry as it is *now*, not as it was captured: its
                // generation has moved, and handing back the stale one would
                // write the same number twice and leave the grid on a
                // thumbnail of the picture being undone.
                let current = model.entries.first { $0.id == entry.id } ?? entry
                model.performCoverUndo(previous, to: current, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(Loc.core(MetadataChange.Field.cover.label))
    }

    /// The actual writes, through `CoverReplacement.commit`: the generation
    /// first, then the picture, with the generation put back if the picture
    /// write fails. Shared by the awaited path (`applyCover`) and the
    /// fire-and-forget one (`performCoverUndo`'s `Task`).
    ///
    /// Was inline here until this had a name of its own in the core: the
    /// generation moving and staying moved when the picture write failed was
    /// a small, permanent lie in `metadata.opf` — a replacement the OPF
    /// claimed had happened and the folder said had not. Moved to
    /// `CoverReplacement.commit` both to fix that and because `LibraryModel`
    /// has no test target of its own (`docs/BACKLOG.md`): the fix could not
    /// otherwise be proven, only asserted.
    private func commitCoverChange(_ bytes: Data?, to entry: LibraryEntry) async {
        guard let library, let index else { return }
        let startedAt = ContinuousClock.now
        do {
            switch try await CoverReplacement.commit(bytes, to: entry, library: library, index: index) {
            case .wrote(let updated):
                TimingLog.shared.metadataWritten(MetadataChange.Field.cover.label, since: startedAt)
                replace(updated)
                errorMessage = nil
            case .refused(let refusal):
                coverRefusal = refusal
                return
            }
        } catch {
            show(error, doing: Loc.string("save the change to “%@”", entry.book.title))
            return
        }

        if bytes == nil {
            coversOnDisk.remove(entry.id)
        } else {
            coversOnDisk.insert(entry.id)
        }
        await loader?.forget(entry.id)
        coverRefreshRequest += 1
        totals = (try? await index.totals(coversOnDisk: coversOnDisk)) ?? totals
    }

    /// What the stored answers take up, for the menu item that names it.
    private(set) var onlineCacheBytes: Int64 = 0

    func refreshOnlineCacheSize() async {
        onlineCacheBytes = await OnlineMetadataModel.cacheSize()
    }

    func clearOnlineCache() async {
        await OnlineMetadataModel.clearCache()
        await refreshOnlineCacheSize()
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
        // `Loc.core`, not the bare name: `MetadataChange.actionName` is one of
        // the core's English words and the Edit menu draws whatever it is
        // given. A German window offered "Widerrufen Title".
        undoManager?.setActionName(Loc.core(change.actionName))

        Task { await write(change, to: entry, startedAt: startedAt) }
    }

    /// Writes a metadata change: the file, then the index, then everything the
    /// window shows that could depend on it.
    ///
    /// The cover no longer goes through here (Sprint 9). It writes a second
    /// file besides `metadata.opf`, and a failure partway through that pair
    /// needs its own unwinding — `CoverReplacement.commit` does that in the
    /// core, where it can be tested, and `commitCoverChange` calls it
    /// directly instead.
    private func write(
        _ change: MetadataChange, to entry: LibraryEntry, startedAt: ContinuousClock.Instant
    ) async {
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
            if change.fields.contains(.publisher) { publisherFacets = try await index.publisherFacets() }
            // So a book that has just been marked read leaves "Unread" at once.
            refilter()
            errorMessage = nil
        } catch {
            show(error, doing: Loc.string("save the change to “%@”", entry.book.title))
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
        edit(books, actionName: Loc.string("Rating"), undoManager: undoManager) { $0.stars = wanted }
    }

    /// The 0 key: unrated, whatever it was.
    func clearRating(undoManager: UndoManager?) {
        edit(selectedEntries, actionName: Loc.string("Rating"), undoManager: undoManager) { $0.stars = 0 }
    }

    /// R, and the checkbox in the inspector.
    func toggleRead(undoManager: UndoManager?) {
        let books = selectedEntries
        guard !books.isEmpty else { return }
        let wanted = AcrossBooks.readStatusAfterToggle(books.map(\.book))
        edit(books, actionName: Loc.string("Read Status"), undoManager: undoManager) { $0.isRead = wanted }
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
        edit(books, actionName: Loc.string("Tags"), undoManager: undoManager) { book in
            if case .changed(let edited) = TagEdit.add(name, to: book, knownTags: known) {
                book = edited
            }
        }
        tagDraft = ""
    }

    func removeTag(_ name: String, undoManager: UndoManager?) {
        edit(selectedEntries, actionName: Loc.string("Tags"), undoManager: undoManager) { book in
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
            fieldRejection = FieldRejection(key: key, message: Loc.message(for: why))
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

    /// The same, told apart into a value, "none of them has one" and "Mixed" —
    /// which is what a row that is only read needs (`SharedValue`).
    func sharedValue(_ field: BookField) -> SharedValue {
        field.sharedValue(across: selectedEntries.map(\.book))
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
            errorMessage = Loc.message(for: why)
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
        let base = Loc.string("New Shelf")
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
            errorMessage = Loc.message(for: why)
        case .success(let after):
            apply(before, after, moving: id, actionName: Loc.string("Rename Shelf"), undoManager: undoManager)
        }
    }

    func moveShelf(_ id: UUID, under parent: UUID?, undoManager: UndoManager?) {
        let before = shelfTree
        switch ShelfEdit.move(id, under: parent, in: before) {
        case .failure(let why):
            errorMessage = Loc.message(for: why)
        case .success(let after):
            apply(before, after, moving: id, actionName: Loc.string("Move Shelf"), undoManager: undoManager)
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
            tree: after, previousTree: before, changes: changes, actionName: Loc.string("Delete Shelf"),
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
            changes.count > 1
                ? Loc.string("%1$@ (%2$@)", actionName, Loc.count("%lld books", changes.count))
                : actionName)
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
            show(error, doing: Loc.string("save the shelves"))
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
        edit(books, actionName: Loc.string("Add to Shelf"), undoManager: undoManager) { book in
            guard !book.shelves.contains(path) else { return }
            book.shelves = (book.shelves + [path]).sorted()
        }
    }

    func removeFromShelf(_ path: String, books: [LibraryEntry], undoManager: UndoManager?) {
        edit(books, actionName: Loc.string("Remove from Shelf"), undoManager: undoManager) { book in
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
            changes.count > 1
                ? Loc.string("%1$@ (%2$@)", actionName, Loc.count("%lld books", changes.count))
                : actionName)
        undoManager?.endUndoGrouping()
    }

    // MARK: Renaming and merging names (Sprint 8)

    /// The merge the sheet is showing, or `nil` when no sheet is open.
    var pendingMerge: NameMerge?
    /// What the last merge did, for the line under the sheet's button.
    private(set) var mergeReport: String?

    /// Opens the sheet on one spelling. `merging` decides whether it comes up
    /// as a rename of that one or as a merge with it already chosen.
    func beginRename(_ kind: NameKind, of name: String, merging: Bool = false) {
        mergeReport = nil
        pendingMerge = NameMerge(
            kind: kind, sources: [name], target: merging ? "" : name)
        // A merge starts with nothing typed, because the target is a choice;
        // a rename starts with the name itself, because it is a correction.
        if merging { pendingMerge?.sources = [name] }
    }

    /// Every spelling of a kind, for the sheet's list. Read off the facets the
    /// sidebar already loaded, so the sheet costs no query.
    func allNames(of kind: NameKind) -> [LibraryIndex.Facet] {
        switch kind {
        case .author: return authorFacets
        case .series: return seriesFacets
        case .publisher: return publisherFacets
        case .tag: return tagFacets
        }
    }

    /// What the merge would do, computed against the loaded entries. The sheet
    /// shows this and `applyMerge` executes this — one value, as every other
    /// plan in this program works (ADR 0002, decision 6).
    func plan(for merge: NameMerge) -> NameMergePlan {
        NameEdit.plan(merge, over: entries)
    }

    /// Writes the merge: one `metadata.opf` per book and one index row per
    /// book, through the ordinary editing chain, wrapped in a single undo step
    /// named for what it did.
    ///
    /// **It does not move a folder** (ADR 0007). What it does is offer to,
    /// afterwards, through `organizeSuggestion`.
    func applyMerge(_ merge: NameMerge, undoManager: UndoManager?) async {
        guard merge.refusal == nil else { return }
        let plan = plan(for: merge)
        guard !plan.isEmpty else {
            mergeReport = Loc.string("Nothing to change")
            return
        }

        pendingMerge = nil
        // The same frame every edit across a selection uses, so the count is
        // pluralised by the catalogue and the sentence is German in a German
        // window (ADR 0016).
        await applyBatch(
            plan.changes,
            actionName: plan.bookCount > 1
                ? Loc.string(
                    "%1$@ (%2$@)", Loc.core(merge.actionName),
                    Loc.count("%lld books", plan.bookCount))
                : Loc.core(merge.actionName),
            undoManager: undoManager)
        mergeReport = Loc.count("%lld books changed", plan.bookCount)
        organizeSuggestion = plan.bookCount
    }

    /// Writes a batch of changes one after another, as **one** step on the undo
    /// stack.
    ///
    /// Not the `apply`-per-book that `edit` uses across a selection. That shape
    /// starts one detached task per book, and each of those asks the index for
    /// the totals and for three facet lists when it lands: fine for the fifty
    /// books a selection holds, wrong for a merge, which can touch every book
    /// by one author. Here the writes are sequential and the index is asked
    /// once, at the end.
    ///
    /// Undo is registered **before** the first write, as everywhere else — once
    /// the file is written nobody can ask it what it used to say — and the
    /// registration inside the undo block is what gives redo for nothing:
    /// `UndoManager` records whatever is registered while undoing as the redo
    /// action.
    private func applyBatch(
        _ changes: [(entry: LibraryEntry, change: MetadataChange)], actionName: String,
        undoManager: UndoManager?
    ) async {
        guard !changes.isEmpty, let library, let index else { return }

        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let inverse = changes.map { (entry: $0.entry, change: $0.change.inverse) }
                Task { await model.applyBatch(inverse, actionName: actionName, undoManager: undoManager) }
            }
        }
        // Already translated by the caller: this one takes a finished
        // sentence, because the count in it has to be pluralised where the
        // count is known.
        undoManager?.setActionName(actionName)

        let editor = MetadataEditor(library: library)
        for (entry, change) in changes {
            do {
                // The entry may be stale by a field, and that is safe: the
                // editor reads the `metadata.opf` that is there and lays only
                // the changed fields over it.
                replace(try await editor.apply(change, to: entry, in: index))
            } catch {
                show(error, doing: Loc.string("save the change to “%@”", entry.book.title))
            }
        }
        totals = (try? await index.totals(coversOnDisk: coversOnDisk)) ?? totals
        await refreshFacets()
        refilter()
    }

    /// How many books a finished merge touched, so the window can ask "tidy the
    /// folders now?" once and then forget it. `nil` means nothing to offer.
    var organizeSuggestion: Int?

    // MARK: Similar spellings (Sprint 18, Teil C2)

    enum SimilarSpellingsPhase: Equatable {
        case ready([SimilarSpellingGroup])
        case done(mergedGroups: Int, mergedBooks: Int)
    }

    var similarSpellingsPhase: SimilarSpellingsPhase?

    /// Opens the preview with every group `SimilarSpellings` proposes across
    /// the whole library, authors and publishers together. Nothing is
    /// merged by this — a proposal fills the same preview list a person
    /// fills by hand (`docs/BACKLOG.md`'s own "Wishes" entry), and the
    /// confirmation stays exactly where "Merge into…" already put it.
    func beginSimilarSpellings() {
        similarSpellingsPhase = .ready(
            SimilarSpellings.authorGroups(among: entries) + SimilarSpellings.publisherGroups(among: entries))
    }

    /// Merges every accepted group as **one** undo step, through the same
    /// `NameEdit.replacing` "Merge into…" already executes — a proposal
    /// this sure of itself is still carried out by the one command Shelf
    /// already trusted to fold spellings together, not by a second path.
    func applySimilarSpellings(_ groups: [SimilarSpellingGroup], undoManager: UndoManager?) {
        let merges = groups.map(\.asMerge)
        guard !merges.isEmpty else {
            similarSpellingsPhase = nil
            return
        }
        let affected = entries.filter { entry in
            merges.contains { merge in
                merge.kind.names(of: entry.book).contains(where: Set(merge.sources).contains)
            }
        }
        guard !affected.isEmpty else {
            similarSpellingsPhase = .done(mergedGroups: 0, mergedBooks: 0)
            return
        }
        edit(affected, actionName: Loc.string("Merge Similar Spellings"), undoManager: undoManager) { book in
            for merge in merges {
                if let updated = NameEdit.replacing(merge, in: book) { book = updated }
            }
        }
        similarSpellingsPhase = .done(mergedGroups: merges.count, mergedBooks: affected.count)
        organizeSuggestion = affected.count
    }

    // MARK: Standardize fields (Sprint 18, Teil C3)

    enum FieldStandardizationPhase: Equatable {
        case ready(FieldStandardizationPlan)
        case done(Int)
    }

    var fieldStandardizationPhase: FieldStandardizationPhase?

    /// Computes C3's plan over the whole library and holds it fixed for the
    /// sheet to show. Nothing is written by this — every rule underneath it
    /// is a pure function with exactly one right answer, but the write
    /// itself is still a deliberate, previewed command like every other one
    /// (ADR 0018), not something that happens on opening a menu.
    func beginFieldStandardization() {
        fieldStandardizationPhase = .ready(FieldStandardization.plan(over: entries))
    }

    /// Writes exactly the plan that was shown — not a recomputation of it —
    /// as one undo step regardless of how many books or fields it touches.
    func applyFieldStandardization(_ plan: FieldStandardizationPlan, undoManager: UndoManager?) {
        guard !plan.isEmpty else {
            fieldStandardizationPhase = nil
            return
        }
        undoManager?.beginUndoGrouping()
        for (entry, change) in plan.changes { apply(change, to: entry, undoManager: undoManager) }
        undoManager?.setActionName(
            plan.bookCount > 1
                ? Loc.string(
                    "%1$@ (%2$@)", Loc.string("Standardize Fields"), Loc.count("%lld books", plan.bookCount))
                : Loc.string("Standardize Fields"))
        undoManager?.endUndoGrouping()
        fieldStandardizationPhase = .done(plan.bookCount)
        organizeSuggestion = plan.bookCount
    }

    private func refreshFacets() async {
        guard let index else { return }
        do {
            tagFacets = try await index.tagFacets()
            authorFacets = try await index.authorFacets()
            seriesFacets = try await index.seriesFacets()
            publisherFacets = try await index.publisherFacets()
        } catch {
            show(error, doing: Loc.string("read the library index"))
        }
    }

    // MARK: Organising the folders (Sprint 8)

    /// Where the `Organize Library…` sheet has got to.
    enum OrganizePhase: Equatable {
        case planning
        /// The preview. Nothing has moved.
        case ready(OrganizePlan)
        case running(OrganizeRunner.Progress)
        case done(OrganizeReport)
    }

    var organizePhase: OrganizePhase?
    /// Whether there is a manifest to undo, so the sheet can offer it.
    private(set) var canUndoOrganize = false
    /// Whether the app should keep folders in step with metadata changes.
    ///
    /// **Off by default** (ADR 0018). A path can be referenced from outside
    /// Shelf — a script, a hardlink backup, a Finder alias — and somebody who
    /// has those must not be surprised. With it on, a metadata change only
    /// *offers* an organise; nothing moves inside a keystroke either way.
    var keepFoldersInStep: Bool {
        get { UserDefaults.standard.bool(forKey: Self.keepFoldersKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.keepFoldersKey) }
    }

    static let keepFoldersKey = "de.erikemmer.shelf.keepFoldersInStep"

    /// Opens the sheet on a fresh preview. Nothing is moved by this.
    func beginOrganize() {
        organizeSuggestion = nil
        organizePhase = .planning
        Task { await planOrganize() }
    }

    private func planOrganize() async {
        guard let library, let index else { return }
        do {
            let entries = try await index.allEntries()
            let root = library.root
            let plan = await Task.detached(priority: .userInitiated) {
                OrganizePlanner.plan(
                    entries: entries, foldsCase: VolumeCase.folds(at: root),
                    folderExists: { OrganizeBookProbe.exists($0, under: root) },
                    folderIsEmpty: { OrganizeBookProbe.isEmpty($0, under: root) },
                    folderHoldsBook: { OrganizeBookProbe.holdsBook(at: $0, id: $1, under: root) })
            }.value
            // A stale cache is the cache's problem, and it is put right before
            // the person is shown anything (ADR 0001).
            if !plan.relocated.isEmpty {
                await writeFolders(plan.relocated.map { ($0.bookID, $0.folder) })
            }
            canUndoOrganize = !OrganizeManifest.read(in: library).isEmpty
            organizePhase = .ready(plan)
        } catch {
            organizePhase = nil
            show(error, doing: Loc.string("work out where the folders should be"))
        }
    }

    /// Moves the folders the preview named — and only those.
    func runOrganize(_ plan: OrganizePlan) {
        guard let library else { return }
        organizePhase = .running(OrganizeRunner.Progress(done: 0, total: plan.moves.count, currentTitle: ""))
        let manifest = OrganizeManifest.read(in: library)
        Task {
            do {
                let onProgress: @Sendable (OrganizeRunner.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in self?.organizePhase = .running(progress) }
                }
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await OrganizeRunner(makeHasher: SHA256Hasher.factory)
                        .run(.init(library: library, plan: plan, manifest: manifest), progress: onProgress)
                }.value

                // The folder first, the index second — always.
                await writeFolders(outcome.moved)
                try? outcome.report.append(in: library)
                canUndoOrganize = !outcome.manifest.isEmpty
                organizePhase = .done(outcome.report)
                await reload()
            } catch {
                organizePhase = nil
                show(error, doing: Loc.string("move the folders"))
            }
        }
    }

    /// Puts every folder the manifest names back where it came from.
    func undoOrganize() {
        guard let library else { return }
        organizePhase = .running(OrganizeRunner.Progress(done: 0, total: 0, currentTitle: ""))
        let manifest = OrganizeManifest.read(in: library)
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await OrganizeRunner(makeHasher: SHA256Hasher.factory)
                        .undo(manifest, in: library)
                }.value
                await writeFolders(outcome.moved)
                try? outcome.report.append(in: library)
                canUndoOrganize = !outcome.manifest.isEmpty
                organizePhase = .done(outcome.report)
                await reload()
            } catch {
                organizePhase = nil
                show(error, doing: Loc.string("put the folders back"))
            }
        }
    }

    /// Brings the index level with where the folders now are.
    private func writeFolders(_ moved: [(bookID: UUID, folder: String)]) async {
        guard let index else { return }
        for (bookID, folder) in moved {
            guard var entry = try? await index.entry(id: bookID) else { continue }
            entry.folder = folder
            try? await index.save(entry)
        }
    }

    // MARK: Exporting (Sprint 8)

    enum ExportPhase: Equatable {
        case choosing
        case planning
        case ready(ExportPlan)
        case running(ExportRunner.Progress)
        case done(ExportReport)
    }

    var exportPhase: ExportPhase?
    /// Where it would go. Chosen through an open panel, so the sandbox lets
    /// Shelf write there.
    var exportDestination: URL?
    var exportOptions = ExportPreset.archive.options
    /// Whether only the selected books go, rather than the whole library.
    var exportsSelectionOnly = false

    func beginExport(selectionOnly: Bool) {
        exportsSelectionOnly = selectionOnly && !selectedEntries.isEmpty
        exportPhase = .choosing
    }

    /// What would be written. Asked again whenever an option changes, because
    /// the count under the button has to be the count the button executes.
    func planExport() async {
        guard let library, let destination = exportDestination else { return }
        exportPhase = .planning
        let entries = exportsSelectionOnly ? selectedEntries : self.entries
        let options = exportOptions
        let root = library.root
        let plan = await Task.detached(priority: .userInitiated) {
            ExportPlanner.plan(
                entries: entries, libraryRoot: root, options: options,
                manifest: ExportManifest.read(at: destination))
        }.value
        exportPhase = .ready(plan)
    }

    func runExport(_ plan: ExportPlan) {
        guard let library, let destination = exportDestination else { return }
        exportPhase = .running(
            ExportRunner.Progress(
                filesDone: 0, filesTotal: plan.toWrite.count, bytesDone: 0,
                bytesTotal: plan.bytesToWrite, currentTitle: ""))
        let name = library.name
        Task {
            let onProgress: @Sendable (ExportRunner.Progress) -> Void = { [weak self] progress in
                Task { @MainActor in self?.exportPhase = .running(progress) }
            }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await ExportRunner(makeHasher: SHA256Hasher.factory)
                        .run(
                            .init(destination: destination, plan: plan, libraryName: name),
                            manifest: ExportManifest.read(at: destination), progress: onProgress)
                }.value
                exportPhase = .done(outcome.report)
            } catch {
                exportPhase = nil
                show(error, doing: Loc.string("export the library"))
            }
        }
    }

    // MARK: Writing into a book's own file (Sprint 10, Schritt E2)

    /// Where the `Write into the Book File…` sheet has got to.
    enum EPUBWritePhase: Equatable {
        case planning
        /// The preview. Nothing has been written.
        case ready(EPUBWrite.Plan)
        case running(EPUBWrite.Progress)
        case done(EPUBWrite.Report)
    }

    var epubWritePhase: EPUBWritePhase?

    /// Opens the sheet on a fresh plan for `entry` — the whole selection if
    /// `entry` is part of it and there is more than one book selected,
    /// otherwise just `entry` alone, the same "book or selection" rule
    /// `BookMenu.subject` already uses.
    func beginEPUBWrite(for entry: LibraryEntry) {
        let books = selection.contains(entry.id) && selection.count > 1 ? selectedEntries : [entry]
        beginEPUBWrite(for: books)
    }

    func beginEPUBWrite(for books: [LibraryEntry]) {
        epubWritePhase = .planning
        Task { await planEPUBWrite(books) }
    }

    private func planEPUBWrite(_ books: [LibraryEntry]) async {
        guard let library else { return }
        let plan = await Task.detached(priority: .userInitiated) {
            EPUBWrite.plan(for: books, library: library)
        }.value
        epubWritePhase = .ready(plan)
    }

    /// Writes every book the plan names, one at a time — `EPUBWrite.run`'s
    /// own rule, never a `TaskGroup` here either. The plan handed in is the
    /// exact plan `beginEPUBWrite` showed; nothing is replanned first.
    func runEPUBWrite(_ plan: EPUBWrite.Plan) {
        guard let library, let index else { return }
        epubWritePhase = .running(EPUBWrite.Progress(done: 0, total: plan.books.count, currentTitle: ""))
        let ids = Set(plan.books.map(\.entryID))
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.filter { ids.contains($0.id) }.map { ($0.id, $0) })
        Task {
            let onProgress: @Sendable (EPUBWrite.Progress) -> Void = { [weak self] progress in
                Task { @MainActor in self?.epubWritePhase = .running(progress) }
            }
            let report = await Task.detached(priority: .userInitiated) {
                await EPUBWrite.run(
                    plan.books, entries: entriesByID, library: library, index: index, progress: onProgress)
            }.value
            epubWritePhase = .done(report)
            await reload()
        }
    }

    /// Why this book is in *Duplicates*, in one line — or nothing when it is
    /// not. The best-founded rule when several matched: identical bytes is a
    /// fact and identical title-and-author is a guess, and the guess is the one
    /// somebody might act on by deleting a book.
    func duplicateReason(for id: UUID) -> DuplicateReason? {
        DuplicateReason.strongest(of: duplicateReasons[id] ?? [])
    }

    /// Every rule that flagged this book, best-founded first — what the
    /// inspector lists when a book is both a byte-for-byte copy and a
    /// title match.
    func duplicateReasons(for id: UUID) -> [DuplicateReason] {
        let found = duplicateReasons[id] ?? []
        return DuplicateReason.allCases.filter { found.contains($0) }
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

    /// Quick Look over the selected book (␣).
    ///
    /// The *first* of a multiple selection: a space bar over twenty books is a
    /// question about one of them. What it shows is `QuickLookPreview`'s
    /// decision — the file itself for a PDF or a comic, the cover already on
    /// disk for an EPUB or a MOBI, which macOS cannot preview at all.
    func quickLookSelection() {
        guard let library, let entry = selectedEntry else { return }
        QuickLookPreview.shared.toggle(entry, in: library)
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

    // MARK: Orphaned folders

    /// Opens the sheet and walks the library for folders nothing points at.
    ///
    /// A folder is an orphan when the index holds no book that lives in it —
    /// what an import killed between two index writes leaves behind. The walk
    /// only *reads*: names, sizes and each folder's `metadata.opf`. Nothing is
    /// moved, and the sheet shows every file by name before anything can be.
    func findOrphanedFolders() async {
        guard let library, let index else { return }
        isOrphanSheetPresented = true
        isScanningForOrphans = true
        defer { isScanningForOrphans = false }
        do {
            let known = Set(try await index.allEntries().map(\.folder))
            orphanedFolders = await Task.detached(priority: .userInitiated) {
                OrphanedFolders.find(in: library, knownFolders: known)
            }.value
        } catch {
            orphanedFolders = []
            show(error, doing: Loc.string("look for orphaned folders"))
        }
    }

    /// Moves the listed folders to the Trash, after the user confirmed a list
    /// that named every file in them.
    ///
    /// The Trash and never a delete: Shelf's judgement that a folder is debris
    /// is a judgement, and the difference between a mistake and a disaster is
    /// whether the folder can be dragged back out. The library's own books are
    /// never in this list — it is built from what the index does *not* hold.
    func trashOrphanedFolders(_ folders: [OrphanedFolder]) async {
        guard let library, !folders.isEmpty else { return }
        let failures = await Task.detached(priority: .userInitiated) {
            OrphanedFolders.moveToTrash(folders, in: library)
        }.value

        let moved = folders.count - failures.count
        orphanedFolders.removeAll { folder in
            failures.allSatisfy { $0.path != folder.path } && folders.contains { $0.path == folder.path }
        }
        if failures.isEmpty {
            errorMessage = nil
        } else {
            errorMessage =
                Loc.string(
                    "%1$@ moved to the Trash, %2$lld could not be: %3$@", Plural.folders(moved),
                    failures.count,
                    failures.map { "\($0.path) – \($0.message)" }.joined(separator: "; "))
        }
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
            // After, not before: an author has no row until a book claims
            // one, and a rebuild recreates every row from `AuthorSort.of`.
            try await index.applyAuthorSortOverrides(descriptor?.authorSortOverrides ?? [:])
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
                    Loc.string(
                        "%1$lld folder(s) hold no readable book. Nothing was changed or removed – "
                            + "see %2$@.", result.unreadableFolders.count, ImportReport.fileName)
            }
        } catch {
            show(error, doing: Loc.string("rebuild the index"))
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
        errorMessage = Loc.string("Could not %1$@: %2$@", what, detail)
        Self.logger.error("\(self.errorMessage ?? "", privacy: .public)")
    }

    private static func describe(_ failure: Library.Failure) -> String {
        switch failure {
        case .notALibrary(let name):
            return Loc.string("“%@” is not a Shelf library. Use New Library… to make one there.", name)
        case .alreadyALibrary(let name):
            return Loc.string("“%@” already holds a library. Open it instead.", name)
        case .cannotCreate(let name):
            return Loc.string("the folder “%@” could not be created. Is the disk writable?", name)
        case .cannotWriteDescriptor(let name):
            return Loc.string(
                "library.json in “%@” could not be written. Is the disk full or read-only?", name)
        case .newerSchema(let found, let supported):
            return Loc.string(
                "it was written by a newer Shelf (format %1$@; this one reads %2$@). Update Shelf "
                    + "to open it.", String(found), String(supported))
        }
    }

    private static func describe(_ failure: LibraryIndex.Failure) -> String {
        switch failure {
        case .cannotOpen(let name, let reason):
            return Loc.string(
                "the index of “%1$@” could not be opened (%2$@). The books are safe – the index "
                    + "can be rebuilt from the folders.", name, reason)
        }
    }

    private static func describe(_ failure: ImportRunner.Failure) -> String {
        switch failure {
        case .notEnoughSpace(let needed, let available):
            return Loc.string(
                "there is not enough room: %1$@ needed, %2$@ free. Nothing was copied.",
                Loc.size(needed), Loc.size(available))
        case .cannotCreateFolder(let name):
            return Loc.string("the folder for “%@” could not be created.", name)
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
            parts.append(Loc.string("%1$@ of %2$@ books", grouped(visible.count), grouped(entries.count)))
        } else {
            parts.append(Loc.count("%lld books", entries.count))
        }
        if !authorFacets.isEmpty { parts.append(Loc.count("%lld authors", authorFacets.count)) }
        if !seriesFacets.isEmpty { parts.append(Loc.count("%lld series", seriesFacets.count)) }
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
