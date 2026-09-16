import AppKit
import Foundation
import Observation
import ShelfCore

/// Fills the cover caches in the background, in rings around the selection.
///
/// Two things make this work at 8 000 books rather than 300 photos:
/// the grid-size cover is small enough that *every* book can keep one, and the
/// disk cache means the second open of a library reads HEIC files instead of
/// decoding JPEGs. The ring order is what makes the first open feel instant
/// anyway – the covers the user can actually see are warmed first.
///
/// It runs at `.background`, so it stands still while a cover somebody is
/// looking at is being decoded, and it stops entirely while the window is being
/// worked (`InteractionWindow`).
@MainActor
@Observable
final class CoverWarmer {
    /// Fast scrolling must not restart the whole run on every frame.
    private static let settleDelay = Duration.milliseconds(300)

    /// Two at a time. A cover decode is a few milliseconds at 400 px, so a
    /// little parallelism finishes a library noticeably sooner without crowding
    /// the machine; `DecodeGate`'s background limit (half the slots) is the
    /// ceiling above this.
    private static let parallelism = 2

    /// How often the progress is published.
    ///
    /// Not per cover. `progress` is observed by the sidebar's footer, so every
    /// update is a view invalidation – and at 8 000 books that is 8 000 of them
    /// for a run that should be a few seconds. It was also half of a feedback
    /// loop that made warming twenty times slower than it should be (ADR 0005).
    /// Every 25 covers is often enough that the footer looks alive.
    private static let progressEvery = 25

    /// What the status bar shows while a library warms up; nil when done.
    private(set) var progress: Progress?

    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int

        var label: String { "Building covers · \(done) of \(total)" }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Which books have been warmed in this run, so a new selection restarts
    /// the *order* without redoing the work.
    @ObservationIgnored private var warmed: Set<UUID> = []

    /// Restarts warming around `index`. Cheap to call on every selection change.
    func warm(_ entries: [LibraryEntry], around index: Int, using loader: CoverLoader) {
        task?.cancel()
        guard !entries.isEmpty else {
            progress = nil
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            await self?.run(entries, around: index, using: loader)
        }
    }

    /// Forgets what has been warmed – for a new library, or after the cache was
    /// cleared.
    func reset() {
        task?.cancel()
        warmed = []
        progress = nil
    }

    private func run(_ entries: [LibraryEntry], around index: Int, using loader: CoverLoader) async {
        let order = WarmOrder.indices(around: index, count: entries.count)
            .map { entries[$0] }
            .filter { !warmed.contains($0.id) }
        guard !order.isEmpty else {
            progress = nil
            return
        }

        let total = order.count
        var done = 0
        progress = Progress(done: 0, total: total)

        var next = 0
        await withTaskGroup(of: UUID?.self) { group in
            func addTask() {
                guard next < order.count, !Task.isCancelled else { return }
                let entry = order[next]
                next += 1
                group.addTask {
                    _ = await loader.cover(for: entry, size: .grid, priority: .background)
                    return entry.id
                }
            }
            for _ in 0..<max(1, Self.parallelism) { addTask() }
            while let finished = await group.next() {
                if let finished { warmed.insert(finished) }
                done += 1
                if done % Self.progressEvery == 0 || done == total {
                    progress = Progress(done: done, total: total)
                }
                addTask()
            }
        }
        progress = nil
    }
}
