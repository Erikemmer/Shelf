import AppKit
import ShelfCore
import SlateKit
import SwiftUI

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
                        .shortcut(mode == .grid ? .grid : .table)
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
