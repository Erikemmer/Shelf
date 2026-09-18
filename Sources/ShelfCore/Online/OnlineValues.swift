import Foundation

/// A publication date as the two services actually print it.
///
/// Open Library's `/api/books` answers `"October 1, 1988"`, its search answers
/// `1937` as a number, and Google Books answers `"1988-10-01"`, `"1988-10"` or
/// `"1988"`. `OPFDate.parse` reads the last three and none of the first, so this
/// tries it first and then the spelled-out forms. A date that is not understood
/// is **kept as text and not as a date**: the comparison then shows what the
/// service said and offers nothing to take over, which is better than storing 1
/// January of a year nobody claimed.
public enum OnlineDate {
    /// The written-out forms, in the order they are worth trying. English only,
    /// because both services answer in English whatever the book is in.
    static let spelledOut = ["MMMM d, yyyy", "MMM d, yyyy", "MMMM yyyy", "MMM yyyy", "d MMMM yyyy"]

    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = OPFDate.parse(trimmed) { return date }
        for format in spelledOut {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// Language codes, from what the services say to what a library holds.
///
/// Open Library answers ISO 639-2 (`eng`, `ger`), Google Books answers ISO 639-1
/// (`en`, `de`), and an EPUB says whichever its maker felt like. Without this,
/// a book whose file says `en` is offered `eng` as a "new" value by one service
/// and nothing by the other — a difference that is not a difference, in a list
/// whose whole job is to show differences.
///
/// A table, not a branch (Leitlinie: reference data is data). Two-letter codes
/// are passed through; an unknown three-letter code is passed through as well,
/// because a code Shelf has never seen is still what the service said.
public enum LanguageCode {
    /// ISO 639-2/B and 639-2/T to 639-1, for the languages a European eBook
    /// library actually holds.
    static let twoLetter: [String: String] = [
        "eng": "en", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr",
        "spa": "es", "ita": "it", "dut": "nl", "nld": "nl", "por": "pt",
        "rus": "ru", "pol": "pl", "swe": "sv", "dan": "da", "nor": "no",
        "fin": "fi", "cze": "cs", "ces": "cs", "hun": "hu", "tur": "tr",
        "gre": "el", "ell": "el", "heb": "he", "ara": "ar", "jpn": "ja",
        "chi": "zh", "zho": "zh", "kor": "ko", "lat": "la", "ukr": "uk",
        "ron": "ro", "rum": "ro", "cat": "ca", "slk": "sk", "slo": "sk",
    ]

    public static func normalised(_ raw: String) -> String {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return twoLetter[code] ?? code
    }
}
