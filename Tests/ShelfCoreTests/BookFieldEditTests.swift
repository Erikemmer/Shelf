import Foundation
import Testing

@testable import ShelfCore

/// The rules that turn what a person typed into a change.
///
/// Every one of them is a rule that can be quietly wrong in a way no build
/// catches: an empty field that writes an empty element, a sort title silently
/// overwritten, "2,5" read as nothing, an ISBN with two digits swapped accepted
/// as a duplicate key. They are in the core rather than in a `TextField`
/// binding precisely so they can be tested here.
@Suite("Editing one field")
struct BookFieldEditTests {

    private func book() -> Book {
        Book(
            title: "The Dispossessed",
            authors: ["Ursula K. Le Guin"],
            series: SeriesRef(name: "Hainish Cycle", index: 6),
            publisher: "Gollancz",
            published: Date(timeIntervalSince1970: 1_000_000_000),
            language: "en",
            description: "Two worlds, one wall.",
            tags: ["science fiction"],
            identifiers: ["isbn": "9780061054884"])
    }

    /// The property the whole type exists for: what a field shows is always
    /// something the same field accepts back. Without it a field that displays
    /// "2019" and parses "yyyy-MM-dd" rewrites the book on every visit.
    @Test("what a field shows is what the field accepts – for every field")
    func displayAndParseAgree() {
        let start = book()
        for field in BookField.allCases {
            let shown = field.text(of: start)
            let outcome = field.apply(shown, to: start)
            #expect(outcome == .unchanged, "\(field.label) changed the book by showing it its own value")
        }
    }

    @Test("an empty value removes the element rather than writing an empty one")
    func emptyRemoves() throws {
        var subject = book()
        for field in [BookField.publisher, .language, .description] {
            guard case .changed(let edited) = field.apply("   ", to: subject) else {
                Issue.record("\(field.label) did not accept an empty value")
                continue
            }
            subject = edited
        }
        #expect(subject.publisher == nil)
        #expect(subject.language == nil)
        #expect(subject.description == nil)

        // And the OPF then has no element at all – not an empty one.
        let text = OPFDocument.render(subject)
        #expect(!text.contains("<dc:publisher>"))
        #expect(!text.contains("<dc:language>"))
        #expect(!text.contains("<dc:description>"))
    }

    @Test("an empty date clears the date")
    func emptyDate() throws {
        guard case .changed(let edited) = BookField.published.apply("", to: book()) else {
            Issue.record("the date was not cleared")
            return
        }
        #expect(edited.published == nil)
        #expect(!OPFDocument.render(edited).contains("<dc:date>"))
    }

    // MARK: Title

    @Test("a title may not be empty – it names the folder the book lives in")
    func titleMustNotBeEmpty() {
        #expect(BookField.title.apply("", to: book()) == .rejected(.titleMustNotBeEmpty))
        #expect(BookField.title.apply("   \n ", to: book()) == .rejected(.titleMustNotBeEmpty))
    }

    @Test("a new title pulls the sort title with it")
    func titleSortFollows() throws {
        // "The Dispossessed" sorts as "Dispossessed, The" – derived, untouched.
        guard case .changed(let edited) = BookField.title.apply("The Left Hand of Darkness", to: book()) else {
            Issue.record("the title did not change")
            return
        }
        #expect(edited.titleSort == "Left Hand of Darkness, The")
    }

    @Test("a sort title somebody set by hand is not overwritten by a title change")
    func handwrittenTitleSortSurvives() throws {
        var subject = book()
        subject.titleSort = "Dispossessed !!"
        guard case .changed(let edited) = BookField.title.apply("The Dispossessed (Revised)", to: subject) else {
            Issue.record("the title did not change")
            return
        }
        #expect(edited.titleSort == "Dispossessed !!")
    }

    // MARK: Authors

