import Foundation
import Testing

@testable import ShelfCore

/// The wiring `ImportModel.examine()` stands on. `ImportModel` itself lives in
/// the app target, which has no tests; what can be pinned here is the helper.
@MainActor
@Suite("Superseding task")
struct SupersedingTaskTests {

    /// Suspends until `release()`; resumes at most once.
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            open = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("cancel() cancels the run and the late result sees it")
    func cancelReachesTheBody() async {
        let slot = SupersedingTask()
        let gate = Gate()
        let started = Gate()
        var sawCancel: Bool?
        let caller = Task { @MainActor in
            await slot.run {
                started.release()
                await gate.wait()  // stands in for a non-cancellable index call
                sawCancel = Task.isCancelled
            }
        }
        await started.wait()
        slot.cancel()
        gate.release()
        await caller.value
        #expect(sawCancel == true)
    }

    @Test("a newer run cancels the older one, which must not look current")
    func newerSupersedesOlder() async {
        let slot = SupersedingTask()
        let gate = Gate()
        let started = Gate()
        var olderCancelled: Bool?
        var newerCancelled: Bool?
        let older = Task { @MainActor in
            await slot.run {
                started.release()
                await gate.wait()
                olderCancelled = Task.isCancelled
            }
        }
        await started.wait()
        await slot.run { newerCancelled = Task.isCancelled }
        gate.release()
        await older.value
        #expect(olderCancelled == true)
        #expect(newerCancelled == false)
    }

    @Test("cancelling the caller of run() cancels the run it started")
    func callerCancellationIsForwarded() async {
        let slot = SupersedingTask()
        let gate = Gate()
        let started = Gate()
        var sawCancel: Bool?
        let caller = Task { @MainActor in
            await slot.run {
                started.release()
                await gate.wait()
                sawCancel = Task.isCancelled
            }
        }
        await started.wait()
        caller.cancel()  // the sheet went away; nobody calls slot.cancel()
        gate.release()
        await caller.value
        #expect(sawCancel == true)
    }

    @Test("an uncancelled run completes normally")
    func runsToTheEnd() async {
        let slot = SupersedingTask()
        var ran = false
        await slot.run { ran = !Task.isCancelled }
        #expect(ran)
    }
}
