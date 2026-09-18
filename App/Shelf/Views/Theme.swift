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

/// The badge that says a file is protected.
///
/// Not red, and not an alert symbol: a protected file is not an error and not a
/// problem Shelf is asking the user to fix. It is a fact about the file, and
/// the reason its metadata may be thin. Shelf recognises it, says so, and does
/// nothing else — never removes it, never works around it (CONCEPT §12,
/// ADR 0012).
struct DRMBadge: View {
    let drm: DRMKind

    init(_ drm: DRMKind) { self.drm = drm }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 8))
            Text(drm.label).font(.caption2)
        }
        .foregroundStyle(Theme.drmBadge)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Slate.textSecondary.opacity(0.14))
        )
        .accessibilityLabel(Loc.string("%@, not touched", Loc.core(drm.label)))
        .help(
            Loc.string("%@. Shelf shows it and leaves the file exactly as it is.", Loc.core(drm.label)))
    }
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

    /// What the sidebar writes above the section.
    ///
    /// Not the raw value: a raw value has to be a literal, and it is also the
    /// identity this section is stored and compared by. Translating it would
    /// have made a German window and an English one disagree about which
    /// section is which.
    var title: String {
        switch self {
        case .shelves: return Loc.string("Shelves")
        case .tags: return Loc.string("Tags")
        case .authors: return Loc.string("Authors")
        case .series: return Loc.contextual("Series [a sidebar section]", english: "Series")
        case .formats: return Loc.string("Formats")
        case .devices: return Loc.string("Devices")
        }
    }

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
        case .shelves: return Loc.string("No shelves yet — use + to make one")
        case .devices: return Loc.string("No reader connected — plug one in over USB")
        case .tags: return Loc.string("No tags yet")
        case .authors: return Loc.string("No authors yet")
        case .series: return Loc.string("No series yet")
        case .formats: return Loc.string("No formats yet")
        }
    }
}

extension Shortcut {
    /// The package draws shortcuts; the table of them is Shelf's.
    ///
    /// The keys are not translated — ⌘F is ⌘F in every language — and the
    /// action and the group are, because they are sentences (ADR 0016).
    var slate: SlateShortcut {
        SlateShortcut(keys: keys, action: Loc.core(action), group: Loc.core(group.title))
    }
}

extension ShortcutGroup {
    /// What the ⌘? sheet writes above the group. Not the raw value: that is
    /// the identity, and it is also what `library.json` would hold if a group
    /// were ever saved.
    var title: String { rawValue }
}