    @Test("several authors keep the order they were typed in")
    func authorOrder() throws {
        guard
            case .changed(let edited) = BookField.authors.apply(
                "Neil Gaiman & Terry Pratchett", to: book())
        else {
            Issue.record("the authors did not change")
            return
        }
        #expect(edited.authors == ["Neil Gaiman", "Terry Pratchett"])
        // The order is data: the first author decides the folder.
        #expect(edited.primaryAuthor == "Neil Gaiman")
    }

    /// The reason the separator is "&" and not ",". `AuthorSort` reads a comma
    /// as "already in sort form", so splitting on commas would turn one author
    /// into two.
    @Test("a name in sort form is one author, not two")
    func sortFormIsOneAuthor() throws {
        guard case .changed(let edited) = BookField.authors.apply("Austen, Jane", to: book()) else {
            Issue.record("the authors did not change")
            return
        }
        #expect(edited.authors == ["Austen, Jane"])
    }

    @Test("empty names between separators are dropped rather than stored")
    func emptyAuthorsDropped() throws {
        guard case .changed(let edited) = BookField.authors.apply(" A &  & B & ", to: book()) else {
            Issue.record("the authors did not change")
            return
        }
        #expect(edited.authors == ["A", "B"])
    }

    /// AuthorSort is not a field on `Book`: it is derived wherever it is needed,
    /// which is what makes it follow a change without anybody maintaining it.
    /// Proved through the file, because that is where it is visible.
    @Test("the author sort form follows a changed author into the OPF")
    func authorSortFollowsIntoTheFile() throws {
        guard case .changed(let edited) = BookField.authors.apply("Jane Austen", to: book()) else {
            Issue.record("the authors did not change")
            return
        }
        let text = OPFDocument.render(edited)
        #expect(text.contains("opf:file-as=\"Austen, Jane\""))
        #expect(!text.contains("Le Guin"))
    }

    // MARK: Series

    @Test("a series index may be a decimal, with a point or a comma")
    func seriesIndexDecimal() throws {
        for typed in ["2.5", "2,5"] {
            guard case .changed(let edited) = BookField.seriesIndex.apply(typed, to: book()) else {
                Issue.record("“\(typed)” was not accepted")
                continue
            }
            #expect(edited.series?.index == 2.5)
        }
    }

    @Test("a series index that is not a number is refused, and says so")
    func seriesIndexRejected() {
        #expect(BookField.seriesIndex.apply("later", to: book()) == .rejected(.notANumber("later")))
        #expect(BookField.seriesIndex.apply("-3", to: book()) == .rejected(.notANumber("-3")))
        if case .rejected(let why) = BookField.seriesIndex.apply("later", to: book()) {
            #expect(why.message.contains("2.5"))
        }
    }

    @Test("clearing the series name removes the series and its index with it")
    func clearingSeries() throws {
        guard case .changed(let edited) = BookField.seriesName.apply("", to: book()) else {
            Issue.record("the series was not cleared")
            return
        }
        #expect(edited.series == nil)
        let text = OPFDocument.render(edited)
        #expect(!text.contains("calibre:series"))
    }

    @Test("clearing only the index keeps the series")
    func clearingIndexKeepsSeries() throws {
        guard case .changed(let edited) = BookField.seriesIndex.apply("", to: book()) else {
            Issue.record("the index was not cleared")
            return
        }
        #expect(edited.series?.name == "Hainish Cycle")
        #expect(edited.series?.index == nil)
        let text = OPFDocument.render(edited)
        #expect(text.contains("calibre:series\""))
        #expect(!text.contains("calibre:series_index"))
    }

    @Test("an index typed for a book in no series changes nothing")
    func indexWithoutSeries() {
        var subject = book()
        subject.series = nil
        #expect(BookField.seriesIndex.apply("3", to: subject) == .unchanged)
    }

    // MARK: Dates

    @Test("a date is accepted as a year, a month or a day")
    func dateShapes() throws {
        for typed in ["2019", "2019-04", "2019-04-01"] {
            guard case .changed = BookField.published.apply(typed, to: book()) else {
                Issue.record("“\(typed)” was not accepted as a date")
                continue
            }
        }
    }

