import Foundation
import Testing

@testable import ShelfCore

/// The mechanism behind `ImportModel.cancel()`: cancelling the awaiting task
/// must be visible inside the detached work, which a bare `Task.detached`
/// does not do.
@Suite("Cancellable detached work")
struct CancellableDetachedTests {

    @Test("cancelling the caller reaches the work")
    func cancellationReachesTheWork() async {
        let started = DispatchSemaphore(value: 0)
        let task = Task {
            await CancellableDetached.run { () -> Bool in
                started.signal()
                // Waits for the cancellation, not for a step count; the
                // deadline only keeps a broken helper from hanging the suite.
                let deadline = Date().addingTimeInterval(20)
                while !Task.isCancelled && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return Task.isCancelled
            }
        }
        // Blocks a background thread, not the cooperative pool, until the work
        // has really started.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                started.wait()
                continuation.resume()
            }
        }
        task.cancel()
        #expect(await task.value)
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
