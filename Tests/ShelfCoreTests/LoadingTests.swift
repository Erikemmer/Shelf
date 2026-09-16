import Foundation
import Testing

@testable import ShelfCore

/// The cover pipeline's rules. Copied from Selector, where they were worked out
/// against measurements, and tested here again because a copy that drifts is
/// worse than no copy at all.
@Suite("The cover pipeline's rules")
struct LoadingTests {

    // MARK: LoadPriority

    @Test("a click outranks a neighbour prefetch, which outranks the warmer")
    func priorityOrder() {
        #expect(LoadPriority.interactive > .neighbour)
        #expect(LoadPriority.neighbour > .background)
        #expect(LoadPriority.allCases.max() == .interactive)
    }

    /// The system throttles `.background` so hard that warming a library of
    /// thousands would take many minutes. What keeps clicks fast is the gate,
    /// not a lower QoS.
    @Test("only interactive work maps to userInitiated, and nothing to background")
    func taskPriorities() {
        #expect(LoadPriority.interactive.taskPriority == .userInitiated)
        #expect(LoadPriority.neighbour.taskPriority == .utility)
        #expect(LoadPriority.background.taskPriority == .utility)
    }

    @Test("the warmer waits for a click, but a neighbour prefetch does not")
    func backgroundYieldsToClicks() {
        #expect(!LoadPriority.mayStart(.background, whilePending: [.interactive]))
        #expect(!LoadPriority.mayStart(.background, whilePending: [.neighbour, .interactive]))
        #expect(LoadPriority.mayStart(.background, whilePending: [.neighbour]))
        #expect(LoadPriority.mayStart(.background, whilePending: []))
        // Interactive and neighbour requests never wait for anything.
        #expect(LoadPriority.mayStart(.interactive, whilePending: [.interactive]))
        #expect(LoadPriority.mayStart(.neighbour, whilePending: [.interactive]))
    }

    // MARK: WarmOrder
    //
    // A strict run from book 1 would leave someone who jumps to the end waiting
    // for everything before it.

    @Test("warming starts at the selection and spreads outwards")
    func warmOrder() {
        #expect(WarmOrder.indices(around: 5, count: 10, radius: 2) == [5, 6, 4, 7, 3])
        #expect(WarmOrder.indices(around: 0, count: 3) == [0, 1, 2])
        #expect(WarmOrder.indices(around: 2, count: 3) == [2, 1, 0])
    }

    @Test("every book is reached when no radius is given")
    func warmOrderCoversEverything() {
        let order = WarmOrder.indices(around: 500, count: 1_000)
        #expect(order.count == 1_000)
        #expect(Set(order).count == 1_000)
        #expect(order.first == 500)
    }

    /// A selection a filter just hid must still produce a sane order rather
    /// than crashing on an out-of-range index.
    @Test("an out-of-range centre is clamped")
    func warmOrderClamps() {
        #expect(WarmOrder.indices(around: 99, count: 3) == [2, 1, 0])
        #expect(WarmOrder.indices(around: -5, count: 3) == [0, 1, 2])
        #expect(WarmOrder.indices(around: 0, count: 0).isEmpty)
    }

    @Test("the window leans forward, two thirds ahead")
    func window() {
        let window = WarmOrder.window(around: 50, count: 100, size: 10)
        #expect(window.first == 50)
        #expect(window.count == 10)
        let ahead = window.filter { $0 > 50 }.count
        #expect(ahead == 6)
    }

    /// Near the ends the window does not shrink – the share that does not fit
    /// moves to the other side, so the budget stays used.
    @Test("at the start of the library the window does not shrink, it shifts")
    func windowAtTheEdges() {
        #expect(WarmOrder.window(around: 0, count: 100, size: 10).count == 10)
        #expect(WarmOrder.window(around: 99, count: 100, size: 10).count == 10)
        // A library smaller than the window is simply all of it.
        #expect(WarmOrder.window(around: 1, count: 3, size: 10).count == 3)
        #expect(WarmOrder.window(around: 0, count: 0, size: 10).isEmpty)
        #expect(WarmOrder.window(around: 0, count: 10, size: 0).isEmpty)
    }