    @Test("a date that is not a date is refused, and says what one looks like")
    func dateRejected() {
        guard case .rejected(let why) = BookField.published.apply("last spring", to: book()) else {
            Issue.record("“last spring” was accepted as a date")
            return
        }
        #expect(why.message.contains("2019-04-01"))
    }

    // MARK: Identifiers

    @Test("an ISBN with a wrong check digit is refused")
    func isbnCheckDigit() {
        // 9780061054884 is valid; swapping two digits is the usual typo.
        guard
            case .rejected(let why) = IdentifierEdit.set(
                scheme: "isbn", value: "9780061054848", in: book())
        else {
            Issue.record("a wrong ISBN was accepted")
            return
        }
        #expect(why == .isbnCheckDigit("9780061054848"))
        #expect(why.message.contains("check digit"))
    }

    @Test("a valid ISBN is stored as typed, hyphens and all")
    func isbnStoredAsTyped() throws {
        guard
            case .changed(let edited) = IdentifierEdit.set(
                scheme: "ISBN", value: "978-0-306-40615-7", in: book())
        else {
            Issue.record("a valid ISBN was refused")
            return
        }
        #expect(edited.identifiers["isbn"] == "978-0-306-40615-7")
        // And the comparison form is the digits alone.
        #expect(edited.isbn == "9780306406157")
    }

    @Test("an identifier that is not an ISBN is not check-summed")
    func otherIdentifiersAreNotValidated() throws {
        guard
            case .changed(let edited) = IdentifierEdit.set(
                scheme: "asin", value: "B00X57B4JG", in: book())
        else {
            Issue.record("an ASIN was refused")
            return
        }
        #expect(edited.identifiers["asin"] == "B00X57B4JG")
    }

    @Test("an empty value removes the identifier rather than storing an empty one")
    func emptyIdentifierRemoves() throws {
        guard case .changed(let edited) = IdentifierEdit.remove(scheme: "isbn", from: book()) else {
            Issue.record("the identifier was not removed")
            return
        }
        #expect(edited.identifiers["isbn"] == nil)
        #expect(!OPFDocument.render(edited).contains("opf:scheme=\"ISBN\""))
    }

