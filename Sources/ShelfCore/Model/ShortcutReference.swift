import Foundation

/// The keyboard shortcuts, as data.
///
/// One table, read by three places: the menu bar, the welcome screen's one-line
/// summary, and the ⌘? sheet. Three hand-written lists would eventually tell
/// the user three different things – which is exactly what a shortcut reference
/// must never do. The keys come from CONCEPT §3.3.
public struct Shortcut: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(group.rawValue).\(keys)" }

    /// As the user reads it: "⌘F", "1–5, 0", "␣".
    public var keys: String
    public var action: String
    public var group: ShortcutGroup
    /// Whether it is one of the handful worth showing on the welcome screen.
    public var isEssential: Bool

    public init(keys: String, action: String, group: ShortcutGroup, isEssential: Bool = false) {
        self.keys = keys
        self.action = action
        self.group = group
        self.isEssential = isEssential
    }
}

public enum ShortcutGroup: String, CaseIterable, Sendable {
    case library = "Library"
    case navigate = "Navigate"
    case edit = "Edit"
    case view = "View"
    case devices = "Devices"
}

public enum ShortcutReference {
    /// Everything Shelf answers to. Entries whose feature is not in Sprint 1
    /// are listed anyway, because a reference that grows between versions is
    /// harder to learn than one that is whole – the menu item is what is
    /// disabled, not the documentation.
    public static let all: [Shortcut] = [
        // Library
        Shortcut(keys: "⌘O", action: "Open Library…", group: .library, isEssential: true),
        Shortcut(keys: "⇧⌘N", action: "New Library…", group: .library),
        Shortcut(keys: "⌥⌘I", action: "Import from Calibre…", group: .library),
        Shortcut(keys: "⌘I", action: "Add Books…", group: .library, isEssential: true),
        Shortcut(keys: "⇧⌘R", action: "Show in Finder", group: .library),

        // Navigate
        Shortcut(keys: "←→↑↓", action: "Move through the grid", group: .navigate, isEssential: true),
        Shortcut(keys: "⌘F", action: "Search", group: .navigate, isEssential: true),
        Shortcut(keys: "↩", action: "Open in the default app", group: .navigate),
        Shortcut(keys: "␣", action: "Quick Look", group: .navigate),

        // Edit
        Shortcut(keys: "1–5, 0", action: "Rating", group: .edit, isEssential: true),
        Shortcut(keys: "R", action: "Read / unread", group: .edit),
        Shortcut(keys: "T", action: "Edit tags", group: .edit),
        Shortcut(keys: "⌘E", action: "Fetch Metadata…", group: .edit),
        Shortcut(keys: "⌘Z / ⇧⌘Z", action: "Undo / Redo", group: .edit),

        // View
        Shortcut(keys: "⌘1 / ⌘2", action: "Grid / Table", group: .view),
        Shortcut(keys: "⌘+ / ⌘−", action: "Cover size", group: .view),
        Shortcut(keys: "⌘⌥I", action: "Show / hide the Inspector", group: .view),
        Shortcut(keys: "⌘?", action: "This list", group: .view),

        // Devices
        Shortcut(keys: "⇧⌘S", action: "Send to Device", group: .devices),
    ]

    /// The handful worth knowing, for the welcome screen's one line.
    public static var essentials: [Shortcut] {
        all.filter(\.isEssential)
    }

    public static func group(_ group: ShortcutGroup) -> [Shortcut] {
        all.filter { $0.group == group }
    }
}