    // MARK: InteractionWindow
    //
    // A scroll is a burst of dozens of events, so a single event cannot decide
    // whether the user is working the window.

    @Test("the window stays active for a quarter of a second after the last event")
    func interactionWindow() {
        var window = InteractionWindow()
        let now = Date()
        #expect(!window.isActive(at: now))

        window.note(at: now)
        #expect(window.isActive(at: now))
        #expect(window.isActive(at: now.addingTimeInterval(0.2)))
        #expect(!window.isActive(at: now.addingTimeInterval(0.3)))
    }

    @Test("the caller is told exactly how long to wait rather than polling")
    func remainingQuietTime() {
        var window = InteractionWindow()
        let now = Date()
        window.note(at: now)
        guard let remaining = window.remainingQuietTime(at: now.addingTimeInterval(0.1)) else {
            Issue.record("the window should still be active")
            return
        }
        #expect(abs(remaining - 0.15) < 0.001)
        #expect(window.remainingQuietTime(at: now.addingTimeInterval(1)) == nil)
    }

    /// A clock that jumped backwards must not produce a wait longer than the
    /// quiet period itself.
    @Test("a clock that went backwards cannot stall the warmer indefinitely")
    func clockWentBackwards() {
        var window = InteractionWindow()
        let now = Date()
        window.note(at: now)
        guard let remaining = window.remainingQuietTime(at: now.addingTimeInterval(-60)) else {
            Issue.record("the window should be active")
            return
        }
        #expect(remaining <= InteractionWindow.quietPeriod)
    }

    @Test("what counts as working the window is listed, not guessed at")
    func interactionSources() {
        #expect(InteractionSource.allCases.count == 4)
        #expect(InteractionSource.allCases.map(\.rawValue).allSatisfy { !$0.isEmpty })
    }

    // MARK: DecodeGate

    @Test("the gate never runs more than its limit at once")
    func gateLimit() async {
        let gate = DecodeGate(limit: 2)
        await gate.acquire(.interactive)
        await gate.acquire(.interactive)
        #expect(await gate.waitingCount == 0)

        // A third has to wait; started in its own task so this test does not.
        let waiting = Task { await gate.acquire(.interactive) }
        while await gate.waitingCount == 0 {
            await Task.yield()
        }
        #expect(await gate.waitingCount == 1)

        await gate.release(.interactive)
        await waiting.value
        await gate.release(.interactive)
        await gate.release(.interactive)
    }

    /// A decode cannot be called back once started, so not starting one is the
    /// only lever there is.
    @Test("warming stands still while the user is working the window")
    func gatePausesWarmingWhileInteracting() async {
        let gate = DecodeGate(limit: 4)
        await gate.setInteracting(true)

        let waiting = Task { await gate.acquire(.background) }
        while await gate.waitingCount == 0 {
            await Task.yield()
        }
        #expect(await gate.waitingCount == 1)

        await gate.setInteracting(false)
        await waiting.value
        await gate.release(.background)
    }

    @Test("warming may hold only half the slots, so the window keeps cores")
    func gateBackgroundLimit() async {
        let gate = DecodeGate(limit: 4, backgroundLimit: 2)
        await gate.acquire(.background)
        await gate.acquire(.background)

        let waiting = Task { await gate.acquire(.background) }
        while await gate.waitingCount == 0 {
            await Task.yield()
        }
        #expect(await gate.waitingCount == 1)

        // An interactive request is not held back by the background limit.
        await gate.acquire(.interactive)
        await gate.release(.interactive)

        await gate.release(.background)
        await waiting.value
        await gate.release(.background)
        await gate.release(.background)
    }

    @Test("the most urgent waiter goes first")
    func gatePrefersUrgentWork() async {
        let gate = DecodeGate(limit: 1)
        await gate.acquire(.interactive)

        let order = OrderRecorder()
        let low = Task {
            await gate.acquire(.neighbour)
            await order.record("neighbour")
        }
        let high = Task {
            await gate.acquire(.interactive)
            await order.record("interactive")
        }
        while await gate.waitingCount < 2 {
            await Task.yield()
        }

        await gate.release(.interactive)
        await high.value
        await gate.release(.interactive)
        await low.value
        await gate.release(.neighbour)

        #expect(await order.first == "interactive")
    }

