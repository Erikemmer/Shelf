import Foundation
import Testing

@testable import ShelfCore

/// Renaming one spelling, and folding several into one.
///
/// The scenario every test here comes back to is the one that started Sprint 8:
/// one person in the library as "Marek Voss", "Voss, Marek" and
/// "M. Voss", which is three authors and three folders and no defect
/// anywhere — three different strings really are three different strings.
@Suite("Renaming and merging the names books share")
struct NameEditTests {

    private func entry(
        _ title: String, authors: [String] = [], series: SeriesRef? = nil,
        publisher: String? = nil, tags: [String] = []
    ) -> LibraryEntry {
        let book = Book(
            title: title, authors: authors, series: series, publisher: publisher, tags: tags)
        return LibraryEntry(book: book, number: 1, folder: "x/\(title)", formats: [])
    }

    // MARK: Authors

    @Test("three spellings of one author become one, and each book is one change")
    func mergeAuthors() {
        let entries = [
            entry("Kältestarre", authors: ["Marek Voss"]),
            entry("Das Kind", authors: ["Voss, Marek"]),
            entry("Nebelriss", authors: ["M. Voss"]),
            entry("Pride and Prejudice", authors: ["Jane Austen"]),
        ]
        let merge = NameMerge(
            kind: .author, sources: ["Voss, Marek", "M. Voss"], target: "Marek Voss")
        let plan = NameEdit.plan(merge, over: entries)

        // The book that already spells it right is not rewritten: a change
        // that changes nothing is not written.
        #expect(plan.bookCount == 2)
        #expect(plan.changes.allSatisfy { $0.change.after.authors == ["Marek Voss"] })
        // And Jane Austen is untouched, which is the whole of "Shelf never chooses".
        #expect(!plan.changes.contains { $0.entry.book.title == "Pride and Prejudice" })
        // Without the count: the window adds that through the same frame it
        // uses for every other edit across a selection, so it is the
        // catalogue that pluralises it.
        #expect(plan.merge.actionName == "Merge Authors")
        #expect(NameMerge.rename(.author, from: "a", to: "b").actionName == "Rename Author")
    }

    @Test("a book carrying two of the spellings ends up with one author, not two")
    func twoSpellingsOnOneBook() {
        let book = entry("An anthology", authors: ["M. Voss", "Marek Voss", "Jane Austen"]).book
        let merge = NameMerge(kind: .author, sources: ["M. Voss"], target: "Marek Voss")
        let edited = NameEdit.replacing(merge, in: book)
        #expect(edited?.authors == ["Marek Voss", "Jane Austen"])
    }

    /// The order of the authors is data — the first one names the folder and
    /// the cover prints them in order — so a merge may not shuffle it.
    @Test("the order of the remaining authors is kept")
    func orderIsKept() {
        let book = entry("Good Omens", authors: ["Terry Pratchett", "N. Gaiman"]).book
        let merge = NameMerge(kind: .author, sources: ["N. Gaiman"], target: "Neil Gaiman")
        #expect(NameEdit.replacing(merge, in: book)?.authors == ["Terry Pratchett", "Neil Gaiman"])
    }

    // MARK: Case

    /// The rename that only changes the capitalisation has to work, which is
    /// why the sources are matched exactly and not folded.
    @Test("a rename that only changes the capitalisation is a real change")
    func capitalisationOnly() {
        let book = entry("A book", authors: ["voss"]).book
        let merge = NameMerge.rename(.author, from: "voss", to: "Voss")
        let change = NameEdit.change(merge, to: book)
        #expect(change?.after.authors == ["Voss"])
    }

    /// …and the target's spelling wins when the replacement collides with a
    /// sibling that differs only in case. TagEdit's rule is the opposite — the
    /// library's existing spelling wins — and this is the one place it should
    /// not apply, because somebody has just said how it should read.
    @Test("when the new spelling collides with one differing only in case, the new one wins")
    func targetWinsTheSpelling() {
        let book = entry("A book", tags: ["Sci-Fi", "space opera"]).book
        let merge = NameMerge.rename(.tag, from: "space opera", to: "sci-fi")
        let edited = NameEdit.replacing(merge, in: book)
        #expect(edited?.tags == ["sci-fi"])
    }

    // MARK: The other three kinds

    @Test("a series keeps its index when its name changes")
    func seriesKeepsIndex() {
        let book = entry("Mistborn 3", series: SeriesRef(name: "mistborn", index: 3.5)).book
        let merge = NameMerge.rename(.series, from: "mistborn", to: "Mistborn")
        let edited = NameEdit.replacing(merge, in: book)
        #expect(edited?.series == SeriesRef(name: "Mistborn", index: 3.5))
    }

