import Foundation
import Testing

@testable import ShelfCore

/// What a request that never got an answer throws.
///
/// **Not `URLError`.** That type lives in `FoundationNetworking` on Linux, which
/// `ShelfCore` does not import and must not need — the core builds on Linux and
/// the tests run there. A struct of three lines costs nothing and keeps the
/// test target as portable as the target it tests.
struct NoAnswer: Error, LocalizedError {
    var errorDescription: String? { "the request did not get an answer" }
}

/// A transport that answers from a script instead of from a socket.
///
/// This is the seam the whole online feature is testable through: everything
/// above it — which URL, how often, what a 503 means, whether this was asked
/// before — is here in the core, and only the socket is in the app.
actor ScriptedTransport: MetadataTransport {
    struct Answer: Sendable {
        var status: Int
        var body: Data
        /// The request never got an answer at all.
        var silent: Bool = false
    }

    private var answers: [Answer]
    private(set) var asked: [URL] = []
    private(set) var askedAt: [ContinuousClock.Instant] = []

    init(_ answers: [Answer]) { self.answers = answers }

    func fetch(_ url: URL, userAgent: String, timeout: Duration) async throws -> (Data: Data, status: Int) {
        asked.append(url)
        askedAt.append(ContinuousClock.now)
        let answer = answers.isEmpty ? Answer(status: 200, body: Data("{}".utf8)) : answers.removeFirst()
        if answer.silent { throw NoAnswer() }
        return (answer.body, answer.status)
    }
}

@Suite("Asking the services, and behaving while doing it")
struct MetadataFetcherTests {
    private func fixture(_ name: String) throws -> Data { try OnlineFixture.data(name) }

    private func quick(
        _ answers: [ScriptedTransport.Answer], cache: ResponseCache? = nil
    ) -> (
        MetadataFetcher, ScriptedTransport
    ) {
        let transport = ScriptedTransport(answers)
        // A tenth of the shipped second, so the tests are quick and the pacing
        // is still the thing being measured.
        let policy = NetworkPolicy(
            userAgent: NetworkPolicy.standard.userAgent, minimumInterval: .milliseconds(100),
            timeout: .seconds(1), maximumAttempts: 3)
        return (MetadataFetcher(transport: transport, cache: cache, policy: policy), transport)
    }

    @Test("both services are asked about one book, and their candidates come back as one list")
    func bothServices() async throws {
        let (fetcher, transport) = quick([
            .init(status: 200, body: try fixture("openlibrary-isbn-9780132350884.json")),
            .init(status: 200, body: try fixture("googlebooks-volume-reconstructed.json")),
        ])
        let result = await fetcher.candidates(for: .isbn("9780132350884"))

        #expect(await transport.asked.count == 2)
        #expect(result.problems.isEmpty)
        #expect(Set(result.candidates.map(\.source)) == [.openLibrary, .googleBooks])
        // Both repeat the ISBN back, so both score 100 and the tie is broken by
        // the order the services are declared in — the list is the same list on
        // every run, which is what makes a candidate list something a person can
        // point at.
        #expect(result.ranked.map(\.score) == [100, 100])
        #expect(result.ranked.first?.candidate.source == .openLibrary)
    }

    /// The finding of the Sprint 6 proof run, as a test: Google Books answered
    /// **429 to all ten ISBNs** — the shared anonymous quota, exhausted before
    /// Shelf asked anything. The window must survive that quietly and still
    /// show what the other service knows (CONCEPT §9).
    @Test("a service that refuses still leaves the other service's answer")
    func oneServiceRefuses() async throws {
        let (fetcher, _) = quick([
            .init(status: 200, body: try fixture("openlibrary-isbn-9780441013593.json")),
            .init(status: 429, body: try fixture("googlebooks-quota-exceeded-429.json")),
        ])
        let result = await fetcher.candidates(for: .isbn("9780441013593"))

        #expect(result.candidates.count == 1)
        #expect(result.candidates.first?.source == .openLibrary)
        #expect(result.problems.count == 1)
        #expect(result.statusLine?.contains("429") == true)
        #expect(result.statusLine?.contains("Google Books") == true)
        #expect(result.failedSources == [.googleBooks])
        // One failure is said in full: the sentence is short and it is useful.
        #expect(result.briefProblem(result.failedSources) == result.statusLine)
    }

