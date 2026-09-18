import Foundation

/// How Shelf behaves towards somebody else's server.
///
/// Two free services with no API key are two services paying for Shelf's
/// curiosity out of their own pocket, so the manners are a rule with a test
/// rather than a habit (CONCEPT §9).
///
/// - a **User-Agent that says who is asking**, so an operator seeing the
///   traffic can find out what it is. It carries the project and its version
///   and **nothing about the person**: no library name, no book title, no
///   identifier of any kind. The only thing that leaves this Mac is the ISBN or
///   the title being looked up.
/// - **at most one request per second per service**, counted per service
///   because they are two different people's servers.
/// - **a retry only for 5xx**, with a widening wait. A 404 is an answer and a
///   429 is an instruction; repeating either is rude and gains nothing.
/// - **a time limit**, so a service that has stopped answering costs a line in
///   the status bar rather than a spinning window.
public struct NetworkPolicy: Equatable, Sendable {
    public var userAgent: String
    public var minimumInterval: Duration
    public var timeout: Duration
    public var maximumAttempts: Int

    public static let standard = NetworkPolicy(
        // The version is the app's marketing version; the URL is what an
        // operator would follow. Nothing here identifies the person running it.
        userAgent: "Shelf/0.1.0 (eBook manager; +https://github.com/Erikemmer/Shelf)",
        minimumInterval: .seconds(1),
        timeout: .seconds(15),
        maximumAttempts: 3)

    public init(userAgent: String, minimumInterval: Duration, timeout: Duration, maximumAttempts: Int) {
        self.userAgent = userAgent
        self.minimumInterval = minimumInterval
        self.timeout = timeout
        self.maximumAttempts = maximumAttempts
    }

    /// Whether a status is worth asking again about.
    ///
    /// 5xx only. A 429 is the service saying "stop", and the answer to being
    /// told to stop is to stop — the pacing above is what keeps Shelf from
    /// being told it in the first place.
    public func shouldRetry(status: Int) -> Bool { (500...599).contains(status) }

    /// 1 s, 2 s, 4 s. Counted from one, so `backoff(afterAttempt: 1)` is the
    /// wait before the second try.
    public func backoff(afterAttempt attempt: Int) -> Duration {
        .seconds(1 << max(0, min(attempt - 1, 4)))
    }
}

/// What one request came back as.
public enum MetadataOutcome: Equatable, Sendable {
    case answered(Data)
    /// The status the service gave, after every retry the policy allowed.
    case refused(status: Int)
    case failed(String)
}

/// Making one HTTP request, and nothing else.
///
/// The seam between the core and the app. Everything above it — which URL, how
/// often, what a 503 means, whether this was asked before, what the answer
/// means — is a rule and is tested here without a network. Below it is
/// `URLSession`, which lives in `App/Shelf` (docs/ARCHITECTURE.md).
public protocol MetadataTransport: Sendable {
    /// Returns the body and the HTTP status. Throwing means the request never
    /// got an answer at all.
    func fetch(_ url: URL, userAgent: String, timeout: Duration) async throws -> (Data: Data, status: Int)
}