    @Test("publishers and tags merge the same way")
    func publishersAndTags() {
        let entries = [
            entry("One", publisher: "Droemer Knaur", tags: ["scifi"]),
            entry("Two", publisher: "Droemer/Knaur", tags: ["Sci-Fi", "classic"]),
        ]
        let publishers = NameEdit.plan(
            NameMerge(kind: .publisher, sources: ["Droemer/Knaur"], target: "Droemer Knaur"),
            over: entries)
        #expect(publishers.bookCount == 1)
        #expect(publishers.changes.first?.change.after.publisher == "Droemer Knaur")

        let tags = NameEdit.plan(
            NameMerge(kind: .tag, sources: ["scifi", "Sci-Fi"], target: "science fiction"),
            over: entries)
        #expect(tags.bookCount == 2)
        // Sorted, because everything that holds tags is (Book.tags).
        #expect(tags.changes.last?.change.after.tags == ["classic", "science fiction"])
    }

    /// Two quite different nothings, told apart. Found by looking at a
    /// screenshot of the sheet: ticking one spelling and typing that same
    /// spelling read "No book carries that name", with three books listed one
    /// line above it.
    @Test("an empty plan says whether nobody carries the name or everybody already does")
    func twoKindsOfNothing() {
        let entries = [
            entry("One", authors: ["Marek Voss"]),
            entry("Two", authors: ["Marek Voss"]),
            entry("Three", authors: ["Jane Austen"]),
        ]
        // Ticked and typed the same: nothing to do, but the books are there.
        let noop = NameEdit.plan(
            NameMerge.rename(.author, from: "Marek Voss", to: "Marek Voss"),
            over: entries)
        #expect(noop.isEmpty)
        #expect(noop.carrying == 2)
        #expect(noop.summary() == "2 books already read that way — nothing to change")

        // A spelling the library has never heard of.
        let absent = NameEdit.plan(
            NameMerge.rename(.author, from: "Nobody At All", to: "Somebody"), over: entries)
        #expect(absent.isEmpty)
        #expect(absent.carrying == 0)
        #expect(absent.summary() == "No book carries that spelling")
    }

    // MARK: What it refuses

    @Test("an empty name, a name with a slash and an empty selection are refused with a sentence")
    func refusals() {
        #expect(NameMerge(kind: .author, sources: ["a"], target: "   ").refusal != nil)
        #expect(NameMerge(kind: .tag, sources: ["a"], target: "Fiction/Sci-Fi").refusal != nil)
        #expect(NameMerge(kind: .author, sources: [], target: "Jane Austen").refusal != nil)
        #expect(NameMerge(kind: .author, sources: ["a"], target: " Jane Austen ").refusal == nil)
        // And the trimmed value is what gets written.
        let book = entry("x", authors: ["a"]).book
        #expect(
            NameEdit.replacing(NameMerge(kind: .author, sources: ["a"], target: " Jane Austen "), in: book)?
                .authors == ["Jane Austen"])
    }

    @Test("a refused merge produces no change at all, rather than a bad one")
    func refusedMergeChangesNothing() {
        let book = entry("x", authors: ["a"]).book
        #expect(NameEdit.change(NameMerge(kind: .author, sources: ["a"], target: ""), to: book) == nil)
    }

    // MARK: The sort keys

    /// The brief asks that `AuthorSort` and `TitleSort` be recomputed. They
    /// are not stored on the `Book` — the index computes them when it writes
    /// the row — so the thing to check is that a merged library sorts by the
    /// *new* name, through the index, and not by the old one.
    @Test("after a merge the index sorts by the new name, not the old one")
    func sortKeysFollow() async throws {
        let index = try LibraryIndex(inMemory: "merge-sort")

        var zebra = entry("Zebra", authors: ["Voss, Marek"])
        try await index.save(zebra)
        // "Voss, Marek" already sorts as itself; the merged spelling
        // "Marek Voss" has to be filed under F as well, which is the
        // thing a fresh name_sort buys.
        #expect(try await index.authorFacets().map { $0.name } == ["Voss, Marek"])

        let merge = NameMerge.rename(.author, from: "Voss, Marek", to: "Marek Voss")
        zebra.book = try #require(NameEdit.replacing(merge, in: zebra.book))
        try await index.save(zebra)

        let facets = try await index.authorFacets()
        // The old author row has no books left, so it is not a facet any more.
        #expect(facets.map { $0.name } == ["Marek Voss"])
        #expect(facets.first?.count == 1)

        let sorted = try await index.allEntries(sortedBy: BookOrder(field: .author, ascending: true))
        #expect(sorted.map { $0.book.title } == ["Zebra"])
    }
}
