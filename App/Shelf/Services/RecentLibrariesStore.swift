import AppKit
import Observation
import ShelfCore

/// One library the user had open before.
struct RecentLibrary: Codable, Equatable, Identifiable, Sendable {
    var id: String { path }

    var path: String
    var name: String
    /// A sandboxed app loses the right to read a folder when it quits, so a
    /// plain path would be useless on the next launch. The bookmark is what
    /// makes "Recent" work at all; the path is only for display.
    var bookmark: Data?
    var bookCount: Int?
    var lastOpened: Date
}

/// Remembers the libraries the user opened, for the welcome screen and
/// File ▸ Open Recent.
///
/// The same shape as Selector's `RecentSessionsStore`, for the same reason:
/// under the sandbox, access has to be started before reading and released when
/// the library changes – macOS grants a limited number of open scopes.
@MainActor
@Observable
final class RecentLibrariesStore {
    private static let defaultsKey = "recentLibraries"
    /// Enough to be useful, few enough that the welcome screen stays a screen.
    private static let limit = 8

    private(set) var entries: [RecentLibrary] = []
    /// Paths whose folder could not be found – shown greyed out, never removed.
    /// A disconnected drive is a normal Tuesday, and a list that silently loses
    /// rows teaches people not to trust it.
    private(set) var unreachablePaths: Set<String> = []

    /// The folder access is currently held for, so it can be released on switch.
    @ObservationIgnored private var accessedFolder: URL?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
            let stored = try? JSONDecoder().decode([RecentLibrary].self, from: data)
        {
            entries = stored
        }
    }

    // MARK: Recording

    func record(_ library: Library, bookCount: Int?) {
        let entry = RecentLibrary(
            path: library.root.path,
            name: library.name,
            bookmark: try? library.root.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil),
            bookCount: bookCount,
            lastOpened: Date())
        entries.removeAll { $0.path == entry.path }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        unreachablePaths.remove(entry.path)
        save()
    }

    func clear() {
        entries = []
        unreachablePaths = []
        save()
    }

    func isReachable(_ entry: RecentLibrary) -> Bool {
        !unreachablePaths.contains(entry.path)
    }

    /// Re-checks which folders are still there. Cheap enough for opening the
    /// welcome screen or the menu, too expensive for every redraw.
    func refreshAvailability() {
        unreachablePaths = Set(entries.filter { resolve($0) == nil }.map(\.path))
    }

    // MARK: Opening

    /// Resolves an entry's bookmark and takes access, ready to be opened.
    /// Returns nil when the folder is gone – the caller marks the entry then.
    func openable(_ entry: RecentLibrary) -> URL? {
        guard let url = resolve(entry) else {
            unreachablePaths.insert(entry.path)
            return nil
        }
        beginAccess(to: url)
        return url
    }

    /// Keeps exactly one security-scoped folder open at a time.
    func beginAccess(to folder: URL) {
        guard accessedFolder != folder else { return }
        if let accessedFolder { accessedFolder.stopAccessingSecurityScopedResource() }
        // Folders picked in the open panel are not security-scoped and return
        // false here; that is fine, access already exists.
        accessedFolder = folder.startAccessingSecurityScopedResource() ? folder : nil
    }

    // MARK: Private

    private func resolve(_ entry: RecentLibrary) -> URL? {
        guard let bookmark = entry.bookmark else {
            return FileManager.default.fileExists(atPath: entry.path)
                ? URL(fileURLWithPath: entry.path) : nil
        }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
        else { return nil }
        return url
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
