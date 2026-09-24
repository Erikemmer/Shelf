import AppKit
import ShelfCore
import SlateKit
import SwiftUI
import UniformTypeIdentifiers

/// Three columns, in the spirit of Final Cut Pro and of Selector:
/// Sidebar (left) · Cover grid (centre) · Inspector (right).
struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    /// The window's undo manager, so a key press lands on the same undo stack
    /// as a click in the inspector.
    @Environment(\.undoManager) private var undoManager
    /// 1–5, 0, R and T, watched at the window. See `EditingKeyMonitor` for why
    /// they are neither menu shortcuts nor a view's `.onKeyPress`.
    @State private var editingKeys = EditingKeyMonitor()
    /// **The** focus of this window, handed down to the grid and to the search
    /// field. One binding, so moving the keyboard to one of them is by
    /// construction taking it off the other — see `LibraryModel.focusTarget`.
    @FocusState private var focus: WindowFocus?

    var body: some View {
        Group {
            // Without a library the three panels would all be empty; show the
            // way in instead of three grey boxes.
            if model.library == nil { WelcomeView() } else { workspace }
        }
        .background(Slate.windowBackground)
        // "My Library — Shelf" while one is open, plain "Shelf" before.
        .navigationTitle(model.library.map { "\($0.name) — Shelf" } ?? "Shelf")
        .toolbar { toolbarContent }
        .overlay(alignment: .top) { banners }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            FolderDrop.handle(providers, into: model)
        }
        .modifier(WorkflowSheets(undoManager: undoManager))
        .onAppear {
            editingKeys.start(handleWindowKey)
            focus = model.focusTarget
            // A reader plugged in before a library is open still belongs in
            // the sidebar, so this does not wait for one.
            model.startWatchingDevices()
        }
        .onDisappear {
            editingKeys.stop()
            model.stopWatchingDevices()
        }
        // The model asks; the window moves the keyboard. Driven by the counter
        // rather than by the value, because ⌘F pressed twice in a row is two
        // requests and the value does not change between them.
        .onChange(of: model.focusRequest) { _, _ in
            // `.elsewhere` means something outside this binding has asked for
            // the keyboard — the inspector's tag field. Letting go is the whole
            // of what is wanted; claiming `nil`'s opposite would be a second
            // view asking to be focused.
            focus = model.focusTarget == .elsewhere ? nil : model.focusTarget
        }
    }

    /// The keys the window answers. Returns true when the key was used, which
    /// is what keeps it from travelling on to anything else.
    ///
    /// Nothing happens without a library, so the keys are inert on the welcome
    /// screen rather than being swallowed there. The navigation keys need no
    /// *selected* book — → with nothing selected picks the first, which is what
    /// makes the grid reachable from the keyboard at all — and the editing keys
    /// do, because there is nothing to edit otherwise.
    private func handleWindowKey(_ key: WindowKey) -> Bool {
        guard model.library != nil else { return false }
        switch key {
        case .left: model.selectPrevious()
        case .right: model.selectNext()
        case .up: model.selectRowAbove()
        case .down: model.selectRowBelow()
        case .home: model.selectFirst()
        case .end: model.selectLast()
        case .character(let characters):
            return handleEditingKey(characters)
        }
        model.noteInteraction()
        return true
    }

    /// 1–5, 0, R, T and the space bar. All of them act on the selected book, so
    /// all of them are inert without one.
    private func handleEditingKey(_ characters: String) -> Bool {
        guard model.selectedEntry != nil else { return false }
        switch characters {
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
        case " ":
            // Quick Look, and through the same monitor as the rating keys for
            // the same reason (ADR 0006): a menu shortcut would swallow the
            // space bar before the search field ever saw it, and nobody could
            // type a title with a space in it.
            model.quickLookSelection()
        default:
            return false
        }
        model.noteInteraction()
        return true
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: Theme.sidebarWidth)
            Rectangle().fill(Slate.separator).frame(width: 1)
            content
            if model.isInspectorShown {
                Rectangle().fill(Slate.separator).frame(width: 1)
                InspectorView()
                    .frame(width: Theme.inspectorWidth)
            }
        }
    }

    /// The middle column: the strip, and under it whichever view is chosen.
    ///
    /// The switch is here rather than inside either view so that both of them
    /// are only about drawing books — and so the strip above them is one strip
    /// and not two that have to be kept alike.
    private var content: some View {
        VStack(spacing: 0) {
            LibraryBar(focus: $focus)
            Rectangle().fill(Slate.separator).frame(height: 1)
            switch model.viewMode {
            case .grid: CoverGridView(focus: $focus)
            case .table: BookTableView(focus: $focus)
            }
        }
        .background(Slate.contentBackground)
        .confirmationDialog(
            bookRemovalQuestion, isPresented: isAskingToRemoveBook, titleVisibility: .visible
        ) {
            Button(Loc.string("Move Book to Trash"), role: .destructive) {
                if let pending = model.pendingBookRemoval {
                    model.removeBook(pending, undoManager: undoManager)
                }
                model.pendingBookRemoval = nil
            }
            Button(Loc.string("Cancel"), role: .cancel) { model.pendingBookRemoval = nil }
        } message: {
            // Every file, named — the confirmation CLAUDE.md's own rules ask
            // for whenever a book file could be displaced, and the whole
            // point of this step rather than an afterthought under it.
            Text(bookRemovalFileList)
        }
    }

    private var isAskingToRemoveBook: Binding<Bool> {
        Binding(
            get: { model.pendingBookRemoval != nil },
            set: { if !$0 { model.pendingBookRemoval = nil } })
    }

    private var bookRemovalQuestion: String {
        guard let entry = model.pendingBookRemoval else { return "" }
        return Loc.string("Move “%@” to the Trash?", entry.book.title)
    }

    private var bookRemovalFileList: String {
        guard let entry = model.pendingBookRemoval else { return "" }
        let names = entry.formats.map(\.fileName).sorted().joined(separator: ", ")
        return Loc.string("This can be undone with ⌘Z. Files: %@", names)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.presentOpenPanel()
            } label: {
                Label(Loc.string("Open Library"), systemImage: "folder")
            }
            .help(Loc.string("Open a Shelf library (⌘O)"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.presentAddBooksPanel()
            } label: {
                Label(Loc.string("Add Books"), systemImage: "plus")
            }
            .labelStyle(.titleAndIcon)
            .help(Loc.string("Add books or a folder of books (⌘I)"))
            .disabled(model.library == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(
                isOn: Binding(get: { model.isInspectorShown }, set: { model.isInspectorShown = $0 })
            ) {
                Label(Loc.string("Inspector"), systemImage: "sidebar.right")
            }
            .labelStyle(.titleAndIcon)
            .help(model.isInspectorShown ? Loc.string("Hide the Inspector") : Loc.string("Show the Inspector"))
            .disabled(model.library == nil)
        }
    }

    /// An error, and the warning a synced library gets. Both dismissible: a
    /// banner nobody can close is a banner that hides the app.
    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 4) {
            if let message = model.errorMessage {
                SlateBanner(message)
                    .onTapGesture { model.dismissError() }
                    .help(Loc.string("Click to dismiss"))
            }
            if let warning = model.syncWarning {
                SlateBanner(warning, tint: Slate.accent.opacity(0.85))
                    .onTapGesture { model.dismissSyncWarning() }
                    .help(Loc.string("Click to dismiss"))
            }
            // What a finished merge offers, once: the books have been renamed,
            // and their folders still carry the old spelling. Clicking opens
            // the preview — it does not move anything by itself (ADR 0018).
            if let count = model.organizeSuggestion {
                SlateBanner(
                    Loc.string(
                        "%1$@ changed — tidy the folders now?",
                        Loc.count("%lld books", count)),
                    tint: Slate.accent.opacity(0.85)
                )
                .onTapGesture { model.beginOrganize() }
                .help(Loc.string("Open Organize Library… Nothing moves until you say so."))
            }
        }
        .padding(.horizontal, 20)
    }
}