    /// A 429 is the service saying "stop". The answer to being told to stop is
    /// to stop — one request, not three.
    @Test("a refusal is not repeated")
    func noRetryForARefusal() async throws {
        let (fetcher, transport) = quick([
            .init(status: 429, body: Data("{}".utf8)),
            .init(status: 404, body: Data("{}".utf8)),
        ])
        _ = await fetcher.candidates(for: .isbn("9780441013593"))
        #expect(await transport.asked.count == 2, "one request per service, and neither repeated")
    }

    @Test("a 5xx is tried again, and the second answer counts")
    func retryForAServerError() async throws {
        let (fetcher, transport) = quick([
            .init(status: 503, body: Data()),
            .init(status: 200, body: try fixture("openlibrary-isbn-9780441013593.json")),
            .init(status: 404, body: Data("{}".utf8)),
        ])
        let result = await fetcher.candidates(for: .isbn("9780441013593"))
        #expect(await transport.asked.count == 3)
        #expect(result.candidates.count == 1)
    }

    /// The three "timeouts" in the first proof run all answered in under three
    /// seconds when asked again. A request that never got an answer is retried
    /// for the same reason a 503 is: nothing was said, so nothing was refused.
    @Test("a request that got no answer at all is tried again")
    func retryForNoAnswer() async throws {
        let (fetcher, transport) = quick([
            .init(status: 0, body: Data(), silent: true),
            .init(status: 200, body: try fixture("openlibrary-isbn-9780441013593.json")),
            .init(status: 404, body: Data("{}".utf8)),
        ])
        let result = await fetcher.candidates(for: .isbn("9780441013593"))
        #expect(await transport.asked.count == 3)
        #expect(result.candidates.count == 1)
    }

    @Test("a service that never answers gives up after three tries, with a sentence")
    func givesUp() async throws {
        let (fetcher, transport) = quick([
            .init(status: 0, body: Data(), silent: true),
            .init(status: 0, body: Data(), silent: true),
            .init(status: 0, body: Data(), silent: true),
            .init(status: 404, body: Data("{}".utf8)),
        ])
        let result = await fetcher.candidates(for: .isbn("9780441013593"))
        #expect(await transport.asked.count == 4)
        #expect(result.problems.count == 2)
        #expect(result.isEmpty)
        // Two are named rather than recited: both sentences together came to
        // 130 characters and the sidebar showed "…could not be foun…".
        #expect(result.briefProblem(result.failedSources) == "Open Library and Google Books did not answer.")
    }

    /// Two free services with no API key are two people's servers paying for
    /// Shelf's curiosity. One request per second each, and counted per service
    /// because a second between Shelf and Open Library says nothing about Shelf
    /// and Google.
    @Test("two questions to one service are spaced apart")
    func pacing() async throws {
        let (fetcher, transport) = quick([
            .init(status: 404, body: Data("{}".utf8)), .init(status: 404, body: Data("{}".utf8)),
            .init(status: 404, body: Data("{}".utf8)), .init(status: 404, body: Data("{}".utf8)),
        ])
        _ = await fetcher.candidates(for: .isbn("9780441013593"))
        _ = await fetcher.candidates(for: .isbn("9780132350884"))

        let times = await transport.askedAt
        #expect(times.count == 4)
        // The two Open Library requests are the first and the third.
        #expect(times[2] - times[0] >= .milliseconds(100))
        #expect(times[3] - times[1] >= .milliseconds(100))
    }

    @Test("an answer already on disk is not asked for again")
    func theCacheAnswers() async throws {
        let folder = try TemporaryFolder()
        let cache = ResponseCache(folder: folder.url)
        let body = try fixture("openlibrary-isbn-9780441013593.json")

        let (first, transport) = quick(
            [.init(status: 200, body: body), .init(status: 404, body: Data("{}".utf8))], cache: cache)
        _ = await first.candidates(for: .isbn("9780441013593"))
        #expect(await transport.asked.count == 2)

        let (second, again) = quick(
            [.init(status: 200, body: body), .init(status: 404, body: Data("{}".utf8))], cache: cache)
        let result = await second.candidates(for: .isbn("9780441013593"))
        // Open Library's answer came off the disk; Google's 404 was never
        // stored, so that one is asked again.
        #expect(await again.asked.count == 1)
        #expect(result.candidates.count == 1)
        #expect(await second.cacheHits == 1)
    }
}