    @Test("a limit below one is still one, so the gate cannot deadlock")
    func gateMinimumLimit() async {
        let gate = DecodeGate(limit: 0)
        await gate.acquire(.interactive)
        await gate.release(.interactive)
    }

    /// Records which task got through first, without a shared mutable variable.
    private actor OrderRecorder {
        private var names: [String] = []
        func record(_ name: String) { names.append(name) }
        var first: String? { names.first }
    }
}

/// The disk cache's key and its eviction rule. The key is the whole of the
/// correctness argument: serving yesterday's picture for today's book is the one
/// failure a cache must never have.
@Suite("The cover cache")
struct CoverCacheTests {

    /// Unlike Selector, which keys on a file's path, size and date, a cover
    /// belongs to the *book* – it outlives any one of the book's files.
    @Test("the key is the book, the size asked for, and a generation")
    func key() {
        let id = UUID()
        let key = CoverCacheKey(bookID: id, pixelWidth: 400)
        #expect(key.fingerprint == "v1\n\(id.uuidString)\n400\n0")
        #expect(key != CoverCacheKey(bookID: id, pixelWidth: 1_000))
        #expect(key != CoverCacheKey(bookID: UUID(), pixelWidth: 400))
    }

    /// The generation is what replaces size-and-date: an edited cover misses
    /// instead of matching something stale.
    @Test("a new generation is a different key, so a replaced cover misses")
    func generation() {
        let id = UUID()
        #expect(
            CoverCacheKey(bookID: id, pixelWidth: 400, generation: 0)
                != CoverCacheKey(bookID: id, pixelWidth: 400, generation: 1))
    }

    /// A changed fingerprint means every cached cover on every machine misses
    /// at once, so it is written out rather than composed from `hashValue`.
    @Test("the fingerprint is spelled out, not derived from Swift's hashing")
    func fingerprintIsStable() {
        guard let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555") else {
            Issue.record("bad test UUID")
            return
        }
        #expect(
            CoverCacheKey(bookID: id, pixelWidth: 400, generation: 2).fingerprint
                == "v1\n11111111-2222-3333-4444-555555555555\n400\n2")
    }

    /// When one book's cover goes wrong, finding its file in the Finder is
    /// worth more than four saved characters.
    @Test("the file name carries the book's UUID in plain sight")
    func fileName() {
        guard let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555") else {
            Issue.record("bad test UUID")
            return
        }
        let name = CoverCacheKey(bookID: id, pixelWidth: 400).fileName(
            hashedBy: PortableSHA256Hasher(), extension: "img")
        #expect(name.hasPrefix("11111111-2222-3333-4444-555555555555-400-"))
        #expect(name.hasSuffix(".img"))
    }

    /// A cache with a file per slider position would decode the whole library
    /// again every time the slider moved.
    @Test("there are two sizes, and the cell's width picks one")
    func sizes() {
        #expect(CoverSize.allCases.count == 2)
        #expect(CoverSize.forCell(points: 120) == .grid)
        #expect(CoverSize.forCell(points: 200) == .grid)
        #expect(CoverSize.forCell(points: 300) == .large)
        // A non-retina display needs fewer pixels for the same cell.
        #expect(CoverSize.forCell(points: 300, scale: 1) == .grid)
    }

    @Test("nothing is evicted below the limit")
    func noEvictionBelowTheLimit() {
        let entries = [
            CoverCachePolicy.Entry(fileName: "a", byteSize: 100, lastUsed: Date()),
            CoverCachePolicy.Entry(fileName: "b", byteSize: 100, lastUsed: Date()),
        ]
        #expect(CoverCachePolicy.evictions(from: entries, limitBytes: 1_000).isEmpty)
    }

    /// A cache that trims itself to half whenever it is full spends the next
    /// session rebuilding what it just threw away.
    @Test("eviction goes oldest first and stops at the limit")
    func eviction() {
        let now = Date()
        let entries = [
            CoverCachePolicy.Entry(fileName: "newest", byteSize: 400, lastUsed: now),
            CoverCachePolicy.Entry(fileName: "oldest", byteSize: 400, lastUsed: now.addingTimeInterval(-200)),
            CoverCachePolicy.Entry(fileName: "middle", byteSize: 400, lastUsed: now.addingTimeInterval(-100)),
        ]
        let doomed = CoverCachePolicy.evictions(from: entries, limitBytes: 1_000)
        #expect(doomed.map(\.fileName) == ["oldest"])
    }

    @Test("two runs over the same folder make the same decision")
    func evictionIsDeterministic() {
        let sameTime = Date()
        let entries = [
            CoverCachePolicy.Entry(fileName: "b", byteSize: 600, lastUsed: sameTime),
            CoverCachePolicy.Entry(fileName: "a", byteSize: 600, lastUsed: sameTime),
        ]
        #expect(CoverCachePolicy.evictions(from: entries, limitBytes: 1_000).map(\.fileName) == ["a"])
    }

    /// Clearing the cache should be a decision with a number behind it rather
    /// than a button that does something vague.
    @Test("the size label names both numbers")
    func sizeLabel() {
        #expect(CoverCachePolicy.sizeLabel(usedBytes: 0) == "0 B of 1.0 GB")
        #expect(CoverCachePolicy.sizeLabel(usedBytes: 500 * 1_024 * 1_024).contains("500.0 MB of"))
    }
}

