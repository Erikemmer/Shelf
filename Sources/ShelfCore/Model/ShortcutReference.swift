import Foundation

/// What one keyboard shortcut is, as a stable name.
///
/// The name rather than the sentence, because the sentence is drawn and
/// translated and the identity must be neither. It is what a menu item asks the
/// table for.
public enum ShortcutAction: String, CaseIterable, Sendable {
    case openLibrary, newLibrary, importFromCalibre, addBooks, showInFinder
    case selectAllBooks, closeLibrary
    case moveThroughTheGrid, firstOrLastBook, search, openInDefaultApp, quickLook
    case rating, readUnread, editTags, fetchMetadata, undoRedo
    case grid, table, largerCovers, smallerCovers, inspector, thisList
    case sendToDevice
}

/// The one chord a menu item can carry.
///
/// Its own small type rather than SwiftUI's `KeyboardShortcut`, because this
/// table lives in `ShelfCore` — which has no SwiftUI, builds on Linux, and is
/// where a test can reach it. The window turns one of these into the real
/// thing in a single place (`Theme.swift`).
public struct ShortcutKey: Equatable, Hashable, Sendable {
    public enum Key: Equatable, Hashable, Sendable {
        case character(Character)
        case leftArrow, rightArrow, upArrow, downArrow, home, end
        case newline, space
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The chord as a person reads it: "⇧⌘N", "⌘O", "↩".
    ///
    /// This is what makes the two halves of an entry checkable against each
    /// other: the table writes the keys as a string because that is what the
    /// ⌘? sheet draws, and writes the chord as data because that is what a
    /// menu item needs. `ShortcutTests` holds one against the other, so an
    /// entry whose two halves say different things cannot be committed.
    public var printed: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += Self.written(character)
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .home: text += "↖"
        case .end: text += "↘"
        case .newline: text += "↩"
        case .space: text += "␣"
        }
        return text
    }

    /// How a character key is *written*, which is not always the character the
    /// menu is given.
    ///
    /// Two of them, both conventions every Mac app follows:
    ///
    /// - **`-` is written `−`**, a minus sign rather than a hyphen. ⌘− next to
    ///   ⌘+ with a hyphen in it reads as a dash.
    /// - **`/` with ⌘ is written `?`.** The key equivalent has to be `/`,
    ///   because that is the character on the key; ? is the same key shifted,
    ///   and declaring ⇧⌘? gives a shortcut nobody's fingers find. Every menu
    ///   in macOS writes it ⌘?. It is also why the ⌘? sheet does not open on a
    ///   posted "?" with ⌘ held — noted in Sprint 7's handoff, and now written
    ///   down where the decision is made.
    static func written(_ character: Character) -> String {
        switch character {
        case "-": return "−"
        case "/": return "?"
        default: return String(character).uppercased()
        }
    }
}

/// The keyboard shortcuts, as data.
///
/// One table, read by three places: **the menu bar**, the welcome screen's
/// one-line summary, and the ⌘? sheet. Three hand-written lists would
/// eventually tell the user three different things – which is exactly what a
/// shortcut reference must never do. The keys come from CONCEPT §3.3.
///
/// Until Sprint 7 the menu bar was not one of the three: it declared its own
/// key equivalents by hand, and the two *had* drifted — ⌘A and ⇧⌘W were in the
/// menus and in no reference the user could read. A menu item now asks this
/// table for both its words and its key (`ShelfApp.menuItem`), so there is
/// nothing left to drift.
public struct Shortcut: Identifiable, Equatable, Hashable, Sendable {
    public var id: ShortcutAction

    /// As the user reads it: "⌘F", "1–5, 0", "␣". Several keys where an action
    /// has several; `menuKey` is the one chord a menu can hold, or nothing.
    public var keys: String
    /// What it does, in English. Translated by the window (ADR 0016).
    public var label: String
    public var group: ShortcutGroup
    /// Whether it is one of the handful worth showing on the welcome screen.
    public var isEssential: Bool

    /// The chord the **menu bar** declares for this action, or `nil` where the
    /// window answers the key itself.
    ///
    /// `nil` is not an omission; it is a decision with two ADRs behind it. A
    /// menu key equivalent is offered the event before the responder chain, so
    /// a bare digit never reaches a text field ("1984" could not be typed into
    /// the search box), and a *held* key spends 58 % of its time inside
    /// AppKit's menu machinery rather than doing the work
    /// ([ADR 0006](../../../docs/adr/0006-editing-keys-are-not-menu-shortcuts.md),
    /// [ADR 0017](../../../docs/adr/0017-the-arrow-keys-leave-the-menu-bar.md)).
    /// So every chord here has ⌘ in it, and every key without one is answered
    /// by `EditingKeyMonitor`.
    public var menuKey: ShortcutKey?

