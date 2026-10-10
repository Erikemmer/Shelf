import Foundation
import Testing

@testable import ShelfCore

/// The mechanism behind `ImportModel.cancel()`: cancelling the awaiting task
/// must be visible inside the detached work, which a bare `Task.detached`
/// does not do.
@Suite("Cancellable detached work")
struct CancellableDetachedTests {

    /// Counts how far a polling loop got; the loop stops once it sees the
    /// cancellation.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("cancelling the caller stops the loop early")
    func cancellationReachesTheWork() async {
        let started = Counter()
        let steps = Counter()
        let task = Task {
            await CancellableDetached.run {
                _ = started.bump()
                for _ in 0..<10_000 {
                    if Task.isCancelled { return true }
                    _ = steps.bump()
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return false
            }
        }
        while started.current == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        let sawCancel = await task.value
        #expect(sawCancel)
        #expect(steps.current < 10_000)
    }

    @Test("without a cancellation the work runs to its end")
    func runsToTheEnd() async {
        let result = await CancellableDetached.run { (1...100).reduce(0, +) }
        #expect(result == 5050)
    }

    @Test("a plain detached task, for contrast, never sees the caller's cancellation")
    func plainDetachedDoesNotSeeIt() async {
        let task = Task { () -> Bool in
            await Task.detached {
                try? await Task.sleep(for: .milliseconds(100))
                return Task.isCancelled
            }.value
        }
        task.cancel()
        #expect(await task.value == false)
    }
}
