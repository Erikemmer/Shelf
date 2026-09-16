import Foundation

/// How urgently a cover is needed. The cover loader uses this to decide which
/// request starts first and which one has to wait.
///
/// The rule behind the order: a book the user just clicked on must never queue
/// behind work nobody is waiting for. Copied from Selector, where it was worked
/// out against real measurements – see `docs/adr/0004-cover-pipeline.md` and
/// Selector's ADR 0003.
public enum LoadPriority: Int, Comparable, CaseIterable, Sendable {
    /// Someone is looking at a blank tile right now (the selected book, the
    /// cover in the inspector).
    case interactive = 2
    /// Likely needed within the next key press or scroll tick: the ring of
    /// covers around the selection.
    case neighbour = 1
    /// Nobody is waiting: the warmer filling the cache for the whole library.
    case background = 0

    public static func < (lhs: LoadPriority, rhs: LoadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Quality of service for the task that does the decoding.
    ///
    /// Background work deliberately stays at `.utility` rather than
    /// `.background`: the system throttles `.background` so hard that warming a
    /// library of thousands of books would take many minutes. What keeps clicks
    /// fast is the gate, not a lower QoS.
    public var taskPriority: TaskPriority {
        switch self {
        case .interactive: return .userInitiated
        case .neighbour: return .utility
        case .background: return .utility
        }
    }

    /// Whether a request of this priority makes the warmer stand still while it runs.
    public var pausesBackgroundWork: Bool { self == .interactive }

    /// Whether work of this priority may start while `pending` is being loaded.
    ///
    /// Only background work yields; neighbour prefetches are cheap enough to
    /// keep running, and they are what makes the next arrow key instant.
    public static func mayStart(_ priority: LoadPriority, whilePending pending: [LoadPriority]) -> Bool {
        guard priority == .background else { return true }
        return !pending.contains { $0.pausesBackgroundWork }
    }
}
