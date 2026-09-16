import Foundation

/// Whether the user is working the window right now.
///
/// Background warming has to stand still while someone scrolls the grid or
/// holds an arrow key – a decode cannot be called back once it has started, so
/// the only lever is not starting one. Single events are not enough to decide
/// that: a scroll is a burst of dozens of them. So every event opens a quiet
/// period, and the window stays "active" until nothing has happened for that
/// long. Copied from Selector.
public struct InteractionWindow: Equatable, Sendable {
    /// How long after the last event the window counts as quiet again.
    ///
    /// Long enough to bridge the gaps inside a gesture (a trackpad scroll
    /// reports every few milliseconds, key repeat runs at ~30 ms), short enough
    /// that warming resumes as soon as the user pauses to look at a book.
    public static let quietPeriod: TimeInterval = 0.25

    private var lastEvent: Date?

    public init() {}

    public mutating func note(at now: Date = Date()) {
        lastEvent = now
    }

    public func isActive(at now: Date = Date()) -> Bool {
        remainingQuietTime(at: now) != nil
    }

    /// How long until the window falls quiet, or `nil` if it already is.
    /// Callers wait exactly this long instead of polling.
    public func remainingQuietTime(at now: Date = Date()) -> TimeInterval? {
        guard let lastEvent else { return nil }
        let elapsed = now.timeIntervalSince(lastEvent)
        guard elapsed < Self.quietPeriod else { return nil }
        // A clock that jumped backwards must not produce a wait longer than the
        // quiet period itself.
        return min(Self.quietPeriod, Self.quietPeriod - elapsed)
    }
}

/// What counts as working the window. Listed so the call sites can be found and
/// so nobody has to guess whether a new gesture belongs in here.
public enum InteractionSource: String, CaseIterable, Sendable {
    /// Scrolling the cover grid or the table.
    case scroll
    /// Stepping through books, in particular a held arrow key.
    case selection
    /// Dragging the cover-size slider, or ⌘± .
    case resize
    /// Typing in the search field, which re-queries the index on every keystroke.
    case search
}
