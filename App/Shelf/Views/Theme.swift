import ShelfCore
import SlateKit
import SwiftUI

/// What is Shelf's own about the way it looks.
///
/// The palette and the shared components live in `SlateKit` (`Slate.accent`,
/// `Slate.panelBackground`, …), because Shelf and Selector are meant to look
/// like siblings rather than two apps that happen to be dark. What stays here
/// is the part that only makes sense with books in front of you: how wide the
/// three areas of the window are, and which symbol stands for what.
enum Theme {
    // The same widths as Selector's, from CONCEPT §3.2: the grid in the middle
    // is what should grow with the window.
    static let sidebarWidth: CGFloat = 220
    static let inspectorWidth: CGFloat = 280

    /// A cover is taller than it is wide. 2:3 is the shape of a paperback and
    /// of nearly every cover image, so a cell of that ratio leaves almost no
    /// empty space.
    static let coverAspectRatio: CGFloat = 2.0 / 3.0

    /// The symbol for one of the sidebar's sections.
    static func icon(for group: SidebarSection) -> String {
        switch group {
        case .shelves: return "books.vertical.fill"
        case .tags: return "number"
        case .authors: return "person"
        case .series: return "list.number"
        case .formats: return "doc"
        case .devices: return "cable.connector"
        }
    }

    /// The colour a DRM badge is drawn in. Not red: a protected file is not an
    /// error, it is a fact about the file (CONCEPT §6).
    static let drmBadge = Slate.textSecondary
}

/// The sidebar's sections, in the order CONCEPT §3.2 gives them.
enum SidebarSection: String, CaseIterable, Identifiable {
    case shelves = "Shelves"
    case tags = "Tags"
    case authors = "Authors"
    case series = "Series"
    case formats = "Formats"
    case devices = "Devices"

    var id: String { rawValue }

    /// Whether Sprint 1 can fill this section. The empty ones are still drawn,
    /// because a sidebar that grows section by section between versions is
    /// harder to learn than one whose shape is fixed from the start.
    var isFilledInSprintOne: Bool {
        switch self {
        case .tags, .authors, .series, .formats: return true
        case .shelves, .devices: return false
        }
    }

    /// What an empty section says about itself, so a blank space is never
    /// unexplained.
    var emptyNote: String {
        switch self {
        case .shelves: return "Shelves arrive in Sprint 2c"
        case .devices: return "Devices arrive in Sprint 5"
        case .tags: return "No tags yet"
        case .authors: return "No authors yet"
        case .series: return "No series yet"
        case .formats: return "No formats yet"
        }
    }
}

extension Shortcut {
    /// The package draws shortcuts; the table of them is Shelf's.
    var slate: SlateShortcut {
        SlateShortcut(keys: keys, action: action, group: group.rawValue)
    }
}
