import Foundation

/// One library the user had open before.
public struct RecentLibrary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }

    public var path: String
    public var name: String
    /// A sandboxed app loses the right to read a folder when it quits, so a
    /// plain path would be useless on the next launch. The bookmark is what
    /// makes "Recent" work at all; the path is only for display.
    public var bookmark: Data?
    public var bookCount: Int?
    public var lastOpened: Date

    public init(path: String, name: String, bookmark: Data?, bookCount: Int?, lastOpened: Date) {
        self.path = path
        self.name = name
        self.bookmark = bookmark
        self.bookCount = bookCount
        self.lastOpened = lastOpened
    }

    /// Corrects the count of a library already in the list, without touching
    /// its position, bookmark or `lastOpened`: an import changes how many
    /// books a library holds, not when it was last opened. A path that is not
    /// in the list is ignored, so a closing library cannot re-add itself.
    /// Returns whether anything changed, so the caller saves only then. It
    /// lives here, not in the app's store, so that it can be tested.
    @discardableResult
    public static func updateBookCount(in list: inout [RecentLibrary], path: String, to count: Int) -> Bool {
        guard let row = list.firstIndex(where: { $0.path == path }), list[row].bookCount != count
        else { return false }
        list[row].bookCount = count
        return true
    }
}
