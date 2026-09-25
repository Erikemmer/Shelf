import Foundation
import Testing

@testable import ShelfCore

/// Teil B2/B3: Open Library's own per-ISBN and per-ASIN edition endpoints,
/// and Teil B1's work-level description — all invented JSON, shaped exactly
/// as the real answers Sprint 21's own probe read (never a real book's own
/// data; CLAUDE.md).
@Suite("Open Library's edition-level endpoints (Sprint 21, Teil B2/B3)")
struct OpenLibraryEditionReaderTests {
    @Test("reads publisher, date, language and the work key from a real edition shape")
    func readsAFullRecord() throws {
        let json = """
            {"title": "Ein erfundener Titel", "publishers": ["Erfundener Verlag"],
             "publish_date": "2019", "languages": [{"key": "/languages/ger"}],
             "works": [{"key": "/works/OL999W"}], "isbn_13": ["9780000000002"]}
            """
        let edition = try #require(try OpenLibraryEditionReader.edition(from: Data(json.utf8), isbn: "9780000000002"))
        #expect(edition.title == "Ein erfundener Titel")
        #expect(edition.publisher == "Erfundener Verlag")
        #expect(edition.publishedText == "2019")
        #expect(edition.language == "de")
        #expect(edition.workKey == "/works/OL999W")
        #expect(edition.isbn == "9780000000002")
    }

    @Test("a record missing every optional field still has a title, and nothing else")
    func aBareRecord() throws {
        let json = #"{"title": "Ein erfundener Titel"}"#
        let edition = try #require(try OpenLibraryEditionReader.edition(from: Data(json.utf8), isbn: "9780000000002"))
        #expect(edition.publisher == nil)
        #expect(edition.publishedText == nil)
        #expect(edition.language == nil)
        #expect(edition.workKey == nil)
    }

    @Test("no title at all is not a record — the same guard every other reader here uses")
    func noTitleIsNoRecord() throws {
        let json = #"{"publishers": ["Erfundener Verlag"]}"#
        let edition = try OpenLibraryEditionReader.edition(from: Data(json.utf8), isbn: "9780000000002")
        #expect(edition == nil)
    }

    @Test("something that is not an object throws, the way every other reader here does")
    func notAnObjectThrows() {
        #expect(throws: MetadataReadFailure.self) {
            try OpenLibraryEditionReader.edition(from: Data("[]".utf8), isbn: "9780000000002")
        }
    }
}

@Suite("Folding an edition record into the candidates a normal lookup already found")
struct EditionMergeTests {
    private func candidate(
        source: MetadataSource, publisher: String?, language: String?, describesOneEdition: Bool
    ) -> MetadataCandidate {
        MetadataCandidate(
            id: "x", source: source, title: "Ein erfundener Titel", publisher: publisher, language: language,
            identifiers: ["isbn": "9780000000002"], describesOneEdition: describesOneEdition)
    }

    @Test("replaces the Open Library candidate's edition-level fields, and nothing about Google Books'")
    func replacesOpenLibrarysOwnFields() {
        let edition = OpenLibraryEdition(
            isbn: "9780000000002", title: "t", publisher: "Der richtige Verlag", publishedText: "2020",
            published: nil, language: "de", workKey: "/works/OL999W")
        let existing = [
            candidate(
                source: .openLibrary, publisher: "Ein Verlag, aus einer anderen Ausgabe geraten",
                language: "ja", describesOneEdition: false),
            candidate(source: .googleBooks, publisher: "Google-Verlag", language: "en", describesOneEdition: true),
        ]
        let merged = EditionMerge.folding(edition, into: existing)

        let openLibrary = try! #require(merged.first { $0.source == .openLibrary })
        #expect(openLibrary.publisher == "Der richtige Verlag")
        #expect(openLibrary.language == "de")
        #expect(openLibrary.describesOneEdition == true)

        let googleBooks = try! #require(merged.first { $0.source == .googleBooks })
        #expect(googleBooks.publisher == "Google-Verlag", "the other service's own candidate is untouched")
    }

    @Test("a field the edition record does not carry is left empty, not inherited from the work-level guess")
    func doesNotLeakTheOldGuess() {
        let edition = OpenLibraryEdition(
            isbn: "9780000000002", title: "t", publisher: nil, publishedText: nil, published: nil, language: nil,
            workKey: nil)
        let existing = [
            candidate(
                source: .openLibrary, publisher: "Ein geratener Verlag", language: "ja", describesOneEdition: false)
        ]
        let merged = EditionMerge.folding(edition, into: existing)
        let openLibrary = try! #require(merged.first { $0.source == .openLibrary })
        #expect(openLibrary.publisher == nil, "not the work-level guess, now wearing a trust flag it never earned")
        #expect(openLibrary.describesOneEdition == true)
    }

