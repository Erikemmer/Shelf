import Foundation

/// Where a book sits in its series, in the words the inspector shows.
///
/// "Book 3 of 7" – and the count is **the books of that series in this
/// library**, not how long the series really is. Shelf has no way of knowing
/// the latter until Sprint 6 asks Open Library, and pretending otherwise would
/// be a number nobody could check.
///
/// The rule is here rather than in the view because of what the Sprint 4
/// screenshot showed: a book numbered 3 of a series the library holds one book
/// of, printed as **"Book 3 of 1"**. The count was right and the sentence was
/// nonsense — "of 1" reads as a claim about the series, and a claim that its
/// own neighbour contradicts. A view that formats two numbers has no business
/// deciding that; it is a rule, and a rule belongs where it can be tested.
public enum SeriesPosition {

    /// The line under the series field, or nothing when there is none to draw.
    ///
    /// - Parameters:
    ///   - printedIndex: the index as the file spells it, so a novella reads
    ///     "Book 3.5" rather than "Book 3" or "Book 3.5000".
    ///   - index: the same number, to compare against the count.
    ///   - countInLibrary: how many books of this series the library holds.
    public static func text(printedIndex: String, index: Double, countInLibrary: Int) -> String? {
        guard countInLibrary > 0, !printedIndex.isEmpty else { return nil }
        // A library that holds fewer books of the series than the index claims
        // is the ordinary case of a half-collected series, not an error — so
        // the position is still worth saying, and the total is not. "Book 3"
        // is true; "Book 3 of 1" is arithmetic nobody asked for.
        guard Double(countInLibrary) >= index else { return "Book \(printedIndex)" }
        return "Book \(printedIndex) of \(countInLibrary)"
    }
}
