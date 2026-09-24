import Testing

@testable import ShelfCore

@Suite("Field standardization (C3)")
struct FieldStandardizationTests {

    // MARK: - TitleStandardization

    @Test("Trims surrounding whitespace")
    func trimsWhitespace() {
        #expect(TitleStandardization.standardized("  Sturmlicht  ") == "Sturmlicht")
    }

    @Test("Collapses internal whitespace runs")
    func collapsesInternalWhitespace() {
        #expect(TitleStandardization.standardized("Sturmlicht   Band  1") == "Sturmlicht Band 1")
    }

    @Test("Removes a trailing merchant suffix")
    func removesMerchantSuffix() {
        #expect(TitleStandardization.standardized("Sturmlicht (German Edition)") == "Sturmlicht")
        #expect(TitleStandardization.standardized("Sturmlicht [eBook]") == "Sturmlicht")
        #expect(
            TitleStandardization.standardized("Nachtschatten (Deutsche Ausgabe)") == "Nachtschatten")
    }

    @Test("Removes several stacked merchant suffixes")
    func removesStackedSuffixes() {
        #expect(
            TitleStandardization.standardized("Sturmlicht (German Edition) (Kindle Edition)")
                == "Sturmlicht")
    }

    @Test("Is case-insensitive about the suffix")
    func suffixIsCaseInsensitive() {
        #expect(TitleStandardization.standardized("Sturmlicht (KINDLE EDITION)") == "Sturmlicht")
    }

    @Test("Never strips a title down to nothing")
    func neverEmptiesATitle() {
        #expect(TitleStandardization.standardized("eBook") == "eBook")
        #expect(TitleStandardization.standardized("(eBook)") == "(eBook)")
    }

    @Test("A title with nothing to standardize is returned unchanged")
    func unchangedTitleStaysExact() {
        #expect(TitleStandardization.standardized("Sturmlicht") == "Sturmlicht")
    }

    // MARK: - ISBNStandardization

    @Test("A valid ISBN-13 is normalised but not reparsed")
    func validISBN13StaysThirteen() {
        #expect(ISBNStandardization.standardized("978-0-306-40615-7") == "9780306406157")
    }

    @Test("A valid ISBN-10 is upgraded to its ISBN-13 form")
    func validISBN10BecomesThirteen() {
        // "0-306-40615-2" is the textbook example ISBN-10.
        let result = ISBNStandardization.standardized("0-306-40615-2")
        #expect(result?.count == 13)
        #expect(result?.hasPrefix("978") == true)
        #expect(result.map(ISBN.isValid) == true)
    }

    @Test("An invalid ISBN is dropped, never guessed at")
    func invalidISBNIsDropped() {
        #expect(ISBNStandardization.standardized("123") == nil)
        #expect(ISBNStandardization.standardized("0-306-40615-9") == nil)
    }

    // MARK: - TagFold

    @Test("Folds only case and whitespace")
    func foldsCaseAndWhitespace() {
        #expect(TagFold.normalized("Science Fiction") == TagFold.normalized("science  fiction"))
        #expect(TagFold.normalized(" Fantasy ") == TagFold.normalized("fantasy"))
    }

    @Test("Does not fold away accents or punctuation")
    func doesNotFoldAccentsOrPunctuation() {
        #expect(TagFold.normalized("Sci-Fi") != TagFold.normalized("SciFi"))
        #expect(TagFold.normalized("Fantasy") != TagFold.normalized("Fantásy"))
    }

    // MARK: - FieldStandardization

    private func book(
        title: String = "Sturmlicht", language: String? = nil, isbn: String? = nil,
        tags: [String] = []
    ) -> Book {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        return Book(title: title, language: language, tags: tags, identifiers: identifiers)
    }

    @Test("Standardizes title, language and ISBN together, in one change")
    func standardizesAllThreeFields() {
        let dirty = book(
            title: "Sturmlicht (Kindle Edition)", language: "eng", isbn: "0-306-40615-2")
        let change = FieldStandardization.change(for: dirty, tagMerges: [])
        #expect(change != nil)
        #expect(change?.after.title == "Sturmlicht")
        #expect(change?.after.language == "en")
        #expect(change?.after.identifiers["isbn"] == "9780306406157")
    }

    @Test("Drops an invalid stored ISBN outright")
    func dropsInvalidISBN() {
        let dirty = book(isbn: "0-306-40615-9")
        let change = FieldStandardization.change(for: dirty, tagMerges: [])
        #expect(change?.after.identifiers["isbn"] == nil)
    }

    @Test("A book already standardized produces no change")
    func alreadyStandardizedIsUnchanged() {
        let clean = book(title: "Sturmlicht", language: "en", isbn: "9780306406157")
        #expect(FieldStandardization.change(for: clean, tagMerges: []) == nil)
    }

    @Test("Applies every tag merge already decided for the library")
    func appliesTagMerges() {
        let dirty = book(tags: ["science  fiction", "Fantasy"])
        let merge = NameMerge(kind: .tag, sources: ["science  fiction"], target: "Science Fiction")
        let change = FieldStandardization.change(for: dirty, tagMerges: [merge])
        #expect(change?.after.tags.contains("Science Fiction") == true)
        #expect(change?.after.tags.contains("science  fiction") == false)
    }

    @Test("Plan computes the same tag merges for every book, once")
    func planFoldsTagsLibraryWide() throws {
        let a = book(title: "One", tags: ["Science Fiction"])
        let b = book(title: "Two", tags: ["science fiction"])
        let entries = [a, b].enumerated().map { index, book in
            LibraryEntry(book: book, number: index + 1, folder: book.title)
        }
        let plan = FieldStandardization.plan(over: entries)
        #expect(plan.bookCount == 1)
        let onlyChange = try #require(plan.changes.first)
        #expect(onlyChange.entry.book.title == "Two")
        #expect(onlyChange.change.after.tags == ["Science Fiction"])
    }
}
