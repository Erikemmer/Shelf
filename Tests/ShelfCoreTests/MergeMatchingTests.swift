import Foundation
import Testing

@testable import ShelfCore

/// B3's own rule for "sicher genug zum Zusammenführen": the same ISBN, or
/// the same normalised title and author with nothing that contradicts it.
@Suite("Grouping books into safe merge candidates")
struct MergeMatchingTests {

    // MARK: TitleNormalization

    @Test("a merchant's own bracketed annotation is stripped")
    func stripsMerchantSuffix() {
        #expect(TitleNormalization.matchable("Sturmlicht (German Edition)") == "sturmlicht")
        #expect(TitleNormalization.matchable("Schattenpfad (Kindle Edition)") == "schattenpfad")
        #expect(TitleNormalization.matchable("Der Prozess (Deutsche Ausgabe)") == "der prozess")
        #expect(TitleNormalization.matchable("Emma [eBook]") == "emma")
    }

    @Test("stacked annotations are all stripped")
    func stripsStackedSuffixes() {
        #expect(TitleNormalization.matchable("Title (German Edition) (Kindle Edition)") == "title")
    }

    @Test("a title that is only the annotation keeps its one word")
    func neverStripsToNothing() {
        #expect(TitleNormalization.matchable("eBook") == "ebook")
    }

