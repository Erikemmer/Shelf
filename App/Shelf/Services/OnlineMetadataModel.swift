import AppKit
import Foundation
import OSLog
import Observation
import ShelfCore

/// The socket, and nothing else.
///
/// Everything above it is in `ShelfCore` and tested without a network: which
/// URL, how often, what a 503 means, whether this was asked before. This is
/// the one piece that cannot be, so it is the one piece that is kept as small
/// as it can be (docs/ARCHITECTURE.md).
struct URLSessionTransport: MetadataTransport {
    /// Ephemeral, so `URLSession` keeps no cache and no cookies of its own:
    /// the answers Shelf keeps are the ones in `ResponseCache`, where they can
    /// be looked at, counted and thrown away. Two caches would be two answers
    /// to "was this asked before".
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// Sends every request somewhere else, for measuring what a network
    /// failure looks like.
    ///
    /// `SHELF_ONLINE_HOST=metadata.invalid` points the lookups at a name that
    /// cannot resolve, which is how the "network errors are quiet" claim is
    /// photographed without touching the Mac's own network settings — and
    /// `.invalid` is the reserved name that is guaranteed never to exist
    /// (RFC 2606), so it can never become somebody's real server.
    ///
    /// In the app layer and not in the core, so the URLs the core builds and
    /// the tests check stay the real ones. `SHELF_TIMING` is the precedent.
    static var substituteHost: String? {
        ProcessInfo.processInfo.environment["SHELF_ONLINE_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func fetch(_ url: URL, userAgent: String, timeout: Duration) async throws -> (Data: Data, status: Int) {
        var request = URLRequest(url: Self.redirected(url))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = TimeInterval(timeout.components.seconds)
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func redirected(_ url: URL) -> URL {
        guard let host = substituteHost, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.host = host
        return parts.url ?? url
    }

    /// The cover's bytes. A separate call because a cover is not a metadata
    /// answer: it is fetched only on an explicit action and never cached as
    /// JSON.
    func image(at url: URL, userAgent: String) async throws -> Data {
        var request = URLRequest(url: Self.redirected(url))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// The Fetch Metadata sheet's own state.
///
/// Its own model rather than a dozen fields on `LibraryModel`, for the reason
/// `ImportModel` is: a lookup outlives the sheet being closed, and a sheet that
/// owns its own work cannot lose it to a click outside.
///
/// **Nothing here writes anything.** It asks, it ranks, it draws the
/// comparison and it collects the ticks; applying goes back through
/// `LibraryModel.apply`, which is the one path that registers undo before it
/// writes and writes `metadata.opf` before the index (docs/ARCHITECTURE.md).
@MainActor
@Observable
final class OnlineMetadataModel {
    private static let logger = Logger(subsystem: "de.erikemmer.shelf", category: "online")

    /// The books the sheet will walk through, in order. More than one only
    /// through a multiple selection, and then still one book at a time with a
    /// decision each — there is no automatic bulk match in v1.0 (CONCEPT §9).
    private(set) var books: [LibraryEntry] = []
    private(set) var position = 0

    private(set) var isSearching = false
    private(set) var result: LookupResult?
    private(set) var chosen: MetadataCandidate?
    private(set) var proposals: [FieldProposal] = []
    var ticked: Set<String> = []

    private(set) var coverPreview: NSImage?
    private(set) var isFetchingCover = false
    /// Whether the cover from the service is still on offer — false once it
    /// has been taken, so a second click is not a second write.
    private(set) var wantsCover = false
    /// Whether there is already a picture beside the book.
    ///
    /// **Not a veto any more.** Until Sprint 9 this was the whole of the rule
    /// — a cover could be fetched only into an empty folder, because there was
    /// no way to undo one and no way to get the old one back. Both exist now
    /// (`CoverReplacement`), so what is left is a question of wording: the
    /// button says *Replace Cover* rather than *Use This Cover*, and the
    /// preview beside it is what a person judges before pressing it. A silent
    /// overwrite would still be a surprise; a labelled one is a decision.
    private(set) var coverAlreadyThere = false
    private(set) var coverNote: String?

    /// The quiet line. Network trouble is a sentence in the status bar and
    /// never a dialogue (CONCEPT §9). `note` is the whole of it, for the sheet;
    /// `briefNote` is what fits in the sidebar's footer.
    private(set) var note: String?
    private(set) var briefNote: String?

    // Not `private`: `FillMissingFieldsModel` (Sprint 18, Teil C4) shares this
    // instance rather than opening a second one, so the two features' calls
    // are paced against each other rather than each assuming it is alone.
    let fetcher: MetadataFetcher
    private let transport = URLSessionTransport()
    private let libraryRoot: URL
    private var searchTask: Task<Void, Never>?

    /// Where the answers are kept. `~/Library/Caches/Shelf/online/` — outside
    /// the library, because an ISBN's answer is the same answer for every
    /// library on this Mac, and unlike the covers it is worth nothing on
    /// another machine.
    static var cacheFolder: URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("Shelf/online", isDirectory: true)
    }

    init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot
        fetcher = MetadataFetcher(
            transport: transport, cache: ResponseCache(folder: Self.cacheFolder), policy: .standard)
    }

    // MARK: Opening

    /// Starts a lookup for these books. The first one is asked about at once.
    func start(with entries: [LibraryEntry]) {
        books = entries
        position = 0
        note = nil
        search()
    }

    var currentBook: LibraryEntry? { books.indices.contains(position) ? books[position] : nil }
    var hasMoreBooks: Bool { position + 1 < books.count }

    /// "Book 3 of 12" — drawn only when there is more than one, because a
    /// count of one is noise.
    var progressLabel: String? {
        books.count > 1
            ? Loc.string("Book %1$@ of %2$@", Loc.number(position + 1), Loc.number(books.count)) : nil
    }

    var query: MetadataQuery? { currentBook.flatMap { MetadataQuery.about($0.book) } }

    func next() {
        guard hasMoreBooks else { return }
        position += 1
        search()
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    // MARK: Asking

    private func search() {
        chosen = nil
        comparing = []
        proposals = []
        ticked = []
        coverPreview = nil
        coverNote = nil
        briefNote = nil
        result = nil
        wantsCover = true
        coverAlreadyThere = currentBook.map { CoverFile.url(in: folder(of: $0)) != nil } ?? false

        guard let query else {
            note = Loc.string("This book has no ISBN and no title to look it up by, so nothing was asked.")
            return
        }
        isSearching = true
        searchTask?.cancel()
        searchTask = Task { [fetcher] in
            let found = await fetcher.candidates(for: query)
            guard !Task.isCancelled else { return }
            self.isSearching = false
            self.result = found
            // A service that failed is a line in the status bar, never a stop:
            // the other service's candidates are still here.
            self.note = found.statusLine
            self.briefNote = found.briefProblem(found.failedSources)
            if found.isEmpty, found.problems.isEmpty {
                self.note = Loc.string("Neither service has anything for %@.", query.description)
                self.briefNote = self.note
            }
            // One candidate that is plainly the edition is chosen for the
            // person; anything less certain is left to them.
            if let best = found.ranked.first, best.score >= Self.certainEnough, found.ranked.count == 1 {
                self.choose(best.candidate)
            }
        }
    }

    /// The score at which a single candidate is opened without being clicked.
    /// 100 is "the service repeated the ISBN back", which is the only answer
    /// certain enough to save a click.
    static let certainEnough = 100

    // MARK: Choosing

    /// The records the comparison is built from: the one that was chosen, and
    /// the other service's answer about the same edition where there is one
    /// (`EditionMatch`). More than one means some lines come in pairs.
    private(set) var comparing: [MetadataCandidate] = []

    func choose(_ candidate: MetadataCandidate) {
        guard let book = currentBook?.book, let query else { return }
        chosen = candidate
        comparing = EditionMatch.comparison(
            of: candidate, among: result?.ranked ?? [], asked: query)
        proposals = MetadataMerge.proposals(for: book, from: comparing)
        ticked = Set(proposals.filter(\.isTickedByDefault).map(\.id))
        loadCoverPreview(candidate)
    }

    /// Back to the list without asking anything again — the answers are still
    /// here, and asking a service twice for one book would be rude twice.
    func backToCandidates() {
        chosen = nil
        comparing = []
        proposals = []
        ticked = []
        coverPreview = nil
        coverNote = nil
    }

    /// The rule is in the core, because "ticking one of two answers unticks the
    /// other" is a rule and not a gesture.
    func toggle(_ proposal: FieldProposal) {
        ticked = MetadataMerge.ticking(proposal, in: proposals, ticked: ticked)
    }

    var chosenProposals: [FieldProposal] { proposals.filter { ticked.contains($0.id) } }

    // MARK: The cover

    private func loadCoverPreview(_ candidate: MetadataCandidate) {
        coverPreview = nil
        guard let url = candidate.coverURL else { return }
        Task { [transport] in
            guard let data = try? await transport.image(at: url, userAgent: NetworkPolicy.standard.userAgent),
                let image = NSImage(data: data)
            else { return }
            guard self.chosen?.id == candidate.id else { return }
            self.coverPreview = image
        }
    }

    /// Downloads the cover and hands back the bytes. **Writes nothing.**
    ///
    /// Until Sprint 9 this wrote the file itself, which made it the second
    /// place in the program that decided what putting a cover beside a book
    /// means — and the two had already drifted: this one refused to replace
    /// anything, so a cover could be fetched exactly once per book and never
    /// corrected. The write is `LibraryModel.applyCover`'s now, the same one
    /// `Set Cover…` and the drop target go through, so the download gets the
    /// Trash, the generation and undo for nothing.
    ///
    /// The book file is not opened at all; the cover is a new file next to it.
    func fetchCoverData() async -> Data? {
        guard let entry = currentBook, let url = chosen?.coverURL, wantsCover else { return nil }
        isFetchingCover = true
        defer { isFetchingCover = false }
        do {
            let data = try await transport.image(at: url, userAgent: NetworkPolicy.standard.userAgent)
            wantsCover = false
            Self.logger.info("cover downloaded for \(entry.id, privacy: .public)")
            return data
        } catch {
            coverNote = Loc.string("The cover could not be fetched: %@", error.localizedDescription)
        }
        return nil
    }

    /// What the sheet says after a cover has landed.
    func coverWasWritten(as name: String) {
        coverAlreadyThere = true
        coverNote = Loc.string("Saved as %@ next to the book.", name)
    }

    private func folder(of entry: LibraryEntry) -> URL {
        libraryRoot.appendingPathComponent(entry.folder, isDirectory: true)
    }

    // MARK: Housekeeping

    func clearNote() {
        note = nil
        briefNote = nil
    }

    /// What the cache holds, for `Shelf ▸ Clear Downloaded Metadata`.
    static func cacheSize() async -> Int64 {
        await ResponseCache(folder: cacheFolder).size()
    }

    static func clearCache() async {
        await ResponseCache(folder: cacheFolder).clear()
    }
}
