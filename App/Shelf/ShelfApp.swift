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
                .onAppear { delegate.model = model }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .appSettings) {
                Divider()
                // The size is in the title rather than behind a confirmation:
                // clearing costs nothing but the time to decode again, and
                // knowing it is 412 MB is the whole reason anyone would.
                Button("Clear Cover Cache (\(CoverCachePolicy.sizeLabel(usedBytes: model.coverCacheBytes)))") {
                    Task { await model.clearCoverCache() }
                }
                .disabled(model.library == nil)
            }
            fileMenu
            libraryMenu
            viewMenu
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { isShowingShortcuts = true }
                    .keyboardShortcut("/", modifiers: .command)
            }
        }
    }

    /// Every shortcut at once, from the one table that also feeds the welcome
    /// screen – so the two can never tell the user different things.
    private var shortcutSheet: some View {
        SlateShortcutSheet(
            title: "Keyboard Shortcuts",
            groups: ShortcutGroup.allCases.map {
                (name: $0.rawValue, shortcuts: ShortcutReference.group($0).map(\.slate))
            }
        ) {
            isShowingShortcuts = false
        }
        .preferredColorScheme(.dark)
    }

    private var fileMenu: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Library…") { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("New Library…") { model.presentNewLibraryPanel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            openRecentMenu
            Divider()
            Button("Add Books…") { model.presentAddBooksPanel() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(model.library == nil)
            // Listed and disabled rather than hidden: it is the reason most
            // people will open Shelf at all (CONCEPT §7), and a menu that grows
            // between versions is harder to learn than one whose shape is fixed.
            Button("Import from Calibre…") {}
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(true)
            Divider()
            Button("Show in Finder") { model.revealSelectedInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedEntry == nil)
            Button("Open in Default App") { model.openSelectedInDefaultApp() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.selectedEntry == nil)
        }
    }

    /// File ▸ Open Recent. Libraries that cannot be reached are greyed out
    /// rather than removed – seeing that one is on an unplugged drive is useful.
    private var openRecentMenu: some View {
        Menu("Open Recent") {
            ForEach(model.recents.entries) { entry in
                Button(entry.name) { model.open(recent: entry) }
                    .disabled(!model.recents.isReachable(entry))
            }
            if !model.recents.entries.isEmpty { Divider() }
            Button("Clear Menu") { model.recents.clear() }
                .disabled(model.recents.entries.isEmpty)
        }
        .onAppear { model.recents.refreshAvailability() }
    }

    private var libraryMenu: some Commands {
        CommandMenu("Library") {
            Button("Search") { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.library == nil)
            Divider()
            Button("Previous Book") { model.selectPrevious() }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.library == nil)
            Button("Next Book") { model.selectNext() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.library == nil)
            Button("Row Above") { model.selectRowAbove() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(model.library == nil)
            Button("Row Below") { model.selectRowBelow() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(model.library == nil)
            Button("First Book") { model.selectFirst() }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(model.library == nil)
            Button("Last Book") { model.selectLast() }
                .keyboardShortcut(.end, modifiers: [])
                .disabled(model.library == nil)
            Divider()
            // Safe to offer precisely because the folder is the truth
            // (ADR 0001): it reads the folders and writes only the index.
            Button("Rebuild Index from Folders") {
                Task { await model.rebuildIndex() }
            }
            .disabled(model.library == nil || model.isLoading)
            Button("Close Library") { model.closeLibrary() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.library == nil)
        }
    }

    /// Hung into SwiftUI's own View menu rather than a second one with the same
    /// name – macOS shows every `CommandMenu` separately, so "View" would appear
    /// twice (a lesson from Selector).
    private var viewMenu: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Larger Covers") { model.enlargeCovers() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(model.library == nil)
            Button("Smaller Covers") { model.shrinkCovers() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(model.library == nil)
            Divider()
            Toggle(
                "Inspector",
                isOn: Binding(get: { model.isInspectorShown }, set: { model.isInspectorShown = $0 })
            )
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(model.library == nil)
            Divider()
            Picker(
                "Show As",
                selection: Binding(get: { model.viewMode }, set: { model.viewMode = $0 })
            ) {
                // ⌘1 and ⌘2, as CONCEPT §3.2 asks. The shortcuts are on the
                // items rather than on a pair of buttons so the menu says what
                // the keys do.
                ForEach(Array(LibraryViewSettings.Mode.allCases.enumerated()), id: \.element) { offset, mode in
                    Label(mode.label, systemImage: mode.icon)
                        .tag(mode)
                        .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: .command)
                }
            }
            .disabled(model.library == nil)
            Divider()
            // Every field, both ways round, the current one ticked. The same
            // field again turns it round — what clicking a table header does.
            Menu("Sort By") {
                ForEach(BookSort.allCases, id: \.self) { field in
                    Button {
                        model.order =
                            model.order.field == field
                            ? model.order.reversed : BookOrder(field)
                    } label: {
                        Label(
                            field.label,
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
