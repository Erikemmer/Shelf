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
        publisher: String? = nil, description: String? = nil, isbn: String? = nil, asin: String? = nil,
        number: Int = 1
    ) -> LibraryEntry {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        if let asin { identifiers["asin"] = asin }
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

    @Test(
        "A region-tagged book language still agrees with a service's bare one — the real-library bug, Sprint 20 Teil A1"
    )
    func regionTaggedLanguageStillMatches() async throws {
        // Real shape, found against the real library: a book stored as
        // "en-GB" (`FieldStandardization` deliberately never folds a
        // region-tagged code — it already carries a canonical region and is
        // not the bare three-letter code that rule exists to fix). Before
        // `LanguageCode.matches`, `normalised("en-GB")` ("en-gb", passed
        // through as unknown) never equalled a service's bare `normalised`
        // form, so this book's description could never fill even once the
        // candidate's own language plainly agreed.
        let googleBooks = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "language": "en", "description": "\(longPlainSummary)"}}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "en-GB", description: nil)],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(googleBooks)]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.description == longPlainSummary)
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

    // MARK: - A 429 stops that service for the rest of the run

    @Test("a 429 on one book's ISBN pass stops that service being asked for any later book")
    func a429StopsTheServiceForLaterBooks() async {
        let result = await FillMissingFields.plan(
            over: [
                entry(isbn: "9780306406157", number: 1),
                entry(isbn: "9780132350884", number: 2),
            ],
            fetcher: fetcher([
                answer(emptyOpenLibrary), ScriptedTransport.Answer(status: 429, body: Data("{}".utf8)),
                answer(emptyOpenLibrary),
            ]))

        #expect(result.problems.contains { $0.contains("Google Books") && $0.contains("429") })
        // Exactly one line — a service down for the run is one fact, said once,
        // not repeated per book it then affected.
        #expect(result.problems.filter { $0.contains("429") }.count == 1)
        // Book 1 is the one that got the 429 itself, not a skip; book 2's own
        // request to Google Books is the one that never happened.
        #expect(result.serviceSkips[.googleBooks] == 1)
        #expect(result.serviceSkips[.openLibrary] == nil)
    }

    @Test("the description pass also stops asking a service the ISBN pass already saw refuse")
    func descriptionPassRespectsAnEarlierRefusal() async throws {
        let googleBooksISBN = """
            {"items": [{"id": "gb1", "volumeInfo": {"title": "Sturmlicht", "authors": ["A. Autor"],
            "publisher": "Verlag X", "industryIdentifiers": [{"type": "ISBN_13", "identifier": "9780306406157"}]}}]}
            """
        let result = await FillMissingFields.plan(
            over: [
                // Book 1: Open Library refuses with 429; Google Books still
                // answers, and its own candidate fills the publisher.
                entry(publisher: nil, isbn: "9780306406157", number: 1),
                // Book 2: no ISBN, so only the description pass runs, and it
                // must not ask Open Library again.
                entry(language: "de", description: nil, isbn: nil, number: 2),
            ],
            fetcher: fetcher([
                ScriptedTransport.Answer(status: 429, body: Data("{}".utf8)), answer(googleBooksISBN),
                answer(emptyGoogleBooks),
            ]))

        let plan = try #require(result.plans.first { $0.entry.number == 1 })
        #expect(plan.change.after.publisher == "Verlag X")
        #expect(result.serviceSkips[.openLibrary] == 1, "book 2's description pass skipped Open Library")
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
                // Teil B2's own edition-endpoint call, between the ISBN
                // pass's two search answers and the description pass's own
                // two — a 404, "no edition record for this ISBN", one of the
                // real answers the Sprint 21 probe actually saw.
                ScriptedTransport.Answer(status: 404, body: Data("{}".utf8)),
                answer(emptyOpenLibrary), answer(googleBooksTitleAuthor),
            ]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.publisher == "Verlag X")
        #expect(plan.change.after.description == longPlainSummary)
        #expect(plan.proposals.contains { $0.source == .isbn(.googleBooks) })
        #expect(plan.proposals.contains { $0.source == .titleAuthor(.googleBooks) })
    }

    // MARK: - Teil B2: Open Library's own per-ISBN edition endpoint

    @Test("an edition-level answer fills publisher, date and language a work-level record alone never could")
    func editionEndpointFillsEditionLevelFields() async throws {
        // The same fixture as "Never fills an edition-level field…" above:
        // Open Library's search finds the work, but never trusts its own
        // publisher/language guess. This time the edition endpoint answers
        // too, and that one is trusted.
        let openLibrarySearch = """
            {"docs": [{"key": "/works/OL1W", "title": "Sturmlicht", "author_name": ["A. Autor"],
            "publisher": ["Ein geratener Verlag"], "language": ["ja"], "isbn": ["9780306406157"]}]}
            """
        let edition = """
            {"title": "Sturmlicht", "publishers": ["Der richtige Verlag"], "publish_date": "2019",
             "languages": [{"key": "/languages/ger"}], "isbn_13": ["9780306406157"]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: nil, publisher: nil, isbn: "9780306406157")],
            fetcher: fetcher([answer(openLibrarySearch), answer(emptyGoogleBooks), answer(edition)]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.publisher == "Der richtige Verlag")
        #expect(plan.change.after.language == "de")
        #expect(plan.proposals.contains { $0.label == BookField.publisher.label && $0.source == .isbn(.openLibrary) })
    }

    @Test("a 404 from the edition endpoint — no record for this ISBN — is quiet, not a problem")
    func editionEndpoint404IsQuiet() async throws {
        let result = await FillMissingFields.plan(
            over: [entry(isbn: "9780306406157")],
            fetcher: fetcher([
                answer(emptyOpenLibrary), answer(emptyGoogleBooks),
                ScriptedTransport.Answer(status: 404, body: Data("{}".utf8)),
            ]))
        #expect(result.problems.isEmpty)
        #expect(result.unchanged.first?.reason == .noAnswer)
    }

    @Test(
        "a 429 from the edition endpoint stops Open Library being asked for any later book, same as a 429 from search")
    func editionEndpoint429BlocksLaterBooks() async throws {
        let result = await FillMissingFields.plan(
            over: [
                entry(isbn: "9780306406157", number: 1),
                entry(isbn: "9780132350884", number: 2),
            ],
            fetcher: fetcher([
                answer(emptyOpenLibrary), answer(emptyGoogleBooks),
                ScriptedTransport.Answer(status: 429, body: Data("{}".utf8)),
                // Book 2's own ISBN search still asks Google Books — only
                // Open Library, having just said "stop", is skipped for it.
                answer(emptyGoogleBooks),
            ]))
        #expect(result.serviceSkips[.openLibrary] == 1, "book 2's own search, skipped because of book 1's edition 429")
    }

    // MARK: - Teil B3: an ASIN treated like an ISBN, once uniquely resolved

    @Test("a uniquely-resolved ASIN fills publisher, date and language, exactly as an ISBN does")
    func uniqueASINFillsEditionLevelFields() async throws {
        let asinSearch = """
            {"numFound": 1, "docs": [{"key": "/works/OL1W", "title": "Sturmlicht", "edition_key": ["OL1M"]}]}
            """
        let edition = """
            {"title": "Sturmlicht", "publishers": ["Der richtige Verlag"], "publish_date": "2019",
             "languages": [{"key": "/languages/ger"}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: nil, publisher: nil, isbn: nil, asin: "B01ABCDEFG")],
            fetcher: fetcher([answer(asinSearch), answer(edition)]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.publisher == "Der richtige Verlag")
        #expect(plan.change.after.language == "de")
        #expect(plan.proposals.contains { $0.source == .asin(.openLibrary) })
    }

    @Test("an ASIN search naming more than one work or edition never fills anything")
    func ambiguousASINNeverFills() async {
        let asinSearch = """
            {"numFound": 2, "docs": [
              {"key": "/works/OL1W", "title": "A", "edition_key": ["OL1M"]},
              {"key": "/works/OL2W", "title": "B", "edition_key": ["OL2M"]}
            ]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(publisher: nil, isbn: nil, asin: "B01ABCDEFG")],
            fetcher: fetcher([answer(asinSearch)]))
        #expect(result.plans.isEmpty)
        #expect(result.unchanged.first?.reason == .noAnswer)
    }

    @Test("an ISBN book is never also asked its ASIN — an ISBN, once present, is the whole of the identity route")
    func isbnTakesPriorityOverASIN() async throws {
        let result = await FillMissingFields.plan(
            over: [entry(isbn: "9780306406157", asin: "B01ABCDEFG")],
            fetcher: fetcher([
                answer(emptyOpenLibrary), answer(emptyGoogleBooks),
                ScriptedTransport.Answer(status: 404, body: Data("{}".utf8)),
            ]))
        // Three answers is the whole of the ISBN pass; a fourth request (an
        // ASIN search) would have hit the transport's own empty-list default
        // rather than failing outright, so the real proof is what actually
        // happened: nothing was filled and nothing errored.
        #expect(result.unchanged.first?.reason == .noAnswer)
    }

    // MARK: - Teil B1: a work-level description, chained from a Title+Author
    // match and from B2/B3's own edition record

    @Test("Open Library's own inline summary is always nil, so a unique OL match falls through to its work record")
    func titleAuthorMatchChainsToTheWorkRecord() async throws {
        let openLibrarySearch = """
            {"docs": [{"key": "/works/OL1W", "title": "Sturmlicht", "author_name": ["A. Autor"], "language": ["ger"]}]}
            """
        let work = """
            {"key": "/works/OL1W", "title": "Sturmlicht",
             "description": {"type": "/type/text", "value": "\(longPlainSummary)"}}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil, isbn: nil)],
            fetcher: fetcher([answer(openLibrarySearch), answer(emptyGoogleBooks), answer(work)]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.description == longPlainSummary)
        #expect(plan.proposals.contains { $0.source == .titleAuthor(.openLibrary) })
    }

    @Test(
        "the work record's own language is never asked — DescriptionFill's condition (c) already used the candidate's")
    func workRecordHasNoLanguageOfItsOwnToCheck() async {
        // The Title+Author match's language still has to agree (condition
        // c, checked before the work is ever fetched) — a language
        // mismatch never reaches the work record at all.
        let openLibrarySearch = """
            {"docs": [{"key": "/works/OL1W", "title": "Sturmlicht", "author_name": ["A. Autor"], "language": ["en"]}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil, isbn: nil)],
            fetcher: fetcher([answer(openLibrarySearch), answer(emptyGoogleBooks)]))
        #expect(result.plans.isEmpty, "language disagreed, so the work record was never fetched at all")
    }

    @Test("B2's own edition record chains to a description too, when the book's language agrees")
    func isbnEditionChainsToADescription() async throws {
        let edition = """
            {"title": "Sturmlicht", "languages": [{"key": "/languages/ger"}], "works": [{"key": "/works/OL1W"}]}
            """
        let work = """
            {"key": "/works/OL1W", "title": "Sturmlicht",
             "description": {"type": "/type/text", "value": "\(longPlainSummary)"}}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", publisher: "Schon da", description: nil, isbn: "9780306406157")],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(emptyGoogleBooks), answer(edition), answer(work)]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.description == longPlainSummary)
        #expect(plan.proposals.contains { $0.label == BookField.description.label && $0.source == .isbn(.openLibrary) })
    }

    @Test("B3's own edition record chains to a description too")
    func asinEditionChainsToADescription() async throws {
        let asinSearch = """
            {"numFound": 1, "docs": [{"key": "/works/OL1W", "title": "Sturmlicht", "edition_key": ["OL1M"]}]}
            """
        let edition = """
            {"title": "Sturmlicht", "languages": [{"key": "/languages/ger"}], "works": [{"key": "/works/OL1W"}]}
            """
        let work = """
            {"key": "/works/OL1W", "title": "Sturmlicht",
             "description": {"type": "/type/text", "value": "\(longPlainSummary)"}}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", description: nil, isbn: nil, asin: "B01ABCDEFG")],
            fetcher: fetcher([answer(asinSearch), answer(edition), answer(work)]))

        let plan = try #require(result.plans.first)
        #expect(plan.change.after.description == longPlainSummary)
        #expect(plan.proposals.contains { $0.label == BookField.description.label && $0.source == .asin(.openLibrary) })
    }

    @Test("an edition record whose own language disagrees with the book's never fetches the work at all")
    func editionLanguageMismatchNeverChainsToTheWork() async {
        let edition = """
            {"title": "Sturmlicht", "languages": [{"key": "/languages/eng"}], "works": [{"key": "/works/OL1W"}]}
            """
        let result = await FillMissingFields.plan(
            over: [entry(language: "de", publisher: "Schon da", description: nil, isbn: "9780306406157")],
            fetcher: fetcher([answer(emptyOpenLibrary), answer(emptyGoogleBooks), answer(edition)]))
        // Three answers is the whole of it — a fourth (the work record)
        // would never be asked, because the language check fails first.
        #expect(result.plans.isEmpty)
        #expect(result.unchanged.first?.reason == .nothingToFill)
    }

    @Test("a UUID stored under mobi-asin's own scheme is never mistaken for a real ASIN")
    func uuidUnderMobiAsinIsNeverAsked() async {
        // Real shape, found against the real library (Sprint 21, Teil B3's
        // own `AmazonASIN`): a Calibre import can carry an identifier under
        // `mobi-asin` that is a UUID, not an ASIN. No language is set, so a
        // Title+Author description lookup cannot run either — an empty
        // fetcher script proves nothing at all was asked.
        let withUUID = LibraryEntry(
            book: Book(
                title: "Sturmlicht", authors: ["A. Autor"],
                identifiers: ["mobi-asin": "1197f37d-a883-4227-97a1-39f0f0f5b32b"]),
            number: 1, folder: "Sturmlicht")
        let result = await FillMissingFields.plan(over: [withUUID], fetcher: fetcher([]))
        #expect(result.unchanged.first?.reason == .nothingToAskWith)
    }
}
