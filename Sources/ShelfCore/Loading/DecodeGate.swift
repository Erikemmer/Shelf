import Foundation

/// Limits how many covers decode at the same time and decides which request
/// goes next.
///
/// An image decode cannot be cancelled once it has started, so the only lever
/// we have is *what starts*. Two rules do the work: never more than `limit`
/// decodes at once (otherwise opening a library makes the whole Mac sluggish),
/// and the most urgent waiting request goes first. Background warming stands
/// still while someone is waiting for a cover – see `LoadPriority.mayStart`.
///
/// Copied from Selector rather than shared: the two apps decode different
/// things, and a change that suits books must not reach into a photo app.
public actor DecodeGate {
    private let limit: Int
    /// How many of the slots background warming may hold. Leaving cores free
    /// keeps the window responsive while a library warms up.
    private let backgroundLimit: Int
    private var running = 0
    private var runningBackground = 0
    /// True while the user is doing something continuous – scrolling the grid,
    /// holding an arrow key. Warming stands still then: a decode cannot be
    /// called back once started, so the only way not to compete for the CPU is
    /// not to start.
    private var isInteracting = false
    /// Priorities acquired but not yet released, waiting ones included – this is
    /// what "a click is in flight" means for the warmer.
    private var outstanding: [LoadPriority] = []
    private var waiting: [(priority: LoadPriority, resume: CheckedContinuation<Void, Never>)] = []

    public init(limit: Int, backgroundLimit: Int? = nil) {
        self.limit = max(limit, 1)
        self.backgroundLimit = max(1, min(backgroundLimit ?? max(1, limit / 2), self.limit))
    }

    /// Tells the gate that the user is (or is no longer) working the window.
    /// Called on scroll and selection changes; the caller clears it again once
    /// things are quiet.
    public func setInteracting(_ interacting: Bool) {
        guard isInteracting != interacting else { return }
        isInteracting = interacting
        if !interacting { startNextWaiter() }
    }

    /// How many requests are queued. Exposed so tests can wait for a known
    /// state instead of sleeping and hoping.
    var waitingCount: Int { waiting.count }

    /// Waits until a decoding slot is free. Every `acquire` needs exactly one
    /// `release` with the same priority.
    public func acquire(_ priority: LoadPriority) async {
        outstanding.append(priority)
        if canStart(priority) {
            occupySlot(priority)
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append((priority, continuation))
        }
    }

    public func release(_ priority: LoadPriority) {
        running -= 1
        if priority == .background { runningBackground -= 1 }
        if let index = outstanding.firstIndex(of: priority) { outstanding.remove(at: index) }
        startNextWaiter()
    }

    private func occupySlot(_ priority: LoadPriority) {
        running += 1
        if priority == .background { runningBackground += 1 }
    }

    private func canStart(_ priority: LoadPriority) -> Bool {
        guard running < limit, LoadPriority.mayStart(priority, whilePending: outstanding) else { return false }
        guard priority == .background else { return true }
        return !isInteracting && runningBackground < backgroundLimit
    }

    /// Hands the free slot to the most urgent waiter; among equals the one that
    /// has waited longest, so nothing starves.
    private func startNextWaiter() {
        guard running < limit else { return }
        var next: Int?
        for (index, entry) in waiting.enumerated() where canStart(entry.priority) {
            if let best = next, waiting[best].priority >= entry.priority { continue }
            next = index
        }
        guard let index = next else { return }
        let entry = waiting.remove(at: index)
        occupySlot(entry.priority)
        entry.resume.resume()
    }
}
