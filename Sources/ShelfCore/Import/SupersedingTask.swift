import Foundation

/// Holds the one unit of work that is allowed to be running, so that
/// `cancel()` has a real `Task` to cancel and a newer run cancels an older one.
///
/// Two things the model's own wiring got wrong once and that are pinned here:
/// the work is an unstructured `Task`, which does not inherit the caller's
/// cancellation, so `run` forwards it with a cancellation handler (a sheet
/// that goes away must stop the examination it started); and a superseded run
/// keeps going until it next looks, so the body itself has to check
/// `Task.isCancelled` after every `await` it makes before it assigns state.
@MainActor
public final class SupersedingTask {
    private var current: Task<Void, Never>?

    public init() {}

    /// Cancels whatever runs now, starts `body` as the new run and waits for it.
    public func run(_ body: @escaping @MainActor () async -> Void) async {
        current?.cancel()
        let work = Task { await body() }
        current = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Cancels the run, if there is one.
    public func cancel() {
        current?.cancel()
        current = nil
    }
}
