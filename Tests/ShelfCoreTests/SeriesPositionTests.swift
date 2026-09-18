import Foundation
import Testing

@testable import ShelfCore

/// "Book 3 of 7" – and what to say when the library does not hold seven.
///
/// From the Sprint 4 screenshot, which showed "Wayfarers" with an index of 3
/// over the line **"Book 3 of 1"**. The count was correct — the library really
/// did hold one book of that series — and the sentence was still wrong.
@Suite("Where a book sits in its series")
struct SeriesPositionTests {

    @Test("a series the library has all of reads as a position out of a total")
    func fullSeries() {
        #expect(SeriesPosition.text(printedIndex: "3", index: 3, countInLibrary: 7) == "Book 3 of 7")
        #expect(SeriesPosition.text(printedIndex: "7", index: 7, countInLibrary: 7) == "Book 7 of 7")
    }

    /// The defect itself.
    @Test("a library that holds fewer books than the index claims says the position alone")
    func halfCollectedSeries() {
        #expect(SeriesPosition.text(printedIndex: "3", index: 3, countInLibrary: 1) == "Book 3")
        #expect(SeriesPosition.text(printedIndex: "164", index: 164, countInLibrary: 1) == "Book 164")
    }

    /// A half issue counts as being past the whole one before it: a library
    /// with two books of a series and a novella numbered 2.5 holds neither
    /// "of 2" honestly nor a contradiction.
    @Test("a half index is compared as the number it is")
    func halfIndex() {
        #expect(SeriesPosition.text(printedIndex: "2.5", index: 2.5, countInLibrary: 3) == "Book 2.5 of 3")
        #expect(SeriesPosition.text(printedIndex: "2.5", index: 2.5, countInLibrary: 2) == "Book 2.5")
    }

    @Test("nothing to say when the library knows of no book in the series")
    func nothingToSay() {
        #expect(SeriesPosition.text(printedIndex: "3", index: 3, countInLibrary: 0) == nil)
        #expect(SeriesPosition.text(printedIndex: "", index: 3, countInLibrary: 4) == nil)
    }
}