    public init(
        _ id: ShortcutAction, keys: String, label: String, group: ShortcutGroup,
        isEssential: Bool = false, menuKey: ShortcutKey? = nil
    ) {
        self.id = id
        self.keys = keys
        self.label = label
        self.group = group
        self.isEssential = isEssential
        self.menuKey = menuKey
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
    /// Everything Shelf answers to.
    public static let all: [Shortcut] = [
        // Library
        Shortcut(
            .openLibrary, keys: "⌘O", label: "Open Library…", group: .library, isEssential: true,
            menuKey: ShortcutKey(.character("o"), .command)),
        Shortcut(
            .newLibrary, keys: "⇧⌘N", label: "New Library…", group: .library,
            menuKey: ShortcutKey(.character("n"), [.command, .shift])),
        Shortcut(
            .importFromCalibre, keys: "⌥⌘I", label: "Import from Calibre…", group: .library,
            menuKey: ShortcutKey(.character("i"), [.command, .option])),
        Shortcut(
            .addBooks, keys: "⇧⌘I", label: "Add Books…", group: .library, isEssential: true,
            menuKey: ShortcutKey(.character("i"), [.command, .shift])),
        Shortcut(
            .showInFinder, keys: "⇧⌘R", label: "Show in Finder", group: .library,
            menuKey: ShortcutKey(.character("r"), [.command, .shift])),
        Shortcut(
            .selectAllBooks, keys: "⌘A", label: "Select All Books", group: .library,
            menuKey: ShortcutKey(.character("a"), .command)),
        Shortcut(
            .closeLibrary, keys: "⇧⌘W", label: "Close Library", group: .library,
            menuKey: ShortcutKey(.character("w"), [.command, .shift])),

        // Navigate
        Shortcut(
            .moveThroughTheGrid, keys: "←→↑↓", label: "Move through the grid", group: .navigate,
            isEssential: true),
        Shortcut(.firstOrLastBook, keys: "↖ / ↘", label: "First / last book", group: .navigate),
        Shortcut(
            .search, keys: "⌘F", label: "Search", group: .navigate, isEssential: true,
            menuKey: ShortcutKey(.character("f"), .command)),
        Shortcut(
            .openInDefaultApp, keys: "↩", label: "Open in the default app", group: .navigate,
            menuKey: ShortcutKey(.newline)),
        Shortcut(.quickLook, keys: "␣", label: "Quick Look", group: .navigate),

        // Edit
        Shortcut(.rating, keys: "1–5, 0", label: "Rating", group: .edit, isEssential: true),
        Shortcut(.readUnread, keys: "R", label: "Read / unread", group: .edit),
        Shortcut(.editTags, keys: "T", label: "Edit tags", group: .edit),
        Shortcut(
            .fetchMetadata, keys: "⌘E", label: "Fetch Metadata…", group: .edit,
            menuKey: ShortcutKey(.character("e"), .command)),
        Shortcut(.undoRedo, keys: "⌘Z / ⇧⌘Z", label: "Undo / Redo", group: .edit),

        // View
        Shortcut(
            .grid, keys: "⌘1", label: "Grid", group: .view,
            menuKey: ShortcutKey(.character("1"), .command)),
        Shortcut(
            .table, keys: "⌘2", label: "Table", group: .view,
            menuKey: ShortcutKey(.character("2"), .command)),
        Shortcut(
            .largerCovers, keys: "⌘+", label: "Larger Covers", group: .view,
            menuKey: ShortcutKey(.character("+"), .command)),
        Shortcut(
            .smallerCovers, keys: "⌘−", label: "Smaller Covers", group: .view,
            menuKey: ShortcutKey(.character("-"), .command)),
        Shortcut(
            .inspector, keys: "⌘I", label: "Show / hide the Inspector", group: .view,
            menuKey: ShortcutKey(.character("i"), .command)),
        Shortcut(
            .thisList, keys: "⌘?", label: "This list", group: .view,
            menuKey: ShortcutKey(.character("/"), .command)),

        // Devices
        Shortcut(
            .sendToDevice, keys: "⇧⌘S", label: "Send to Device", group: .devices,
            menuKey: ShortcutKey(.character("s"), [.command, .shift])),
    ]

    /// The handful worth knowing, for the welcome screen's one line.
    public static var essentials: [Shortcut] {
        all.filter(\.isEssential)
    }

    public static func group(_ group: ShortcutGroup) -> [Shortcut] {
        all.filter { $0.group == group }
    }

    /// One entry by name. A menu item asks for this and gets both its words and
    /// its key out of the same row.
    public static func find(_ id: ShortcutAction) -> Shortcut? {
        all.first { $0.id == id }
    }
}