/// Every sheet a workflow (import, device, metadata, organise, merge…) opens
/// from this window, split out of `ContentView.body` into its own modifier.
///
/// Not a style choice — a dozen chained `.sheet(...)` calls in one expression
/// is exactly the shape that made the type checker give up ("unable to
/// type-check this expression in reasonable time") the moment a thirteenth
/// was added for "Standardize Fields…". Splitting the chain across two
/// modifiers, each type-checked on its own, is the fix; it has to be two
/// rather than one flat list here for the same reason.
private struct WorkflowSheets: ViewModifier {
    @Environment(LibraryModel.self) private var model
    let undoManager: UndoManager?

    func body(content: Content) -> some View {
        content
            .modifier(LibraryWorkflowSheets(undoManager: undoManager))
            .modifier(DeviceAndReaderSheets(undoManager: undoManager))
    }
}

private struct LibraryWorkflowSheets: ViewModifier {
    @Environment(LibraryModel.self) private var model
    let undoManager: UndoManager?

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: Binding(
                    get: { model.isImportSheetPresented },
                    set: { model.isImportSheetPresented = $0 })
            ) {
                ImportSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.isOrphanSheetPresented },
                    set: { model.isOrphanSheetPresented = $0 })
            ) {
                OrphanSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.isFetchMetadataSheetPresented },
                    set: { model.isFetchMetadataSheetPresented = $0 })
            ) {
                // The window's undo manager, handed down: a sheet has none of
                // its own, so a fetched field would be written with no way back.
                FetchMetadataSheet(undoManager: undoManager).environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.organizePhase != nil },
                    set: { if !$0 { model.organizePhase = nil } })
            ) {
                OrganizeSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.mergePhase != nil },
                    set: { if !$0 { model.mergePhase = nil } })
            ) {
                MergeSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.similarSpellingsPhase != nil },
                    set: { if !$0 { model.similarSpellingsPhase = nil } })
            ) {
                SimilarSpellingsSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.fieldStandardizationPhase != nil },
                    set: { if !$0 { model.fieldStandardizationPhase = nil } })
            ) {
                FieldStandardizationSheet().environment(model)
            }
    }
}

private struct DeviceAndReaderSheets: ViewModifier {
    @Environment(LibraryModel.self) private var model
    let undoManager: UndoManager?

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: Binding(
                    get: { model.devices.isSendSheetPresented },
                    set: { model.devices.isSendSheetPresented = $0 })
            ) {
                SendToDeviceSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.isDeviceContentsSheetPresented },
                    set: { model.isDeviceContentsSheetPresented = $0 })
            ) {
                DeviceContentsSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.devices.isDeleteSheetPresented },
                    set: { model.devices.isDeleteSheetPresented = $0 })
            ) {
                DeleteFromDeviceSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.exportPhase != nil },
                    set: { if !$0 { model.exportPhase = nil } })
            ) {
                ExportSheet().environment(model)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.epubWritePhase != nil },
                    set: { if !$0 { model.epubWritePhase = nil } })
            ) {
                WriteIntoBookSheet().environment(model)
            }
    }
}
