import Foundation
import Testing

@testable import ShelfCore

/// "Ähnliche Schreibweisen…" — proposing groups, never merging them. Every
/// test here checks a proposal is *offered*; none of them checks that
/// anything gets merged, because this type never merges anything (ADR 0018).
@Suite("Proposing similar author and publisher spellings")
struct SimilarSpellingsTests {

    private func entry(title: String, author: String, series: String? = nil, number: Int) -> LibraryEntry {
        let book = Book(
            title: title, authors: [author], series: series.map { SeriesRef(name: $0) })
        return LibraryEntry(book: book, number: number, folder: "\(author)/\(title) (\(number))")
    }

    // MARK: Authors — the safe fold

    @Test("order and punctuation variants of one author are proposed as a group")
    func safeFoldGroups() {
        let entries = [
            entry(title: "Book One", author: "Jonas Ahlberg", number: 1),
            entry(title: "Book Two", author: "Ahlberg, Jonas", number: 2),
        ]
        let groups = SimilarSpellings.authorGroups(among: entries)
        #expect(groups.count == 1)
        #expect(Set(groups[0].spellings) == ["Jonas Ahlberg", "Ahlberg, Jonas"])
        #expect(groups[0].winner == "Jonas Ahlberg")
    }

    @Test("unrelated authors are never grouped")
    func unrelatedAuthorsNeverGroup() {
        let entries = [
            entry(title: "Book One", author: "Jonas Ahlberg", number: 1),
            entry(title: "Book Two", author: "Nora Lindqvist", number: 2),
        ]
        #expect(SimilarSpellings.authorGroups(among: entries).isEmpty)
    }

    // MARK: Authors — the riskier initials rule

    @Test("an initial groups with the one full name sharing its surname and a work")
    func initialsGroupWithExactlyOneFullNameSharingAWork() {
        let entries = [
            entry(title: "Nachtfrost", author: "J. Ahlberg", number: 1),
            entry(title: "Nachtfrost", author: "Jonas Ahlberg", number: 2),
        ]
        let groups = SimilarSpellings.authorGroups(among: entries)
        #expect(groups.count == 1)
        #expect(Set(groups[0].spellings) == ["J. Ahlberg", "Jonas Ahlberg"])
        #expect(groups[0].winner == "Jonas Ahlberg")
    }

    @Test("an initial groups with the one full name sharing its surname and a series")
    func initialsGroupWithExactlyOneFullNameSharingASeries() {
        let entries = [
            entry(title: "Book One", author: "J. Ahlberg", series: "The Long Winter", number: 1),
            entry(title: "Book Two", author: "Jonas Ahlberg", series: "The Long Winter", number: 2),
        ]
        let groups = SimilarSpellings.authorGroups(among: entries)
        #expect(groups.count == 1)
    }

    @Test("an initial never groups without a shared work or series, however similar the name")
    func initialsNeverGroupWithoutSharedWorkOrSeries() {
        let entries = [
            entry(title: "Book One", author: "J. Ahlberg", number: 1),
            entry(title: "Book Two", author: "Jonas Ahlberg", number: 2),
        ]
        #expect(SimilarSpellings.authorGroups(among: entries).isEmpty)
    }

    @Test("an initial is left alone when two different full names share its surname")
    func initialsNeverGroupWhenAmbiguous() {
        let entries = [
            entry(title: "Nachtfrost", author: "J. Ahlberg", number: 1),
            entry(title: "Nachtfrost", author: "Jonas Ahlberg", number: 2),
            entry(title: "Nachtfrost", author: "Julia Ahlberg", number: 3),
        ]
        // "Jonas" and "Julia" both fit "J. Ahlberg" — genuinely ambiguous,
        // left for a person, not guessed at.
        #expect(SimilarSpellings.authorGroups(among: entries).isEmpty)
    }

    @Test("two authors with different surnames never group, whatever their first names look like")
    func differentSurnamesNeverGroup() {
        let entries = [
            entry(title: "Nachtfrost", author: "J. Ahlberg", number: 1),
            entry(title: "Nachtfrost", author: "Jonas Lindqvist", number: 2),
        ]
        #expect(SimilarSpellings.authorGroups(among: entries).isEmpty)
    }

    // MARK: Publishers

    @Test("a legal-form suffix folds into the shorter spelling's group")
    func publisherLegalSuffixGroups() {
        let entries = [
            entry(title: "Book One", author: "A", number: 1),
            entry(title: "Book Two", author: "B", number: 2),
        ]
        var withPublishers = entries
        withPublishers[0].book.publisher = "Canongate Books"
        withPublishers[1].book.publisher = "Canongate Books Ltd"
        let groups = SimilarSpellings.publisherGroups(among: withPublishers)
        #expect(groups.count == 1)
        #expect(groups[0].winner == "Canongate Books Ltd")
    }

    @Test("two genuinely different publishers never group")
    func differentPublishersNeverGroup() {
        var entries = [
            entry(title: "Book One", author: "A", number: 1),
            entry(title: "Book Two", author: "B", number: 2),
        ]
        entries[0].book.publisher = "Rowohlt"
        entries[1].book.publisher = "Fischer"
        #expect(SimilarSpellings.publisherGroups(among: entries).isEmpty)
    }

    // MARK: asMerge

    @Test("a group's asMerge folds every spelling but the winner into it")
    func asMergeFoldsEverythingButTheWinner() {
        let group = SimilarSpellingGroup(
            kind: .author, winner: "Jonas Ahlberg", spellings: ["Ahlberg, Jonas", "J. Ahlberg", "Jonas Ahlberg"],
            bookCounts: [:])
        let merge = group.asMerge
        #expect(merge.target == "Jonas Ahlberg")
        #expect(Set(merge.sources) == ["Ahlberg, Jonas", "J. Ahlberg"])
    }
}
