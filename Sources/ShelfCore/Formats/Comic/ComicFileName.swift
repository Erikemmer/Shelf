import Foundation

/// What a comic's file name says about it.
///
/// For most of a comics collection this is the *only* metadata there will ever
/// be: a CBZ is a zip of pictures and carries nothing unless somebody put a
/// `ComicInfo.xml` in it, which most scrapers do not. So the rules live here,
/// in the core, where they are tested — rather than in a regex in a view.
///
/// `Serie 012 (2019).cbz` → series "Serie", issue 12, year 2019. The shapes
/// below are reference data, widest first, and adding one is a row.
public enum ComicFileName {

    public struct Parsed: Equatable, Sendable {
        public var series: String?
        /// The issue or volume number. A `Double` because half issues exist
        /// (`#12.5`) and because `SeriesRef.index` is one.
        public var number: Double?
        public var year: Int?
        /// What is left after the series, the number and the year are taken
        /// out — usually the issue's own title, and usually nothing.
        public var title: String?

        public init(series: String? = nil, number: Double? = nil, year: Int? = nil, title: String? = nil) {
            self.series = series
            self.number = number
            self.year = year
            self.title = title
        }
    }

    /// The patterns, in the order they are tried. Each one must capture the
    /// series first, then the number.
    ///
    /// Anchored at the end of the stem rather than searched for anywhere in it:
    /// `Battle 2000 15` is series "Battle 2000", issue 15 — and a pattern that
    /// searched would call it series "Battle", issue 2000.
    static let numberPatterns = [
        // `Series v02`, the collected-volume spelling.
        #"^(.*?)[ _]+[vV](\d{1,4}(?:\.\d+)?)$"#,
        // `Series #12` and `Series # 12`.
        #"^(.*?)[ _]+#[ _]*(\d{1,4}(?:\.\d+)?)$"#,
        // `Series 012` — the common one. Three or more digits, or one or two
        // that are not a year: a bare `Series 1998` is far more likely to be a
        // year than issue 1998, and the year pattern has already taken it.
        #"^(.*?)[ _]+(\d{1,4}(?:\.\d+)?)$"#,
    ]

    /// Reads a file name stem — no extension, no path.
    public static func parse(_ stem: String) -> Parsed {
        var parsed = Parsed()
        // The bracketed groups at the end come off first, one at a time: the
        // year among them is kept and the rest — `(Digital)`, `(Empire)`, the
        // scanner's signature — is dropped. One pass rather than "year first,
        // noise second", because a real name puts them in either order and
        // `Saga 012 (2019) (Digital)` lost its year to the other arrangement.
        var rest = tidied(stem)
        while let group = trailingBracketGroup(in: rest) {
            let shortened = String(rest[rest.startIndex..<group.range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // A name that is *only* a bracketed group keeps it rather than
            // becoming empty.
            guard !shortened.isEmpty else { break }
            if parsed.year == nil, let year = Int(group.inside), (1800...2099).contains(year) {
                parsed.year = year
            }
            rest = shortened
        }

        for pattern in numberPatterns {
            guard let match = firstMatch(pattern, in: rest), match.count >= 3 else { continue }
            let series = match[1].trimmingCharacters(in: .whitespaces)
            guard !series.isEmpty, let number = Double(match[2]) else { continue }
            parsed.series = tidied(series)
            parsed.number = number
            return parsed
        }

        // No number: the whole thing is the title, and it is a series only if
        // something else says so.
        parsed.title = rest.isEmpty ? nil : rest
        return parsed
    }

    /// The `Book` a file name alone can support.
    ///
    /// The title is `Series 12` rather than bare `Series`, because a shelf of
    /// forty books all called "Saga" is a shelf nobody can use. The series and
    /// its index go in as well, so the series view can order them.
    public static func book(from stem: String) -> Book {
        let parsed = parse(stem)
        var book: Book

        if let series = parsed.series, let number = parsed.number {
            let printed = number == number.rounded() ? String(Int(number)) : String(number)
            book = Book(title: "\(series) \(printed)", series: SeriesRef(name: series, index: number))
        } else if let title = parsed.title {
            book = Book(title: FileNameMetadata.title(from: title))
            let authors = FileNameMetadata.authors(from: title)
            if !authors.isEmpty { book.authors = authors }
        } else {
            book = Book(title: stem)
        }

        if let year = parsed.year {
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            var calendar = Calendar(identifier: .gregorian)
            // Fixed, not the user's: a date that reads differently on another
            // Mac is the same class of defect as the "64,4" the smoke test met.
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            book.published = calendar.date(from: components)
        }
        return book
    }

    // MARK: The small rules

    /// The last `(…)` or `[…]` in the name, when the name ends with one: where
    /// it is, and what is inside it.
    static func trailingBracketGroup(in text: String) -> (range: Range<String.Index>, inside: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = firstMatch(bracketGroupPattern, in: trimmed), match.count >= 2,
            let range = trimmed.range(of: match[0], options: .backwards)
        else { return nil }
        return (range, match[1])
    }

    /// A bracketed group at the very end, and what is inside it.
    static let bracketGroupPattern = #"[\(\[]([^\(\)\[\]]*)[\)\]]\s*$"#

    /// Underscores to spaces always; dots to spaces **only when the name has no
    /// spaces of its own**.
    ///
    /// That condition is the whole of it, and it was found by a test. Scene
    /// releases use dots *instead of* spaces (`The.Sandman.v01.(1989)`), so
    /// there the dot is a separator. A name that already has spaces uses the
    /// dot for what a dot is — and `Monstress 12.5 (2018)` came out as issue 12
    /// of a series called "Monstress 12" when dots were replaced unconditionally.
    static func tidied(_ text: String) -> String {
        var working = text.replacingOccurrences(of: "_", with: " ")
        if !working.contains(" ") {
            working = working.replacingOccurrences(of: ".", with: " ")
        }
        return working.split(separator: " ").filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The whole match and its groups, or nil.
    ///
    /// `NSRegularExpression` rather than Swift's `Regex`, because `Regex` needs
    /// macOS 13 *and* a newer swift-corelibs-foundation than the Linux CI image
    /// carries, and the core builds there.
    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: full) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
