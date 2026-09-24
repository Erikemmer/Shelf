import Foundation
import Testing

@testable import ShelfCore

@Suite("Filling missing fields, strictly by ISBN (Sprint 18, Teil C4)")
struct FillMissingFieldsTests {
    private func fetcher(_ answers: [ScriptedTransport.Answer]) -> MetadataFetcher {
        let transport = ScriptedTransport(answers)
        let policy = NetworkPolicy(
            userAgent: NetworkPolicy.standard.userAgent, minimumInterval: .milliseconds(1),
            timeout: .seconds(1), maximumAttempts: 3)
        return MetadataFetcher(transport: transport, cache: nil, policy: policy)
    }

    private func answer(_ json: String) -> ScriptedTransport.Answer {
        ScriptedTransport.Answer(status: 200, body: Data(json.utf8))
    }

    private let emptyOpenLibrary = "{\"docs\": []}"
    private let emptyGoogleBooks = "{\"totalItems\": 0}"

    private func entry(
        title: String = "Sturmlicht", authors: [String] = ["A. Autor"], language: String? = nil,
        publisher: String? = nil, description: String? = nil, isbn: String? = nil, number: Int = 1
    ) -> LibraryEntry {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        let book = Book(
            title: title, authors: authors, publisher: publisher, language: language,
            description: description, identifiers: identifiers)
        return LibraryEntry(book: book, number: number, folder: title)
    }

    // MARK: - The ISBN pass