/// SHA-256 is what "verified" means, so it is checked against the standard's
/// own published digests – not only against itself.
@Suite("SHA-256")
struct HashingTests {

    private func digest(_ text: String) -> String {
        let hasher = PortableSHA256Hasher()
        hasher.update(Data(text.utf8))
        return hasher.finish()
    }

    @Test("the standard's published test vectors")
    func knownVectors() {
        // FIPS 180-4's own examples, and the empty string's digest, which every
        // implementation in the world agrees on.
        #expect(digest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// The padding rule has a special case at 55, 56 and 64 bytes – exactly
    /// where the length no longer fits in the final block.
    @Test("inputs at the block boundary are padded correctly")
    func blockBoundaries() {
        #expect(
            digest(String(repeating: "a", count: 55))
                == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        #expect(
            digest(String(repeating: "a", count: 56))
                == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        #expect(
            digest(String(repeating: "a", count: 64))
                == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    /// The importer feeds a file in 4 MB chunks, so the chunked path is the one
    /// that actually runs.
    @Test("the digest is the same however the bytes are handed over")
    func chunking() {
        let whole = PortableSHA256Hasher()
        whole.update(Data(String(repeating: "shelf", count: 10_000).utf8))

        let chunked = PortableSHA256Hasher()
        for _ in 0..<10_000 { chunked.update(Data("shelf".utf8)) }

        #expect(whole.finish() == chunked.finish())
    }

    @Test("finishing twice gives the same answer rather than a corrupted one")
    func finishIsIdempotent() {
        let hasher = PortableSHA256Hasher()
        hasher.update(Data("abc".utf8))
        let first = hasher.finish()
        #expect(hasher.finish() == first)
        // Bytes offered after finishing are ignored, not silently mixed in.
        hasher.update(Data("more".utf8))
        #expect(hasher.finish() == first)
    }

    @Test("a file's digest matches the digest of its bytes")
    func fileDigest() throws {
        let folder = try TemporaryFolder()
        let payload = Data((0..<100_000).map { UInt8($0 % 256) })
        let url = try folder.write("file.bin", data: payload)

        let direct = PortableSHA256Hasher()
        direct.update(payload)
        #expect(try FileDigest.sha256(of: url, makeHasher: PortableSHA256Hasher.factory) == direct.finish())
    }

    @Test("a file that cannot be read names itself rather than returning a wrong digest")
    func unreadableFile() {
        #expect(throws: FileDigest.Failure.cannotRead("nothing.epub")) {
            try FileDigest.sha256(
                of: URL(fileURLWithPath: "/nonexistent/nothing.epub"),
                makeHasher: PortableSHA256Hasher.factory)
        }
    }

    @Test("an empty file has the empty digest, not an error")
    func emptyFile() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("empty.bin", data: Data())
        #expect(
            try FileDigest.sha256(of: url, makeHasher: PortableSHA256Hasher.factory)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
