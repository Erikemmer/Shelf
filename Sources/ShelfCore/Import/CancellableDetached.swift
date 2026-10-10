import Foundation

/// Runs slow, synchronous work off the calling actor **and** lets a
/// cancellation of the caller reach it.
///
/// A plain `Task.detached { … }.value` starts uncancelled and stays that way
/// whatever happens to the task awaiting it, so a caller's `cancel()` never
/// got to the loop inside. That is what made `ImportModel.cancel()` a no-op
/// for the examining phase (`docs/BACKLOG.md`). The cancellation handler
/// forwards it; the work polls `Task.isCancelled` itself.
public enum CancellableDetached {
    public static func run<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        let inner = Task.detached(priority: priority) { work() }
        return await withTaskCancellationHandler {
            await inner.value
        } onCancel: {
            inner.cancel()
        }
    }
}
