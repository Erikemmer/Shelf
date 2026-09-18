import AppKit
import ShelfCore
import SlateKit
import SwiftUI

/// What the window shows before a library is open: the ways in, what was open
/// last, and the handful of keys worth knowing.
///
/// Quiet on purpose – it is a workspace waiting for work, not a landing page.
struct WelcomeView: View {
    @Environment(LibraryModel.self) private var model
    /// Highlights the drop zone while a folder hovers over it.
    @State private var isDropTargeted = false

    var body: some View {
        SlateWelcomeLayout {
            SlateWelcomeHeader(
                title: Loc.string("Shelf"),
                subtitle: Loc.string("Your eBooks, with their covers, metadata and devices in one place."))

            SlatePrimaryButton(Loc.string("Open Library…")) { model.presentOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .help(Loc.string("Choose a Shelf library folder (⌘O)"))

            SlateSecondaryButton(Loc.string("New Library…")) { model.presentNewLibraryPanel() }
                .help(Loc.string("Make an empty library in a folder you choose (⇧⌘N)"))

            // Still disabled here, and visible anyway: it is the reason most
            // people will open this app at all, and hiding it would make them
            // wonder whether Shelf can do it (CONCEPT §7).
            //
            // The import itself has worked since Sprint 3; what it needs is a
            // library to import *into*, and there is none on this screen. The
            // help text said "Arrives in Sprint 3" for three sprints after it
            // had. It now says what to do instead, which is the one thing a
            // disabled button owes the person looking at it.
            SlateSecondaryButton(Loc.string("Import from Calibre…")) {}
                .disabled(true)
                .help(
                    Loc.string(
                        "Make or open a library first, then Library ▸ Import from Calibre…. The "
                            + "Calibre folder itself is only ever read."))

            SlateDropZone(title: Loc.string("Drop a library folder here"), isTargeted: isDropTargeted)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    FolderDrop.handle(providers, into: model)
                }

            SlateShortcutLine(ShortcutReference.essentials.map(\.slate))

            if !model.recents.entries.isEmpty { recentList }
        }
        .onAppear { model.recents.refreshAvailability() }
    }

    private var recentList: some View {
        SlateRecentList(title: Loc.string("Recent Libraries")) {
            ForEach(model.recents.entries) { entry in
                RecentLibraryRow(entry: entry, isReachable: model.recents.isReachable(entry))
            }
        }
    }
}

/// One row in the recent list: name, how many books were in it, and the path.
struct RecentLibraryRow: View {
    @Environment(LibraryModel.self) private var model
    let entry: RecentLibrary
    let isReachable: Bool

    var body: some View {
        SlateRecentRow(
            name: entry.name, detail: summary, path: entry.path, isReachable: isReachable,
            help: isReachable
                ? entry.path : Loc.string("%@ — not available right now", entry.path)
        ) {
            model.open(recent: entry)
        }
    }

    private var summary: String? {
        guard let count = entry.bookCount else { return nil }
        return Loc.count("%lld books", count)
    }
}

/// Dropping works on the welcome screen and on the whole window, so the
/// handling lives in one place.
enum FolderDrop {
    static func handle(_ providers: [NSItemProvider], into model: LibraryModel) -> Bool {
        guard !providers.isEmpty else { return false }
        // Collected before being handed over, so a drop of eight hundred files
        // is one import with one counting protocol rather than eight hundred.
        let collector = URLCollector(expecting: providers.count) { urls in
            Task { @MainActor in model.handleDrop(urls) }
        }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                collector.add(url)
            }
        }
        return true
    }
}

/// Gathers the URLs of one drop, which arrive one callback at a time and off
/// the main thread, and reports them once when they are all in.
private final class URLCollector: @unchecked Sendable {
    private let expected: Int
    private let finished: ([URL]) -> Void
    private let lock = NSLock()
    private var urls: [URL] = []
    private var seen = 0

    init(expecting expected: Int, finished: @escaping ([URL]) -> Void) {
        self.expected = expected
        self.finished = finished
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        seen += 1
        let done = seen >= expected
        let collected = urls
        lock.unlock()
        if done { finished(collected) }
    }
}
