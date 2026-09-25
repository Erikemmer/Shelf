import Foundation
import Testing

@testable import ShelfCore

@Suite("Reducing Calibre's own comments HTML to plain paragraphs")
struct HTMLToPlainParagraphsTests {
    @Test("block tags become paragraph breaks, everything else is dropped")
    func reducesRichHTML() {
        let html = "<div><p>Erster Absatz mit <b>fettem</b> Text.</p><p>Zweiter Absatz.</p></div>"
        #expect(HTMLToPlainParagraphs.reduce(html) == "Erster Absatz mit fettem Text.\n\nZweiter Absatz.")
    }

    @Test("entities are decoded") func entities() {
        #expect(HTMLToPlainParagraphs.reduce("Salz &amp; Pfeffer") == "Salz & Pfeffer")
        #expect(HTMLToPlainParagraphs.reduce("A&nbsp;B") == "A B")
    }

    @Test("a bare <br> is a paragraph break too") func lineBreak() {
        #expect(HTMLToPlainParagraphs.reduce("Zeile eins<br>Zeile zwei") == "Zeile eins\n\nZeile zwei")
    }

    @Test("plain text with no markup at all is unchanged") func plainText() {
        #expect(HTMLToPlainParagraphs.reduce("Ein ganz gewöhnlicher Satz.") == "Ein ganz gewöhnlicher Satz.")
    }
}

@Suite("Calibre as a second source for Fill Missing Fields (Sprint 21, Teil B4)")
struct CalibreFieldSourceTests {
    private func calibreBook(
        id: UUID = UUID(), number: Int = 1, isbn: String? = nil, description: String? = nil,
        publisher: String? = nil, language: String? = nil, series: SeriesRef? = nil, tags: [String] = []
    ) -> CalibreBook {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        let book = Book(
            id: id, title: "Ein Titel", authors: ["Eine Autorin"], series: series, publisher: publisher,
            language: language, description: description, tags: tags, identifiers: identifiers)
        return CalibreBook(number: number, book: book, folder: "Eine Autorin/Ein Titel (1)")
    }

    // MARK: - Matching

    @Test("matches by the UUID Calibre gave the book at import") func matchesByUUID() {
        let id = UUID()
        let ours = Book(id: id, title: "Ein Titel", authors: ["Eine Autorin"])
        let library = CalibreLibrary(
            folder: URL(fileURLWithPath: "/tmp"), schema: CalibreSchema(userVersion: 1, isKnown: true),
            books: [calibreBook(id: id)])
        #expect(CalibreFieldSource.matching(ours, in: library)?.book.id == id)
    }

    @Test("falls back to an equal, checksum-valid ISBN when the UUID does not match")
    func matchesByISBN() {
        let ours = Book(
            title: "Ein anderer Titel", authors: ["Jemand"], identifiers: ["isbn": "9780306406157"])
        let library = CalibreLibrary(
            folder: URL(fileURLWithPath: "/tmp"), schema: CalibreSchema(userVersion: 1, isKnown: true),
            books: [calibreBook(isbn: "9780306406157")])
        #expect(CalibreFieldSource.matching(ours, in: library) != nil)
    }

    @Test("title alone is never a match") func titleAloneNeverMatches() {
        let ours = Book(title: "Ein Titel", authors: ["Eine Autorin"])
        let library = CalibreLibrary(
            folder: URL(fileURLWithPath: "/tmp"), schema: CalibreSchema(userVersion: 1, isKnown: true),
            books: [calibreBook()])
        #expect(CalibreFieldSource.matching(ours, in: library) == nil)
    }

    @Test("a mismatched ISBN — neither UUID nor ISBN agree — is not a match")
    func mismatchedISBNIsNoMatch() {
        let ours = Book(title: "Ein Titel", authors: ["Eine Autorin"], identifiers: ["isbn": "9780132350884"])
        let library = CalibreLibrary(
            folder: URL(fileURLWithPath: "/tmp"), schema: CalibreSchema(userVersion: 1, isKnown: true),
            books: [calibreBook(isbn: "9780306406157")])
        #expect(CalibreFieldSource.matching(ours, in: library) == nil)
    }

    // MARK: - Filling