/// The whole of a lookup except the socket: ask the cache, pace, retry, parse.
///
/// An actor because the pacing is shared state — two books looked up at once
/// must not become two requests in the same second.
public actor MetadataFetcher {
    private let transport: any MetadataTransport
    private let cache: ResponseCache?
    private let policy: NetworkPolicy
    /// Per service, because a second between Shelf and Open Library says
    /// nothing about Shelf and Google.
    private var lastRequest: [MetadataSource: ContinuousClock.Instant] = [:]

    /// Counted for the proof run and for the report, never sent anywhere.
    public private(set) var requestsMade = 0
    public private(set) var cacheHits = 0

    public init(transport: any MetadataTransport, cache: ResponseCache? = nil, policy: NetworkPolicy = .standard) {
        self.transport = transport
        self.cache = cache
        self.policy = policy
    }

    /// Both services, asked about one book.
    ///
    /// A service that fails does not stop the other: the result carries what
    /// came back and what did not, and the window shows the failures as a line
    /// in the status bar rather than as a dialogue (CONCEPT §9).
    public func candidates(for query: MetadataQuery) async -> LookupResult {
        var found: [MetadataCandidate] = []
        var problems: [String] = []
        for request in MetadataEndpoint.requests(for: query) {
            switch await answer(to: request) {
            case .answered(let data):
                do {
                    found += try parse(data, from: request.source, answering: query)
                } catch let failure as MetadataReadFailure {
                    problems.append(failure.message)
                } catch {
                    problems.append("\(request.source.name) answered something unreadable.")
                }
            case .refused(let status):
                problems.append("\(request.source.name) answered \(status).")
            case .failed(let why):
                problems.append("\(request.source.name): \(why)")
            }
        }
        return LookupResult(
            query: query,
            ranked: MetadataScore.ranked(found, for: query),
            problems: problems)
    }

    func parse(
        _ data: Data, from source: MetadataSource, answering query: MetadataQuery
    ) throws -> [MetadataCandidate] {
        switch source {
        case .openLibrary: return try OpenLibraryReader.candidates(from: data, answering: query)
        case .googleBooks: return try GoogleBooksReader.candidates(from: data)
        }
    }

    /// One request: the cache first, then the network, with the pacing and the
    /// retries the policy allows.
    func answer(to request: MetadataRequest) async -> MetadataOutcome {
        if let cache, let stored = await cache.read(request.cacheKey) {
            cacheHits += 1
            return .answered(stored)
        }
        var attempt = 1
        while true {
            await pace(request.source)
            do {
                requestsMade += 1
                let (data, status) = try await transport.fetch(
                    request.url, userAgent: policy.userAgent, timeout: policy.timeout)
                if (200...299).contains(status) {
                    if let cache { await cache.write(data, for: request.cacheKey) }
                    return .answered(data)
                }
                guard policy.shouldRetry(status: status), attempt < policy.maximumAttempts else {
                    return .refused(status: status)
                }
                try? await Task.sleep(for: policy.backoff(afterAttempt: attempt))
                attempt += 1
            } catch {
                guard attempt < policy.maximumAttempts else {
                    return .failed(Self.describe(error))
                }
                try? await Task.sleep(for: policy.backoff(afterAttempt: attempt))
                attempt += 1
            }
        }
    }

    /// Waits until this service may be asked again.
    private func pace(_ source: MetadataSource) async {
        if let last = lastRequest[source] {
            let waited = ContinuousClock.now - last
            if waited < policy.minimumInterval {
                try? await Task.sleep(for: policy.minimumInterval - waited)
            }
        }
        lastRequest[source] = ContinuousClock.now
    }

    /// A network error in words rather than in a domain and a number. The
    /// status bar shows this, so "the network is not reachable" is the useful
    /// half and `NSURLErrorDomain -1009` is not.
    static func describe(_ error: any Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.isEmpty ? "the request did not get an answer" : text
    }
}

/// What a lookup came back with: the candidates in order, and what went wrong.
public struct LookupResult: Equatable, Sendable {
    public var query: MetadataQuery
    public var ranked: [(candidate: MetadataCandidate, score: Int)]
    /// One line per service that could not answer. Never empty *and* fatal:
    /// one service failing still leaves the other's candidates.
    public var problems: [String]

    public var candidates: [MetadataCandidate] { ranked.map(\.candidate) }
    public var isEmpty: Bool { ranked.isEmpty }

    public init(query: MetadataQuery, ranked: [(candidate: MetadataCandidate, score: Int)], problems: [String]) {
        self.query = query
        self.ranked = ranked
        self.problems = problems
    }

    public static func == (left: LookupResult, right: LookupResult) -> Bool {
        left.query == right.query && left.problems == right.problems
            && left.ranked.map(\.candidate) == right.ranked.map(\.candidate)
            && left.ranked.map(\.score) == right.ranked.map(\.score)
    }

    /// The one line the status bar shows, or nothing.
    public var statusLine: String? {
        guard !problems.isEmpty else { return nil }
        return problems.joined(separator: " ")
    }
}