    @Test("a value with no scheme is refused, and a scheme with no value is nothing")
    func schemeRequired() {
        #expect(
            IdentifierEdit.set(scheme: "", value: "12345", in: book())
                == .rejected(.identifierNeedsAScheme))
        #expect(IdentifierEdit.set(scheme: "", value: "", in: book()) == .unchanged)
    }

    /// The duplicate check's own derived row is not something a book claims
    /// about itself; letting it in would write `opf:scheme="ISBN_NORMALISED"`
    /// into every OPF.
    @Test("isbn_normalised cannot be set by hand")
    func normalisedISBNIsNotEditable() {
        #expect(
            IdentifierEdit.set(scheme: "isbn_normalised", value: "9780306406157", in: book())
                == .unchanged)
    }

    // MARK: Tags

    @Test("a tag is added, and the same tag again changes nothing")
    func addTag() throws {
        guard case .changed(let edited) = TagEdit.add("utopia", to: book()) else {
            Issue.record("the tag was not added")
            return
        }
        #expect(edited.tags == ["science fiction", "utopia"])
        #expect(TagEdit.add("utopia", to: edited) == .unchanged)
    }

    @Test("a tag that differs only in case is the same tag, and the library's spelling wins")
    func tagCaseFolding() throws {
        #expect(TagEdit.add("Science Fiction", to: book()) == .unchanged)
        // A tag the library already knows keeps its spelling rather than
        // gaining a second one.
        guard
            case .changed(let edited) = TagEdit.add(
                "SPACE OPERA", to: book(), knownTags: ["space opera", "fantasy"])
        else {
            Issue.record("the tag was not added")
            return
        }
        #expect(edited.tags.contains("space opera"))
        #expect(!edited.tags.contains("SPACE OPERA"))
    }

    @Test("removing a tag is case-insensitive too")
    func removeTag() throws {
        guard case .changed(let edited) = TagEdit.remove("SCIENCE FICTION", from: book()) else {
            Issue.record("the tag was not removed")
            return
        }
        #expect(edited.tags.isEmpty)
        #expect(TagEdit.remove("nothing like it", from: book()) == .unchanged)
    }

    @Test("an empty tag is not a tag")
    func emptyTag() {
        #expect(TagEdit.add("   ", to: book()) == .unchanged)
    }

    @Test("each tag is its own dc:subject element, the way Calibre writes them")
    func tagsAreOneElementEach() throws {
        guard case .changed(let edited) = TagEdit.add("utopia", to: book()) else { return }
        let text = OPFDocument.render(edited)
        #expect(text.contains("<dc:subject>science fiction</dc:subject>"))
        #expect(text.contains("<dc:subject>utopia</dc:subject>"))
    }

    // MARK: Completion

    @Test("completion offers what starts with the text before what merely contains it")
    func completionOrder() {
        let known = ["classics", "science fiction", "scifi shelf", "translated"]
        let offered = TagEdit.completions(for: "sci", among: known, excluding: [])
        #expect(offered == ["science fiction", "scifi shelf"])
    }

    @Test("completion never offers a tag the book already carries")
    func completionExcludesExisting() {
        let known = ["science fiction", "space opera"]
        let offered = TagEdit.completions(for: "s", among: known, excluding: ["Science Fiction"])
        #expect(offered == ["space opera"])
    }

    @Test("an empty field offers the first few tags rather than nothing")
    func completionWithoutText() {
        let known = ["a", "b", "c", "d", "e", "f", "g", "h"]
        #expect(TagEdit.completions(for: "", among: known, excluding: []).count == 6)
        #expect(TagEdit.completions(for: "", among: known, excluding: [], limit: 2) == ["a", "b"])
    }
}

/// The ISBN check digit, which is the only thing that catches a transposed pair
/// of digits – the most common mistake in typing thirteen of them.
@Suite("ISBN")
struct ISBNTests {

    @Test("real ISBN-13s are accepted")
    func validThirteen() {
        for isbn in ["9780061054884", "978-0-306-40615-7", "9780140328721"] {
            #expect(ISBN.isValid(isbn), "\(isbn) should be valid")
        }
    }

    @Test("real ISBN-10s are accepted, X included")
    func validTen() {
        for isbn in ["0306406152", "0-306-40615-2", "080442957X", "155860832X"] {
            #expect(ISBN.isValid(isbn), "\(isbn) should be valid")
        }
    }

    @Test("a transposed pair of digits is caught")
    func transposition() {
        #expect(ISBN.isValid("9780306406157"))
        #expect(!ISBN.isValid("9780306406175"))
        #expect(ISBN.isValid("0306406152"))
        #expect(!ISBN.isValid("0306406125"))
    }

    @Test("the wrong number of digits is not an ISBN")
    func length() {
        #expect(!ISBN.isValid(""))
        #expect(!ISBN.isValid("123456789"))
        #expect(!ISBN.isValid("12345678901"))
        #expect(!ISBN.isValid("97803064061570"))
    }

    @Test("X is only ever the check digit")
    func misplacedX() {
        #expect(!ISBN.isValid("X306406152"))
        #expect(!ISBN.isValid("030X406152"))
        // And never in a 13.
        #expect(!ISBN.isValid("978030640615X"))
    }

    @Test("hyphens, spaces and a lower-case x do not change the answer")
    func normalisation() {
        #expect(ISBN.normalised("978-0-306 40615-7") == "9780306406157")
        #expect(ISBN.normalised("08044 2957x") == "080442957X")
        #expect(ISBN.isValid("080442957x"))
    }

    @Test("letters other than X are not digits")
    func letters() {
        #expect(!ISBN.isValid("97803064O6157"))
    }
}