    @Test("with no Open Library candidate to fold into, the edition stands on its own")
    func standsAloneWithoutASearchAnswer() {
        let edition = OpenLibraryEdition(
            isbn: "9780000000002", title: "Ein erfundener Titel", publisher: "Ein Verlag", publishedText: "2021",
            published: nil, language: "de", workKey: nil)
        let merged = EditionMerge.folding(edition, into: [])
        #expect(merged.count == 1)
        #expect(merged.first?.source == .openLibrary)
        #expect(merged.first?.describesOneEdition == true)
        #expect(merged.first?.publisher == "Ein Verlag")
    }
}

@Suite("An Amazon ASIN, and where it might be hiding")
struct AmazonASINTests {
    @Test("a real ASIN's shape") func shape() {
        #expect(AmazonASIN.isValid("B01ABCDEFG"))
        #expect(!AmazonASIN.isValid("not-an-asin"))
        #expect(!AmazonASIN.isValid("9780306406157"), "an ISBN is not an ASIN, however many digits it has")
    }

    @Test("checked under asin, then mobi-asin, then amazon — never a UUID under any of them")
    func schemeOrder() {
        #expect(AmazonASIN.valid(in: ["asin": "B01ABCDEFG"]) == "B01ABCDEFG")
        #expect(AmazonASIN.valid(in: ["mobi-asin": "B02ABCDEFG"]) == "B02ABCDEFG")
        #expect(AmazonASIN.valid(in: ["mobi-asin": "1197f37d-a883-4227-97a1-39f0f0f5b32b"]) == nil)
        #expect(AmazonASIN.valid(in: [:]) == nil)
    }
}

@Suite("Teil B3's own uniqueness check")
struct OpenLibraryASINSearchTests {
    @Test("exactly one work, exactly one edition — the shape B3 trusts")
    func uniqueHit() throws {
        let json = """
            {"numFound": 1, "docs": [{"key": "/works/OL1W", "title": "t", "edition_key": ["OL1M"],
             "isbn": ["0000000002", "9780000000002"]}]}
            """
        let hit = try #require(try OpenLibraryASINSearch.uniqueEdition(from: Data(json.utf8)))
        #expect(hit.editionKey == "OL1M")
        #expect(hit.isbn == "9780000000002", "the 13-digit one is preferred")
    }

    @Test("no hit at all") func noHit() throws {
        let json = #"{"numFound": 0, "docs": []}"#
        #expect(try OpenLibraryASINSearch.uniqueEdition(from: Data(json.utf8)) == nil)
    }

    @Test("more than one work is not unique, whatever it carries")
    func moreThanOneWork() throws {
        let json = """
            {"numFound": 2, "docs": [
              {"key": "/works/OL1W", "title": "t", "edition_key": ["OL1M"]},
              {"key": "/works/OL2W", "title": "t2", "edition_key": ["OL2M"]}
            ]}
            """
        #expect(try OpenLibraryASINSearch.uniqueEdition(from: Data(json.utf8)) == nil)
    }

    @Test("one work with more than one edition is not unique either")
    func moreThanOneEdition() throws {
        let json = """
            {"numFound": 1, "docs": [{"key": "/works/OL1W", "title": "t", "edition_key": ["OL1M", "OL2M"]}]}
            """
        #expect(try OpenLibraryASINSearch.uniqueEdition(from: Data(json.utf8)) == nil)
    }
}

@Suite("A work's own description (Teil B1)")
struct OpenLibraryWorkReaderTests {
    @Test("the object shape every real work record this project has read actually uses")
    func objectShape() throws {
        let json = """
            {"key": "/works/OL1W", "title": "t",
             "description": {"type": "/type/text", "value": "Eine erfundene, ausreichend lange Beschreibung."}}
            """
        #expect(
            try OpenLibraryWorkReader.description(from: Data(json.utf8))
                == "Eine erfundene, ausreichend lange Beschreibung.")
    }

    @Test("a plain string, in case a future answer ever uses it")
    func stringShape() throws {
        let json = #"{"key": "/works/OL1W", "title": "t", "description": "Eine erfundene Beschreibung."}"#
        #expect(try OpenLibraryWorkReader.description(from: Data(json.utf8)) == "Eine erfundene Beschreibung.")
    }

    @Test("no description key at all is not an error") func noDescription() throws {
        let json = #"{"key": "/works/OL1W", "title": "t"}"#
        #expect(try OpenLibraryWorkReader.description(from: Data(json.utf8)) == nil)
    }
}
