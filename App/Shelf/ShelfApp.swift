import AppKit
import Darwin
import ShelfCore
import SlateKit
import SwiftUI
import os

/// App entry point. One window per library; dark appearance like Final Cut Pro.
@main
struct ShelfApp: App {
    @State private var model = LibraryModel()
    @State private var isShowingShortcuts = false
    /// Folders arriving from outside are handled by the delegate, not by
    /// `onOpenURL`: that modifier lives inside a `WindowGroup`, so SwiftUI opens
    /// a *new window* for every URL. Two libraries opened in one session left
    /// three windows behind, which the smoke test's window count noticed.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // The clock for "how long until the window is usable" starts here, not
        // at the first cell. Silent unless SHELF_TIMING=1.
        TimingLog.shared.noteLaunch()
    }

    var body: some Scene {
        WindowGroup("Shelf") {
            ContentView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1_100, minHeight: 700)
                .sheet(isPresented: $isShowingShortcuts) { shortcutSheet }
                .onAppear {
                    delegate.model = model
                    // So the two "Clear …" items in the app menu can name what
                    // they would throw away before anybody opens the menu.
                    Task { await model.refreshOnlineCacheSize() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .appSettings) {
                Divider()
                // The size is in the title rather than behind a confirmation:
                // clearing costs nothing but the time to decode again, and
                // knowing it is 412 MB is the whole reason anyone would.
                Button(
                    Loc.string("Clear Cover Cache (%@)", CoverCachePolicy.sizeLabel(usedBytes: model.coverCacheBytes))
                ) {
                    Task { await model.clearCoverCache() }
                }
                .disabled(model.library == nil)
                // The answers the two metadata services gave, so the same ISBN
                // is not asked twice. Not inside a library: it is keyed by an
                // ISBN and serves every library on this Mac.
                Button(
                    Loc.string(
                        "Clear Downloaded Metadata (%@)", CoverCachePolicy.sizeLabel(usedBytes: model.onlineCacheBytes))
                ) {
                    Task { await model.clearOnlineCache() }
                }
                Divider()
                // Off by default, and a toggle rather than a settings window
                // because it is the only setting Shelf has (ADR 0018). With it
                // on, a metadata change *offers* an organise; it still never
                // moves a folder inside a keystroke.
                Toggle(
                    Loc.string("Keep Folders in Step with Metadata Changes"),
                    isOn: Binding(
                        get: { model.keepFoldersInStep },
                        set: { model.keepFoldersInStep = $0 }))
            }
            fileMenu
            libraryMenu
            deviceMenu
            viewMenu
            CommandGroup(replacing: .help) {
                Button(Loc.string("Keyboard Shortcuts")) { isShowingShortcuts = true }
                    .shortcut(.thisList)
            }
        }
    }

    /// Every shortcut at once, from the one table that also feeds the welcome
    /// screen – so the two can never tell the user different things.
    private var shortcutSheet: some View {
        SlateShortcutSheet(
            title: Loc.string("Keyboard Shortcuts"),
            groups: ShortcutGroup.allCases.map {
                (name: Loc.core($0.title), shortcuts: ShortcutReference.group($0).map(\.slate))
            }
        ) {
            isShowingShortcuts = false
        }
        .preferredColorScheme(.dark)
    }

    private var fileMenu: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(Loc.string("Open Library…")) { model.presentOpenPanel() }
                .shortcut(.openLibrary)
            Button(Loc.string("New Library…")) { model.presentNewLibraryPanel() }
                .shortcut(.newLibrary)
            openRecentMenu
            Divider()
            Button(Loc.string("Add Books…")) { model.presentAddBooksPanel() }
                .shortcut(.addBooks)
                .disabled(model.library == nil)
            // The reason most people will open Shelf at all (CONCEPT §7).
            Button(Loc.string("Import from Calibre…")) { model.presentCalibrePanel() }
                .shortcut(.importFromCalibre)
            Divider()
            // The way out. A library that cannot leave is a library nobody
            // should put ten years into (Leitlinie, principle 3).
            Button(Loc.string("Export Library…")) { model.beginExport(selectionOnly: false) }
                .disabled(model.library == nil)
            Button(Loc.string("Export Selected Books…")) { model.beginExport(selectionOnly: true) }
                .disabled(model.library == nil || model.selectedEntries.isEmpty)
            // ⌘E, the shortcut sheet has said so since Sprint 1. It asks; it
            // writes nothing until a person has agreed field by field.
            Button(Loc.string("Fetch Metadata…")) { model.presentFetchMetadata() }
                .shortcut(.fetchMetadata)
                .disabled(model.library == nil || model.selection.isEmpty)
            Divider()
            Button(Loc.string("Show in Finder")) { model.revealSelectedInFinder() }
                .shortcut(.showInFinder)
                .disabled(model.selectedEntry == nil)
            Button(Loc.string("Open in Default App")) { model.openSelectedInDefaultApp() }
                .shortcut(.openInDefaultApp)
                .disabled(model.selectedEntry == nil)
        }
    }

    /// File ▸ Open Recent. Libraries that cannot be reached are greyed out
    /// rather than removed – seeing that one is on an unplugged drive is useful.
    private var openRecentMenu: some View {
        Menu(Loc.string("Open Recent")) {
            ForEach(model.recents.entries) { entry in
                Button(entry.name) { model.open(recent: entry) }
                    .disabled(!model.recents.isReachable(entry))
            }
            if !model.recents.entries.isEmpty { Divider() }
            Button(Loc.string("Clear Menu")) { model.recents.clear() }
                .disabled(model.recents.entries.isEmpty)
        }
        .onAppear { model.recents.refreshAvailability() }
    }

    private var libraryMenu: some Commands {
        CommandMenu(Loc.string("Library")) {
            Button(Loc.string("Search")) { model.focusSearch() }
                .shortcut(.search)
                .disabled(model.library == nil)
            Divider()
            // In the Library menu rather than in Edit: SwiftUI's own Select All
            // belongs to whatever text field has the keyboard, and putting this
            // there would fight it. Here it means one thing — every book the
            // filter is showing.
            Button(Loc.string("Select All Books")) { model.selectAll() }
                .shortcut(.selectAllBooks)
                .disabled(model.library == nil)
            Divider()
            // **No `keyboardShortcut` on these six.** The keys are ←→↑↓, Home
            // and End, and they are answered by `EditingKeyMonitor` instead —
            // ADR 0017, the measurement ADR 0006 took and did not act on for
            // the arrows: a held → spent 31 % of ten seconds inside
            // `NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` and
            // another 27 % flashing the menu title, against 0.3 % doing the
            // work. The items stay, because a menu is a keyboard route of its
            // own (⌃F2) and because an action that exists only as a bare key
            // is an action nobody finds; the keys themselves are in
            // `ShortcutReference`, which is what the ⌘? sheet reads.
            Button(Loc.string("Previous Book")) { model.selectPrevious() }
                .disabled(model.library == nil)
            Button(Loc.string("Next Book")) { model.selectNext() }
                .disabled(model.library == nil)
            Button(Loc.string("Row Above")) { model.selectRowAbove() }
                .disabled(model.library == nil)
            Button(Loc.string("Row Below")) { model.selectRowBelow() }
                .disabled(model.library == nil)
            Button(Loc.string("First Book")) { model.selectFirst() }
                .disabled(model.library == nil)
            Button(Loc.string("Last Book")) { model.selectLast() }
                .disabled(model.library == nil)
            Divider()
            // Safe to offer precisely because the folder is the truth
            // (ADR 0001): it reads the folders and writes only the index.
            Button(Loc.string("Rebuild Index from Folders")) {
                Task { await model.rebuildIndex() }
            }
            .disabled(model.library == nil || model.isLoading)
            // What an interrupted import leaves behind. It only looks; the
            // sheet names every file before anything can move, and what moves
            // moves to the Trash.
            Button(Loc.string("Find Orphaned Folders…")) {
                Task { await model.findOrphanedFolders() }
            }
            .disabled(model.library == nil || model.isLoading)
            // The one command that moves a book's folder. It shows the whole
            // list first and moves nothing until a button is pressed
            // (ADR 0018).
            Button(Loc.string("Organize Library…")) { model.beginOrganize() }
                .disabled(model.library == nil || model.isLoading)
            Button(Loc.string("Close Library")) { model.closeLibrary() }
                .shortcut(.closeLibrary)
                .disabled(model.library == nil)
        }
    }

    /// Everything that touches a reader. Its own menu rather than items in
    /// Library, because one of them is the only destructive thing Shelf does
    /// and it must not sit next to "Rebuild Index".
    private var deviceMenu: some Commands {
        CommandMenu(Loc.string("Device")) {
            Button(sendLabel) { model.sendSelectionToDevice(nil) }
                .shortcut(.sendToDevice)
                .disabled(model.devices.selectedDevice == nil || model.selection.isEmpty)
            Button(Loc.string("Show What Is on the Device…")) { model.showDeviceContents(nil) }
                .disabled(model.devices.selectedDevice == nil)
            Divider()
            // Deleting on a device is reached only through the contents sheet,
            // where the files are chosen, and then only through a confirmation
            // that names every one of them (ADR 0014). This item opens that
            // sheet; it deletes nothing itself, and the menu says so.
            Button(Loc.string("Delete from Device…")) { model.showDeviceContents(nil) }
                .disabled(model.devices.selectedDevice == nil)
            Divider()
            treatVolumeMenu
            Divider()
            Button(ejectLabel) {
                if let device = model.devices.selectedDevice { model.devices.eject(device) }
            }
            .disabled(model.devices.selectedDevice == nil || model.devices.phase.isRunning)
        }
    }

    /// Which row of the shortcut table a view mode's key lives in.
    ///
    /// A `switch` rather than a ternary, so a third mode is a build error here
    /// rather than a menu item that quietly claims ⌘2.
    private static func shortcut(for mode: LibraryViewSettings.Mode) -> ShortcutAction {
        switch mode {
        case .grid: return .grid
        case .table: return .table
        }
    }

    private var sendLabel: String {
        guard let device = model.devices.selectedDevice else { return Loc.string("Send to Device") }
        return Loc.string("Send to “%@”", device.name)
    }

    private var ejectLabel: String {
        guard let device = model.devices.selectedDevice else { return Loc.string("Eject") }
        return Loc.string("Eject “%@”", device.name)
    }

    /// The way in when no marker matches — a reader Shelf has never heard of,
    /// or a card taken out of one (CONCEPT §8.1).
    ///
    /// One item per profile, each opening a panel to choose the volume.
    ///
    /// The profile is picked in the menu and the volume in an **open panel**,
    /// rather than both in the menu, and that is not a matter of taste: the
    /// sandbox treats choosing a folder in a panel as permission to read it,
    /// and there are volumes Shelf cannot look inside without that — a mounted
    /// disk image is one, measured in Sprint 5. A menu of volume names could
    /// list them and not get in.
    private var treatVolumeMenu: some View {
        Menu(Loc.string("Treat Volume as Device")) {
            ForEach(DeviceProfiles.all) { profile in
                Button(profile.name + "…") { model.presentDeviceVolumePanel(as: profile.id) }
            }
        }
    }

    /// Hung into SwiftUI's own View menu rather than a second one with the same
    /// name – macOS shows every `CommandMenu` separately, so "View" would appear
    /// twice (a lesson from Selector).
    private var viewMenu: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button(Loc.string("Larger Covers")) { model.enlargeCovers() }
                .shortcut(.largerCovers)
                .disabled(model.library == nil)
            Button(Loc.string("Smaller Covers")) { model.shrinkCovers() }
                .shortcut(.smallerCovers)
                .disabled(model.library == nil)
            Divider()
            Toggle(
                Loc.string("Inspector"),
                isOn: Binding(get: { model.isInspectorShown }, set: { model.isInspectorShown = $0 })
            )
            .shortcut(.inspector)
            .disabled(model.library == nil)
            Divider()
            Picker(
                Loc.string("Show As"),
                selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
            ) {
                // ⌘1 and ⌘2, as CONCEPT §3.2 asks. The shortcuts are on the
                // items rather than on a pair of buttons so the menu says what
                // the keys do.
                ForEach(LibraryViewSettings.Mode.allCases, id: \.self) { mode in
                    // `Loc.core`, not the bare label. `mode.label` is a
                    // `String` from the core, and SwiftUI draws a `String`
                    // verbatim — so a German menu bar read "Grid" and "Table"
                    // while the strip two points below it read "Cover" and
                    // "Tabelle". The ⌘? sheet and `SortMenu` had it right and
                    // the menu bar did not, which is the whole argument for
                    // one table (ADR 0016).
                    Label(Loc.core(mode.label), systemImage: mode.icon)
                        .tag(mode)
                        // ⌘1 and ⌘2 out of `ShortcutReference`, not counted off
                        // the enumeration: the key a menu declares and the key
                        // the ⌘? sheet prints are now one fact.
                        .shortcut(Self.shortcut(for: mode))
                }
            }
            .disabled(model.library == nil)
            Divider()
            // Every field, both ways round, the current one ticked. The same
            // field again turns it round — what clicking a table header does.
            Menu(Loc.string("Sort By")) {
                ForEach(BookSort.allCases, id: \.self) { field in
                    Button {
                        model.order =
                            model.order.field == field
                            ? model.order.reversed : BookOrder(field)
                    } label: {
                        Label(
                            Loc.core(field.label),
                            systemImage: model.order.field == field
                                ? (model.order.ascending ? "arrow.up" : "arrow.down") : "")
                    }
                }
            }
            .disabled(model.library == nil)
        }
    }
}