@Suite("Manners towards somebody else's server")
struct NetworkPolicyTests {
    @Test("only a server error is worth asking again about")
    func whatIsRetried() {
        let policy = NetworkPolicy.standard
        #expect(policy.shouldRetry(status: 500))
        #expect(policy.shouldRetry(status: 503))
        #expect(!policy.shouldRetry(status: 429), "a 429 is an instruction, not a hiccup")
        #expect(!policy.shouldRetry(status: 404))
        #expect(!policy.shouldRetry(status: 200))
    }

    @Test("the wait between tries widens")
    func backoff() {
        let policy = NetworkPolicy.standard
        #expect(policy.backoff(afterAttempt: 1) == .seconds(1))
        #expect(policy.backoff(afterAttempt: 2) == .seconds(2))
        #expect(policy.backoff(afterAttempt: 3) == .seconds(4))
    }

    /// The only thing that leaves this Mac is the ISBN or the title being
    /// looked up. The User-Agent says who is asking and nothing about whom it
    /// is asking for.
    @Test("the user agent names the project and nothing about the person")
    func userAgent() {
        let agent = NetworkPolicy.standard.userAgent
        #expect(agent.hasPrefix("Shelf/"))
        #expect(agent.contains("github.com/Erikemmer/Shelf"))
        #expect(!agent.contains("@"))
    }
}

@Suite("The answers kept on disk")
struct ResponseCacheTests {
    @Test("what was written comes back, and what was never written does not")
    func roundTrip() async throws {
        let folder = try TemporaryFolder()
        let cache = ResponseCache(folder: folder.url)
        await cache.write(Data("{\"docs\":[]}".utf8), for: "openlibrary-abc")

        #expect(await cache.read("openlibrary-abc") == Data("{\"docs\":[]}".utf8))
        #expect(await cache.read("openlibrary-nothing") == nil)
        #expect(await cache.size() > 0)
    }

    @Test("an answer older than the cache allows is not used")
    func staleAnswers() async throws {
        let folder = try TemporaryFolder()
        let cache = ResponseCache(folder: folder.url, maximumAge: 0)
        await cache.write(Data("{}".utf8), for: "openlibrary-abc")
        #expect(await cache.read("openlibrary-abc") == nil)
    }

    @Test("clearing removes the answers and leaves the folder")
    func clearing() async throws {
        let folder = try TemporaryFolder()
        let cache = ResponseCache(folder: folder.url)
        await cache.write(Data("{}".utf8), for: "openlibrary-abc")
        await cache.clear()

        #expect(await cache.read("openlibrary-abc") == nil)
        #expect(FileManager.default.fileExists(atPath: folder.url.path))
    }

    /// A cache that cannot be written is not an error: the lookup worked, and
    /// the only cost is asking again next time.
    @Test("a folder that cannot be made costs nothing")
    func unwritable() async throws {
        let cache = ResponseCache(folder: URL(fileURLWithPath: "/dev/null/nowhere"))
        await cache.write(Data("{}".utf8), for: "x")
        #expect(await cache.read("x") == nil)
    }
}

@Suite("A cover fetched from the net")
struct OnlineCoverTests {
    /// The smallest legal PNG the fixtures can make — the magic number is what
    /// is being checked, not the picture.
    private var png: Data { MinimalPNG.cover(width: 8, height: 12, seed: 3) }

    @Test("a cover is written beside the book, named from its own bytes")
    func writesBesideTheBook() throws {
        let folder = try TemporaryFolder()
        #expect(OnlineCover.isWanted(in: folder.url))

        let written = try OnlineCover.write(png, into: folder.url)
        #expect(written.lastPathComponent == "cover.png")
        #expect(!OnlineCover.isWanted(in: folder.url))
        // And nothing else was left lying about.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names == ["cover.png"])
    }

    @Test("a cover that is already there is not written over")
    func neverOverACover() throws {
        let folder = try TemporaryFolder()
        try OnlineCover.write(png, into: folder.url)
        #expect(throws: OnlineCover.Refusal.coverAlreadyThere("cover.png")) {
            try OnlineCover.write(png, into: folder.url)
        }
    }

    /// A service that answers an error page with a 200 would otherwise leave a
    /// file called `cover.jpg` holding the words "Not Found", and every later
    /// decode would fail on it without saying why.
    @Test("what is not an image is not written at all")
    func notAnImage() throws {
        let folder = try TemporaryFolder()
        #expect(throws: OnlineCover.Refusal.notAnImage) {
            try OnlineCover.write(Data("<html>Not Found</html>".utf8), into: folder.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
    }
}
