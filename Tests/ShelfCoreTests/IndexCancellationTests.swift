import Foundation
import Testing

@testable import ShelfCore

/// The mechanism behind two real bugs (`docs/BACKLOG.md`, `CHANGELOG.md`
/// Sprint 14, Teil A): `LibraryModel.reload()` and `ImportRunner.run()`'s
/// own batch saves, both in the app/import layer, are not unit-testable on
/// their own at the exact call site — there is no app-side test target yet,
/// and `ImportRunner`'s own cancellation test uses an in-memory
/// `BatchCollector` that never checks cancellation at all. What is testable
/// here, at the root, is the GRDB behaviour that made an entirely healthy
/// index look unreadable, or a routine Cancel look like a failed import: an
/// async read *or write* cooperatively checks `Task.isCancelled` and throws
/// `CancellationError` *before touching the database at all*, whenever the
/// surrounding `Task` was cancelled for a reason that has nothing to do with
/// the index itself — and a `Task.detached`, which starts uncancelled
/// regardless of what cancelled its caller, is what both fixes rely on to
/// escape that.
@Suite("A read after the surrounding task is cancelled")
struct IndexCancellationTests {

    private func entry(title: String) -> LibraryEntry {
        let book = Book(title: title, authors: ["An Author"])
        return LibraryEntry(
            book: book, number: 1, folder: "An Author/\(title) (1)",
            formats: [
                BookFormat(
                    bookID: book.id, format: .epub, fileName: "\(title).epub", byteSize: 1_000,
                    sha256: "digest")
            ])
    }

    /// The root cause, reproduced directly: a perfectly healthy index,
    /// asked to read from within an already-cancelled `Task`, throws
    /// `CancellationError` — indistinguishable, to a generic `catch`, from a
    /// real read failure. This is exactly what turned a cancelled import
    /// into a false "Could not read the library index" banner.
    @Test("throws CancellationError, even though the index itself is fine")
    func readInsideCancelledTaskThrows() async throws {
        let index = try LibraryIndex(inMemory: "cancel-throws")
        try await index.save(entry(title: "A Book"))

        // Deterministic, not timing-dependent: the task cannot reach the
        // read until this test lets it, and `task.cancel()` is called
        // before that gate ever opens — so the read is guaranteed to run
        // already cancelled, not merely usually.
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let task = Task<[LibraryEntry], Error> {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return try await index.allEntries()
        }

        task.cancel()
        continuation.yield()
        continuation.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    /// The fix, proved at the same level the bug lives at: reading through a
    /// `Task.detached`, exactly what `LibraryModel.runImport()` now does
    /// before calling `reload()`, is unaffected by the outer task's
    /// cancellation — a detached task starts uncancelled regardless of what
    /// cancelled its caller. The index reads back cleanly.
    @Test("a detached task reads cleanly despite the outer task's cancellation")
    func detachedReadIgnoresOuterCancellation() async throws {
        let index = try LibraryIndex(inMemory: "cancel-detached")
        try await index.save(entry(title: "A Book"))

        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let task = Task<[LibraryEntry], Never> {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            return (try? await Task.detached { try await index.allEntries() }.value) ?? []
        }

        task.cancel()
        continuation.yield()
        continuation.finish()

        let entries = await task.value
        #expect(entries.map(\.book.title) == ["A Book"])
    }

    /// The write-side twin of `readInsideCancelledTaskThrows`, and the exact
    /// mechanism `ImportRunner.run()`'s own batch saves ran into: a
    /// perfectly healthy write, from within an already-cancelled `Task`,
    /// throws `CancellationError` before the row ever lands. Before this
    /// sprint only the *last, short* batch was guarded against it
    /// (`CHANGELOG.md`, Sprint 13, Teil C, Bug 3) — the *regular*, mid-loop
    /// batch that fires every `ImportRunner.indexBatchSize` books had the
    /// same unguarded `try await saveBatch(unsaved)`, and a Cancel landing
    /// exactly at that boundary let the error escape `run()` itself.
    @Test("a write inside a cancelled task throws CancellationError before it lands")
    func writeInsideCancelledTaskThrows() async throws {
        let index = try LibraryIndex(inMemory: "cancel-write-throws")

        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let task = Task<Void, Error> {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            try await index.save(entry(title: "A Book"))
        }

        task.cancel()
        continuation.yield()
        continuation.finish()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let saved = try await index.allEntries()
        #expect(saved.isEmpty)
    }

    /// The fix for both call sites, proved once at the root: a write through
    /// a `Task.detached`, exactly what `ImportRunner.run()` now does at
    /// *every* `saveBatch` call rather than only the last one, lands
    /// regardless of the outer task's cancellation.
    @Test("a detached task writes cleanly despite the outer task's cancellation")
    func detachedWriteIgnoresOuterCancellation() async throws {
        let index = try LibraryIndex(inMemory: "cancel-write-detached")
        let written = entry(title: "A Book")

        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let task = Task<Void, Never> {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
            try? await Task.detached { try await index.save(written) }.value
        }

        task.cancel()
        continuation.yield()
        continuation.finish()

        await task.value
        let saved = try await index.allEntries()
        #expect(saved.map(\.book.title) == ["A Book"])
    }
}