/// Handles a library folder that arrives from outside the app: dropped on the
/// icon, double-clicked, or `open -a Shelf <folder>`.
///
/// An `NSApplicationDelegate` rather than SwiftUI's `onOpenURL`, because that
/// modifier sits inside a `WindowGroup` and SwiftUI answers it by opening a new
/// window. One app, one library, one window: a second folder replaces what is
/// open, as `File ▸ Open Library…` does.
///
/// It is also what lets `make smoke` open a real library without permission to
/// automate System Events, so the test can measure a window with books in it
/// rather than only the welcome screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the window when it appears. A folder that arrives before then is
    /// remembered and opened as soon as there is something to open it with.
    var model: LibraryModel? {
        didSet {
            guard let pending, let model else { return }
            self.pending = nil
            model.open(pending)
        }
    }

    private var pending: URL?

    /// Held for the app's lifetime — a `DispatchSourceSignal` that is
    /// deallocated stops delivering.
    private var sigtermSource: DispatchSourceSignal?

    /// `SIGTERM`'s default disposition ends the process at once — the same
    /// as `SIGKILL` from an in-flight import's point of view, nothing
    /// flushes. Ignoring the default and routing the signal through
    /// `NSApp.terminate(nil)` instead means `SIGTERM` takes exactly the path
    /// ⌘Q already does, in `applicationShouldTerminate(_:)` below — one
    /// answer for both abort kinds a process can be *asked*, rather than
    /// forced, to leave by. `SIGKILL` cannot be caught here or anywhere:
    /// POSIX disallows it, so that one stays open (`docs/BACKLOG.md`).
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.terminationLogger.notice("applicationDidFinishLaunching: installing SIGTERM handler")
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Self.terminationLogger.notice("SIGTERM received")
            self?.requestTermination()
        }
        source.resume()
        sigtermSource = source

        // ⌘Q and File ▸ Quit both fire this one `NSMenuItem`, whatever its
        // localised title — repointing its action rather than replacing the
        // command with `CommandGroup(replacing: .appTermination)` needs no
        // catalogue entry of its own and keeps AppKit's own wording exactly
        // as it is. Dock ▸ Quit sends the terminate Apple Event straight to
        // `NSApp`, bypassing this item entirely, and stays outside what this
        // reaches (`docs/BACKLOG.md`).
        if let quitItem = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
            $0.action == #selector(NSApplication.terminate(_:))
        }) {
            quitItem.target = self
            quitItem.action = #selector(requestTermination)
        }
    }

    /// The one place both ⌘Q/File ▸ Quit and `SIGTERM` end up. Three steps,
    /// in this order, each measured against the real, running app with `log
    /// stream` — not assumed:
    ///
    /// 1. Cancel the import *first*, before anything else. Every one of its
    ///    progress updates is its own `Task { @MainActor in … }`, one per
    ///    file, throttled but still frequent for a large import — enough of
    ///    them queued ahead of a block asked for later that this whole
    ///    method, called after them, sometimes never got a turn until the
    ///    run finished on its own. Cancelling here, synchronously, stops the
    ///    flood at its source within one file's processing time, which nothing
    ///    later in this method needs to wait behind.
    /// 2. Dismiss any presented sheet. Not cosmetic: `applicationShouldTerminate(_:)`
    ///    was never reached at all — not merely delayed — while the import
    ///    sheet was still on screen.
    /// 3. Ask `NSApp` to terminate, `.async` rather than directly: calling it
    ///    synchronously and reentrantly, from a block already running on
    ///    `DispatchQueue.main` (this one), also measurably kept it from being
    ///    reached, whatever the exact AppKit mechanism behind that is.
    @objc private func requestTermination() {
        model?.cancelImportRun()
        model?.isImportSheetPresented = false
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static let terminationLogger = Logger(subsystem: "de.erikemmer.shelf", category: "termination")

    /// A quit with an import mid-copy must not just let the process end:
    /// `ImportRunner` writes its short last batch only when the `Task`
    /// running it is cancelled and allowed to finish, and until Sprint 13
    /// nothing ever asked it to — a killed import and a quit import left the
    /// same orphaned folders (`CHANGELOG.md`, Sprint 13, Teil A). `.examining`
    /// and every other phase have written nothing yet, so only `.running`
    /// delays termination at all.
    ///
    /// Two things tried here and abandoned, both measured against the real,
    /// running app with `log stream`, neither assumed: `.terminateLater` with
    /// an async `Task { @MainActor in … await … }` replying once the run
    /// finished — the reply never came, because AppKit's own wait for it is
    /// a nested loop on the main thread that a `Task` hop onto the main actor
    /// never got a turn inside. Answering that by pumping `.default` mode by
    /// hand instead of returning `.terminateLater` at all — same result,
    /// because the real obstacle is GCD's main queue being serial: this
    /// callback is already *running* as one block on it, and nothing else
    /// scheduled on that same queue starts until this one returns, however
    /// the waiting is spelled. `ImportModel.copyFinishedSemaphore` exists
    /// because of exactly this: signalled from a `Task.detached` that never
    /// needed the main queue to make progress, so waiting on it here does
    /// not have the problem above.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.terminationLogger.notice(
            "applicationShouldTerminate: model=\(self.model != nil), isImportRunning=\(self.model?.isImportRunning ?? false)"
        )
        guard let model, model.isImportRunning, let semaphore = model.importCopyFinishedSemaphore else {
            return .terminateNow
        }
        model.cancelImportRun()
        Self.terminationLogger.notice("waiting for the import's copy to finish")
        // A bound in case the semaphore is somehow never signalled — quitting
        // late is a much smaller problem than never quitting at all.
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            Self.terminationLogger.error("the import's copy did not finish within 30 s, terminating anyway")
        } else {
            Self.terminationLogger.notice("the import's copy finished, terminating")
        }
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // One library at a time, so several folders at once take the first and
        // say nothing about the rest rather than opening windows nobody asked for.
        guard let url = urls.first(where: \.hasDirectoryPath) ?? urls.first else { return }
        guard let model else {
            pending = url
            return
        }
        model.open(url)
    }
}
