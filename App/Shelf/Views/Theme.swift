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
        case .publishers: return "building.columns"
        case .formats: return "doc"
        case .devices: return "cable.connector"
        }
    }

    /// The colour a DRM badge is drawn in. Not red: a protected file is not an
    /// error, it is a fact about the file (CONCEPT §6).
    ///
    /// `textPrimary` since Sprint 7, and not because it should shout. The badge
    /// sits on a plate of its own — `textSecondary` at 14 % over the panel — and
    /// secondary text on that plate read at **3.96:1**, under WCAG AA's 4.5:1
    /// for normal text. Found by `Scripts/check-contrast.py`. The plate is what
    /// makes it quiet; the word on it has to be readable.
    static let drmBadge = Slate.textPrimary
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
        // The padlock and the word are one fact, and the padlock's own SF
        // Symbol name is not part of it.
        .accessibilityElement(children: .ignore)
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
    case publishers = "Publishers"
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
        case .publishers: return Loc.string("Publishers")
        case .formats: return Loc.string("Formats")
        case .devices: return Loc.string("Devices")
        }
    }

    /// Whether Sprint 1 can fill this section. The empty ones are still drawn,
    /// because a sidebar that grows section by section between versions is
    /// harder to learn than one whose shape is fixed from the start.
    var isFilledInSprintOne: Bool {
        switch self {
        case .tags, .authors, .series, .publishers, .formats: return true
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
        case .publishers: return Loc.string("No publishers yet")
        case .formats: return Loc.string("No formats yet")
        }
    }
}

extension Shortcut {
    /// The package draws shortcuts; the table of them is Shelf's.
    ///
    /// The keys are not translated — ⌘F is ⌘F in every language — and the
    /// label and the group are, because they are sentences (ADR 0016).
    var slate: SlateShortcut {
        SlateShortcut(keys: keys, action: Loc.core(label), group: Loc.core(group.title))
    }
}

extension ShortcutKey {
    /// The core's chord as SwiftUI's. The one place the two vocabularies meet:
    /// `ShortcutKey` lives in `ShelfCore`, which has no SwiftUI and builds on
    /// Linux, and `KeyboardShortcut` is what a menu item takes.
    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(equivalent, modifiers: swiftUIModifiers)
    }

    private var equivalent: KeyEquivalent {
        switch key {
        case .character(let character): return KeyEquivalent(character)
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .home: return .home
        case .end: return .end
        case .newline: return .return
        case .space: return .space
        }
    }

    private var swiftUIModifiers: EventModifiers {
        var found: EventModifiers = []
        if modifiers.contains(.command) { found.insert(.command) }
        if modifiers.contains(.shift) { found.insert(.shift) }
        if modifiers.contains(.option) { found.insert(.option) }
        if modifiers.contains(.control) { found.insert(.control) }
        return found
    }
}

extension View {
    /// The key this action is answered by, out of the one table.
    ///
    /// `nil` where the window answers the key itself, and `.keyboardShortcut`
    /// takes an optional — so a menu item that must *not* carry a key equivalent
    /// says so by being in the table with no `menuKey`, rather than by somebody
    /// remembering not to write one (ADR 0006, ADR 0017).
    func shortcut(_ id: ShortcutAction) -> some View {
        keyboardShortcut(ShortcutReference.find(id)?.menuKey?.keyboardShortcut)
    }
}

extension ShortcutGroup {
    /// What the ⌘? sheet writes above the group. Not the raw value: that is
    /// the identity, and it is also what `library.json` would hold if a group
    /// were ever saved.
    var title: String { rawValue }
}