    @Test("Fills an empty field from a matching ISBN candidate")
    func fillsFromISBN() async throws {
        let googleBooks = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "publisher": "Verlag X", "industryIdentifiers": [{"type": "ISBN_13", "identifier": "9780306406157"}]}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(publisher: nil, isbn: "9780306406157")],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))

        #expect(result.plans.count == 1)
        let plan = try #require(result.plans.first)
        #expect(plan.change.after.publisher == "Verlag X")
        #expect(plan.proposals.contains { $0.source == .isbn(.googleBooks) })
    }

    @Test("Never fills an edition-level field from a work-level-only record")
    func neverFillsEditionLevelFromAWorkRecord() async throws {
        // Open Library's search never sets describesOneEdition, and it is the
        // only one that answers here — so publisher/language/date must stay empty.
        let openLibrary = """
            {"docs": [{"key": "/works/OL1W", "title": "Sturmlicht", "author_name": ["A. Autor"],
            "publisher": ["Verlag X"], "isbn": ["9780306406157"]}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(publisher: nil, isbn: "9780306406157")],
            fetcher: fetcher([answer(openLibrary), answer(emptyGoogleBooks)]))

        #expect(result.plans.isEmpty)
        #expect(result.unchanged.first?.reason == .nothingToFill)
    }

    // MARK: - Reporting buckets

    @Test("A book with no ISBN and no title has nothing to ask with")
    func nothingToAskWith() async {
        let result = await FillMissingFields.plan(
            over: [entry(title: "", authors: [])], fetcher: fetcher([]))
        #expect(result.unchanged.first?.reason == .nothingToAskWith)
    }

    @Test("A valid ISBN that gets no answer at all is reported as such")
    func noAnswerReported() async {
        let result = await FillMissingFields.plan(
            over: [entry(isbn: "9780306406157")],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(emptyGoogleBooks)]))
        #expect(result.unchanged.first?.reason == .noAnswer)
    }

    // MARK: - DescriptionFill's four conditions

    // Trimmed: `OpenLibraryReader.string` (shared by both readers) trims
    // whitespace off whatever a service sends back, so the expected value
    // has to match what actually survives the round trip.
    private let longPlainSummary = String(repeating: "Ein Roman über eine lange Reise. ", count: 4)
        .trimmingCharacters(in: .whitespaces)

    @Test("Fills description via Title+Author when all four conditions hold")
    func fillsDescriptionViaTitleAuthor() async throws {
        let googleBooks = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "language": "de", "description": "\(longPlainSummary)"}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil)],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.description == longPlainSummary)
        #expect(plan.proposals.contains { $0.source == .titleAuthor(.googleBooks) })
    }

    @Test("Two candidates matching title and author is ambiguous — no fill")
    func ambiguousTitleAuthorNeverFills() async {
        let googleBooks = """
            {"items": [
              {"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"], "language": "de", "description": "\(longPlainSummary)"}},
              {"id": "gb2", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"], "language": "de", "description": "\(longPlainSummary)"}}
            ]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil)],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))
        #expect(result.plans.isEmpty)
    }

    @Test("A language that disagrees with the book's own never fills")
    func languageMismatchNeverFills() async {
        let googleBooks = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "language": "en", "description": "\(longPlainSummary)"}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil)],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))
        #expect(result.plans.isEmpty)
    }

    @Test("A summary at or under 80 characters never fills")
    func tooShortNeverFills() async {
        let googleBooks = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "language": "de", "description": "Ein kurzer Satz."}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil)],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))
        #expect(result.plans.isEmpty)
    }

    @Test("A summary carrying markup beyond a paragraph break never fills")
    func markedUpSummaryNeverFills() async {
        let markedUp = "<b>\(longPlainSummary)</b>"
        let googleBooks = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "language": "de", "description": "\(markedUp)"}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil)],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))
        #expect(result.plans.isEmpty)
    }

    @Test("A plain paragraph break alone does not disqualify a summary")
    func paragraphBreakAloneIsFine() async throws {
        let withBreak = "<p>\(longPlainSummary)</p><p>\(longPlainSummary)</p>"
        let googleBooks = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "language": "de", "description": "\(withBreak)"}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil)],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))
        let plan = try #require(result.plans.first)
        #expect(plan.change.after.description == withBreak)
    }

    @Test("An already-filled description is never reconsidered")
    func nonEmptyDescriptionNeverAsked() async {
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: "Schon da.")],
            fetcher: fetcher([]))
        #expect(result.plans.isEmpty)
        #expect(result.unchanged.first?.reason == .nothingToAskWith)
    }

    @Test("Progress is reported once per book, in order")
    func progressReportedOncePerBook() async {
        actor Recorder {
            var seen: [(Int, Int)] = []
            func record(_ done: Int, _ total: Int) { seen.append((done, total)) }
        }
        let recorder = Recorder()
        _ = await FillMissingFields.plan(
            over: [entry(title: "One", authors: []), entry(title: "Two", authors: [], number: 2)],
            fetcher: fetcher([]),
            progress: { done, total in Task { await recorder.record(done, total) } })
        // The callback itself is synchronous per book; give the recorder's
        // tasks a moment to land before reading them back.
        try? await Task.sleep(for: .milliseconds(50))
        let seen = await recorder.seen
        #expect(seen.map(\.0) == [1, 2])
        #expect(seen.map(\.1) == [2, 2])
    }

    // MARK: - Composition: the ISBN pass and the description exception together

    @Test("A book with an ISBN can still get its description via Title+Author")
    func isbnAndDescriptionExceptionCombine() async throws {
        // Google Books' own ISBN answer has no description (only Open Library's
        // ISBN answer does here, and Open Library never carries one for real —
        // this fixture only has to prove the *second* pass runs at all).
        let googleBooksISBN = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "publisher": "Verlag X", "industryIdentifiers": [{"type": "ISBN_13", "identifier": "9780306406157"}]}}]}
            """
        let googleBooksTitleAuthor = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "language": "de", "description": "\(longPlainSummary)"}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", publisher: nil, description: nil, isbn: "9780306406157")],
            fetcher: fetcher([
                answer(emptyOpenLibrary), answer(googleBooksISBN),
                answer(emptyOpenLibrary), answer(googleBooksTitleAuthor),
            ]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.publisher == "Verlag X")
        #expect(plan.change.after.description == longPlainSummary)
        #expect(plan.proposals.contains { $0.source == .isbn(.googleBooks) })
        #expect(plan.proposals.contains { $0.source == .titleAuthor(.googleBooks) })
    }
}