    @Test("fills every empty field the match carries, description reduced from HTML")
    func fillsEmptyFields() {
        let ours = Book(title: "Ein Titel", authors: ["Eine Autorin"])
        let match = calibreBook(
            description: "<p>Eine erfundene Beschreibung.</p>", publisher: "Erfundener Verlag", language: "de",
            series: SeriesRef(name: "Eine Reihe", index: 3))
        let result = CalibreFieldSource.fill(ours, from: match)

        #expect(result.book.description == "Eine erfundene Beschreibung.")
        #expect(result.book.publisher == "Erfundener Verlag")
        #expect(result.book.language == "de")
        #expect(result.book.series?.name == "Eine Reihe")
        #expect(result.book.series?.index == 3)
        #expect(result.proposals.allSatisfy { $0.source == .calibre })
        #expect(result.proposals.contains { $0.label == BookField.description.label })
    }

    @Test("never overwrites a field the book already has") func neverOverwrites() {
        var ours = Book(title: "Ein Titel", authors: ["Eine Autorin"], publisher: "Der eigene Verlag")
        ours.description = "Die eigene Beschreibung."
        let match = calibreBook(description: "Eine andere Beschreibung.", publisher: "Ein anderer Verlag")
        let result = CalibreFieldSource.fill(ours, from: match)

        #expect(result.book.publisher == "Der eigene Verlag")
        #expect(result.book.description == "Die eigene Beschreibung.")
        #expect(result.proposals.isEmpty)
    }

    @Test("tags are applied only when the book has none of its own") func tagsOnlyWhenNone() {
        let withNoTags = Book(title: "Ein Titel", authors: ["Eine Autorin"])
        let withTags = { () -> Book in
            var book = Book(title: "Ein Titel", authors: ["Eine Autorin"])
            book.tags = ["Eigener Tag"]
            return book
        }()
        let match = calibreBook(tags: ["Ein Tag", "Ein zweiter Tag"])

        let filledEmpty = CalibreFieldSource.fill(withNoTags, from: match)
        #expect(Set(filledEmpty.book.tags) == ["Ein Tag", "Ein zweiter Tag"])
        #expect(filledEmpty.proposals.contains { $0.label == "Tags" })

        let filledWithOwn = CalibreFieldSource.fill(withTags, from: match)
        #expect(filledWithOwn.book.tags == ["Eigener Tag"])
        #expect(!filledWithOwn.proposals.contains { $0.label == "Tags" })
    }

    @Test("an empty ISBN is filled, a checksum-invalid one is refused like a typed one")
    func isbnGoesThroughTheSameValidation() {
        let ours = Book(title: "Ein Titel", authors: ["Eine Autorin"])
        let valid = calibreBook(isbn: "9780306406157")
        let filled = CalibreFieldSource.fill(ours, from: valid)
        #expect(filled.book.identifiers["isbn"] == "9780306406157")
        #expect(filled.proposals.contains { $0.label == "ISBN" })

        // A wrong check digit — never a real book's own ISBN, invented for
        // the test — is refused exactly as `IdentifierEdit.set` refuses a
        // typed one.
        let invalidMatch = calibreBook(isbn: "9780306406158")
        let refused = CalibreFieldSource.fill(ours, from: invalidMatch)
        #expect(refused.book.identifiers["isbn"] == nil)
        #expect(!refused.proposals.contains { $0.label == "ISBN" })
    }
}

@Suite("Whether metadata.db is actually there to be read, without ever opening it")
struct CalibreSourceAvailabilityTests {
    @Test("a real, local metadata.db is available") func available() throws {
        let folder = try TemporaryFolder()
        FileManager.default.createFile(
            atPath: folder.url.appendingPathComponent("metadata.db").path, contents: Data("x".utf8))
        #expect(CalibreSourceAvailability.status(ofMetadataDB: folder.url) == .available)
    }

    @Test("no metadata.db at all is missing, not a crash") func missing() throws {
        let folder = try TemporaryFolder()
        #expect(CalibreSourceAvailability.status(ofMetadataDB: folder.url) == .missing)
    }

    @Test("an empty metadata.db (0 bytes) is missing — never a database Shelf would try to open")
    func zeroBytesIsMissing() throws {
        let folder = try TemporaryFolder()
        FileManager.default.createFile(atPath: folder.url.appendingPathComponent("metadata.db").path, contents: Data())
        #expect(CalibreSourceAvailability.status(ofMetadataDB: folder.url) == .missing)
    }
}
