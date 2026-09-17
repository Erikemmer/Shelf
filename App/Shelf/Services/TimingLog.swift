import Foundation
import ShelfCore
import os

/// Measures the one thing no command-line run can measure: how long it takes
/// until every cover the user can actually *see* is on screen.
///
/// `make proof` measures when the process settles and how fast the cache fills.
/// Neither is the number CONCEPT §11 asks for ("warm cache under 2 s"), because
/// both keep counting long after the first screenful is complete. This counts
/// the cells the grid has actually laid out and stops when the last of them has
/// its cover.
///
/// **Silent unless `SHELF_TIMING=1` is in the environment.** A measurement that
/// prints during normal use is a measurement nobody leaves switched on, and a
/// log line per cell would be exactly the kind of work that changes what is
/// being measured.
///
/// Deliberately *not* `@Observable` and read by no view. Cell appearance
/// driving observable state is the feedback loop that made warming twenty
/// times slower in Sprint 1 (ADR 0005): warm → progress → invalidate → cell
/// appears → "interaction" → warming pauses. Nothing here is observed, so
/// nothing here can close that loop again.
@MainActor
final class TimingLog {
    static let shared = TimingLog()

    /// Read once. The environment cannot change under a running process, and a
    /// dictionary lookup per cell is exactly the overhead this must not add.
    static let isEnabled = ProcessInfo.processInfo.environment["SHELF_TIMING"] == "1"

    /// How long after the last cover the run counts as finished.
    ///
    /// The grid lays its cells out over several frames, so the pending set
    /// empties and fills again a few times before the screenful is really
    /// complete. Reporting on the first empty moment would report the first
    /// row, not the first screen.
    private static let settleDelay = Duration.milliseconds(250)

    private static let logger = Logger(subsystem: "de.erikemmer.shelf", category: "timing")

    /// When the process was ready to draw. Set by `ShelfApp` rather than taken
    /// here lazily, so it is the app's start and not the first cell's.
    private var launchedAt = ContinuousClock.now
    private var openedAt: ContinuousClock.Instant?
    private var libraryName = ""

    /// Cells the grid has laid out whose cover has not settled yet.
    private var pending: Set<UUID> = []
    /// Cells seen in this run at all – the "how many covers" in the report.
    private var seen: Set<UUID> = []
    private var hasReported = false
    private var settleTask: Task<Void, Never>?

    private init() {}

    /// Called once, as early as the app can call anything.
    func noteLaunch() {
        guard Self.isEnabled else { return }
        launchedAt = ContinuousClock.now
        emit("launch")
    }

    /// The user asked for a library. The clock for "cold / warm open" starts here.
    func libraryOpenBegan(_ name: String) {
        guard Self.isEnabled else { return }
        settleTask?.cancel()
        openedAt = ContinuousClock.now
        libraryName = name
        pending = []
        seen = []
        hasReported = false
        emit("open began: \(name)")
    }

    /// The index is read and the grid has something to lay out.
    func entriesReady(_ count: Int) {
        guard Self.isEnabled, let openedAt else { return }
        emit("index read: \(count) books, \(Self.milliseconds(since: openedAt)) ms after the open began")
    }

    /// A grid cell exists and has started asking for its cover.
    func cellAppeared(_ id: UUID) {
        guard Self.isEnabled, openedAt != nil, !hasReported else { return }
        settleTask?.cancel()
        settleTask = nil
        seen.insert(id)
        pending.insert(id)
    }

    /// A grid cell has its cover – or has established that there is none.
    /// Both count: an empty placeholder the user is looking at is finished too.
    func coverSettled(_ id: UUID) {
        guard Self.isEnabled, openedAt != nil, !hasReported else { return }
        pending.remove(id)
        guard pending.isEmpty else { return }
        scheduleReport()
    }

    /// Waits out `settleDelay` before believing the screenful is complete.
    private func scheduleReport() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.report()
        }
    }

    private func report() {
        guard let openedAt, !hasReported, pending.isEmpty, !seen.isEmpty else { return }
        hasReported = true
        emit(
            "visible covers complete: \(seen.count) cells, "
                + "\(Self.milliseconds(since: openedAt)) ms after the open began, "
                + "\(Self.milliseconds(since: launchedAt)) ms after launch "
                + "(\(libraryName))")
    }

    private static func milliseconds(since instant: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - instant) / .milliseconds(1))
    }

    /// Both channels on purpose: `os.Logger` survives a run nobody captured,
    /// and the unbuffered write makes `open --stdout <file>` enough to read the
    /// numbers back. `print` would be block-buffered into a file and the last
    /// line – the one that matters – would still be in the buffer at quit.
    private func emit(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        FileHandle.standardOutput.write(Data("shelf-timing: \(message)\n".utf8))
    }
}