    @Test("a doubled trailing number still collapses, as it already did")
    func stillFoldsDoubledNumbers() {
        #expect(
            TitleNormalization.matchable("A Desolation #164 164") == TitleNormalization.matchable("A Desolation #164"))
    }

    @Test("an unrelated title is not touched")
    func leavesOrdinaryTitlesAlone() {
        #expect(TitleNormalization.matchable("Dune") == "dune")
    }

    // MARK: AuthorNameFold

    @Test("order and punctuation do not make two spellings different people")
    func foldsOrderAndPunctuation() {
        #expect(AuthorNameFold.normalized("Fitzek, Sebastian") == AuthorNameFold.normalized("Sebastian Fitzek"))
        #expect(AuthorNameFold.normalized("Hartmann, Cole") == AuthorNameFold.normalized("Cole Hartmann"))
    }

    @Test("an initial for a full first name is NOT folded the same — that needs Teil C's own confirmation")
    func doesNotFoldInitialsAgainstFullNames() {
        #expect(AuthorNameFold.normalized("J. Zeh") != AuthorNameFold.normalized("Juli Zeh"))
    }

    @Test("genuinely different people stay different")
    func leavesDifferentPeopleAlone() {
        #expect(AuthorNameFold.normalized("R. Voss") != AuthorNameFold.normalized("M. Lindqvist"))
    }

    // MARK: MergeCandidates

    private func entry(
        title: String, author: String, isbn: String? = nil, language: String? = nil, number: Int
    ) -> LibraryEntry {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        let book = Book(title: title, authors: [author], language: language, identifiers: identifiers)
        return LibraryEntry(book: book, number: number, folder: "\(author)/\(title) (\(number))")
    }

    @Test("the same valid ISBN groups two books regardless of title or author spelling")
    func groupsByISBN() {
        let a = entry(title: "Sturmlicht", author: "A. Brennecke", isbn: "9783404178926", number: 1)
        let b = entry(title: "Storm Ember (German Edition)", author: "S. Beckett", isbn: "978-3-404-17892-6", number: 2)
        let groups = MergeCandidates.certainGroups(among: [a, b])
        #expect(groups.count == 1)
        #expect(Set(groups[0].bookIDs) == [a.id, b.id])
    }

    @Test("an invalid ISBN string does not group books by coincidence")
    func invalidISBNsNeverGroup() {
        // Too short to be any real ISBN, and identical on both books – if
        // this grouped, it would be by coincidence, not by an actual
        // checksum-valid identifier the two books share.
        let a = entry(title: "Book One", author: "A", isbn: "123", number: 1)
        let b = entry(title: "Book Two", author: "B", isbn: "123", number: 2)
        #expect(MergeCandidates.certainGroups(among: [a, b]).isEmpty)
    }

    @Test("same normalised title and author, no ISBN, groups")
    func groupsByTitleAndAuthor() {
        let a = entry(title: "Schattenpfad", author: "A. Brennecke", number: 1)
        let b = entry(title: "Schattenpfad (German Edition)", author: "A. Brennecke", number: 2)
        let groups = MergeCandidates.certainGroups(among: [a, b])
        #expect(groups.count == 1)
        #expect(Set(groups[0].bookIDs) == [a.id, b.id])
    }

    @Test("an author spelling swap still groups, via the safe fold")
    func groupsAcrossAuthorOrderSwap() {
        let a = entry(title: "Nachtfrost", author: "Sebastian Fitzek", number: 1)
        let b = entry(title: "Nachtfrost", author: "Fitzek, Sebastian", number: 2)
        let groups = MergeCandidates.certainGroups(among: [a, b])
        #expect(groups.count == 1)
    }

    @Test("a different language is a different edition — counted, not merged")
    func differentLanguageNeverGroups() {
        let a = entry(title: "Emma", author: "Jane Austen", language: "en", number: 1)
        let b = entry(title: "Emma", author: "Jane Austen", language: "de", number: 2)
        #expect(MergeCandidates.certainGroups(among: [a, b]).isEmpty)
    }

    /// A MOBI's EXTH record and an EPUB's `dc:language` routinely disagree on
    /// the *code* for the very same language — found live in the real
    /// library, six pairs of it, all six the same book in two formats.
    @Test("a two-letter and a three-letter code for the same language are not a conflict")
    func sameLanguageDifferentCodeStillGroups() {
        let a = entry(title: "Ohne Erinnerung", author: "L. Brandt", language: "eng", number: 1)
        let b = entry(title: "Ohne Erinnerung", author: "Brandt, L.", language: "en", number: 2)
        let groups = MergeCandidates.certainGroups(among: [a, b])
        #expect(groups.count == 1)
    }

    /// Found live in the real library: an EPUB with no recorded ISBN beside
    /// a MOBI whose EXTH record has one. An ISBN present on one side and
    /// absent on the other is a gap, not a conflict — only two books whose
    /// ISBNs actually *disagree* are a different edition.
    @Test("one book with an ISBN and one without still group, if nothing disagrees")
    func isbnPresentOnOneSideOnlyStillGroups() {
        let a = entry(title: "Nachtschatten", author: "R. Voss", number: 1)
        let b = entry(title: "Nachtschatten", author: "Voss, R.", isbn: "9780000000019", number: 2)
        let groups = MergeCandidates.certainGroups(among: [a, b])
        #expect(groups.count == 1)
        #expect(Set(groups[0].bookIDs) == [a.id, b.id])
    }

    @Test("a conflicting ISBN never groups, even with the same title and author")
    func conflictingISBNNeverGroups() {
        let a = entry(title: "Emma", author: "Jane Austen", isbn: "9780141439587", number: 1)
        let b = entry(title: "Emma", author: "Jane Austen", isbn: "9780199535576", number: 2)
        #expect(MergeCandidates.certainGroups(among: [a, b]).isEmpty)
    }

    @Test("a shared title with a different author never groups")
    func differentAuthorNeverGroups() {
        let a = entry(title: "Emma", author: "Jane Austen", number: 1)
        let b = entry(title: "Emma", author: "Someone Else", number: 2)
        #expect(MergeCandidates.certainGroups(among: [a, b]).isEmpty)
    }

    @Test("a lone book groups with nothing")
    func loneBookNeverGroups() {
        let a = entry(title: "Solo", author: "Nobody Else", number: 1)
        #expect(MergeCandidates.certainGroups(among: [a]).isEmpty)
    }

    @Test("three books of the same work all land in one group, not three pairs")
    func threeWayGroup() {
        let a = entry(title: "Schattenpfad", author: "A. Brennecke", number: 1)
        let b = entry(title: "Schattenpfad", author: "A. Brennecke", number: 2)
        let c = entry(title: "Schattenpfad", author: "A. Brennecke", number: 3)
        let groups = MergeCandidates.certainGroups(among: [a, b, c])
        #expect(groups.count == 1)
        #expect(Set(groups[0].bookIDs) == [a.id, b.id, c.id])
    }

    @Test("a book already grouped by ISBN is not grouped again by title and author")
    func noBookInTwoGroups() {
        let a = entry(title: "Schattenpfad", author: "A. Brennecke", isbn: "9783404178926", number: 1)
        let b = entry(title: "Schattenpfad", author: "A. Brennecke", isbn: "978-3-404-17892-6", number: 2)
        let c = entry(title: "Schattenpfad", author: "A. Brennecke", number: 3)
        let groups = MergeCandidates.certainGroups(among: [a, b, c])
        // a+b group by ISBN; c has none, so it groups with nobody under the
        // title+author rule alone unless it happens to match one of them —
        // here it would, by title+author, but a and b are already spoken for.
        // Every book still appears in at most one group.
        let seen = groups.flatMap(\.bookIDs)
        #expect(seen.count == Set(seen).count)
    }
}
