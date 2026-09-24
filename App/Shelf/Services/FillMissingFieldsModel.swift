import Foundation
import Observation
import ShelfCore

/// "Fill Missing Fields…" — Teil C4. Unlike `OnlineMetadataModel`'s
/// one-book-at-a-time walk, this runs `FillMissingFields.plan` across many
/// books in one pass and shows one combined, previewed, undoable result. See
/// the ADR 0015 addendum for why a combined preview built entirely from
/// `MetadataMerge`'s own field-trust rules is not the "automatic bulk match"
/// that ADR's own rule 5 rules out.
@Observable
@MainActor
final class FillMissingFieldsModel {
    enum Phase: Equatable {
        static func == (one: Phase, other: Phase) -> Bool {
            switch (one, other) {
            case (.searching(let a, let b), .searching(let c, let d)): return a == c && b == d
            case (.ready, .ready): return true
            case (.done(let a, let b), .done(let c, let d)): return a == c && b == d
            default: return false
            }
        }
        case searching(done: Int, total: Int)
        case ready(FillMissingFields.Result)
        case done(booksFilled: Int, coversFilled: Int)
    }

    private(set) var phase: Phase?
    private let fetcher: MetadataFetcher
    private let coverTransport = URLSessionTransport()
    private let libraryRoot: URL

    init(fetcher: MetadataFetcher, libraryRoot: URL) {
        self.fetcher = fetcher
        self.libraryRoot = libraryRoot
    }

    /// Runs the ISBN pass and the description exception across every entry,
    /// reporting progress as it goes — a real library at one request per
    /// second per service can take minutes.
    func begin(over entries: [LibraryEntry]) {
        phase = .searching(done: 0, total: entries.count)
        Task {
            let result = await FillMissingFields.plan(
                over: entries, fetcher: fetcher,
                progress: { [weak self] done, total in
                    Task { @MainActor in self?.phase = .searching(done: done, total: total) }
                })
            phase = .ready(result)
        }
    }

    func markDone(booksFilled: Int, coversFilled: Int) {
        phase = .done(booksFilled: booksFilled, coversFilled: coversFilled)
    }

    /// The covers this run would also fetch: every entry lacking one
    /// (`CoverFile.booksWithACover`, the same folder-truth query the sidebar's
    /// "Missing Cover" collection uses — never a raw filename guess) that also
    /// has a valid ISBN. Computed alongside the field plan so the preview
    /// names both before either writes anything.
    func coverGaps(among entries: [LibraryEntry]) -> [LibraryEntry] {
        let withCovers = CoverFile.booksWithACover(in: libraryRoot, entries: entries)
        return entries.filter { !withCovers.contains($0.id) && MetadataQuery.about($0.book).map(isISBN) == true }
    }

    private func isISBN(_ query: MetadataQuery) -> Bool {
        if case .isbn = query { return true }
        return false
    }

    /// Fetches and prepares a cover for each gap, ISBN only — never a
    /// Title+Author guess at which picture belongs to which edition. Skips a
    /// book with no candidate, no cover URL, or bytes that are not a picture
    /// at all (`CoverImage.prepare`, the same check `Set Cover…` applies); the
    /// count in `.done` is only ever what actually landed.
    func fetchCovers(for gaps: [LibraryEntry]) async -> [(entry: LibraryEntry, data: Data)] {
        var found: [(entry: LibraryEntry, data: Data)] = []
        for entry in gaps {
            guard case .isbn(let isbn) = MetadataQuery.about(entry.book) else { continue }
            let result = await fetcher.candidates(for: .isbn(isbn))
            guard let url = result.ranked.first?.candidate.coverURL else { continue }
            guard let raw = try? await coverTransport.image(at: url, userAgent: NetworkPolicy.standard.userAgent)
            else { continue }
            guard case .success(let prepared) = CoverImage.prepare(raw) else { continue }
            found.append((entry, prepared))
        }
        return found
    }
}
