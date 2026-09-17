import Foundation

/// An ISBN: how it is normalised, and whether it can be one at all.
///
/// The check digit is the whole reason this exists. An ISBN is the strongest
/// duplicate test the importer has (`identifiers.isbn_normalised`), and a
/// mistyped one is worse than none: it is a key that will silently match a
/// different book, or match nothing while looking like it should. Nine or
/// fourteen digits are caught by the length; one transposed pair in the middle
/// is caught only by the check digit, and transposing a pair is the most common
/// thing a person does while typing thirteen digits.
///
/// Validation is for what a *person types*. Nothing on the way in from a file is
/// validated: a library full of wrong ISBNs must still import, keep them and
/// show them, because they are what the file says (CONCEPT §5). The editor
/// refuses a bad one; the reader never does.
public enum ISBN {
    /// Digits and `X` only, upper-cased. `978-0-306-40615-7`, `978 0306406157`
    /// and `9780306406157` normalise to the same string, which is what makes
    /// two spellings of one ISBN one book.
    public static func normalised(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isNumber || $0 == "X" })
    }

    /// Whether the value is an ISBN-10 or an ISBN-13 with a correct check digit.
    public static func isValid(_ raw: String) -> Bool {
        let digits = normalised(raw)
        switch digits.count {
        case 10: return isValidTen(digits)
        case 13: return isValidThirteen(digits)
        default: return false
        }
    }

    /// ISBN-10: the weighted sum with weights 10…1 is divisible by 11, and the
    /// last position may be `X` for ten.
    private static func isValidTen(_ digits: String) -> Bool {
        var sum = 0
        for (position, character) in digits.enumerated() {
            let value: Int
            if character == "X" {
                // Only the check digit may be X. "X123456789" is not an ISBN.
                guard position == 9 else { return false }
                value = 10
            } else {
                guard let digit = character.wholeNumberValue else { return false }
                value = digit
            }
            sum += value * (10 - position)
        }
        return sum % 11 == 0
    }

    /// ISBN-13 (and EAN-13): weights alternate 1 and 3, the sum is divisible by
    /// ten. `X` is not legal anywhere in a 13 – and it has no `wholeNumberValue`,
    /// so the guard below is what refuses it.
    private static func isValidThirteen(_ digits: String) -> Bool {
        var sum = 0
        for (position, character) in digits.enumerated() {
            guard let digit = character.wholeNumberValue else { return false }
            sum += digit * (position % 2 == 0 ? 1 : 3)
        }
        return sum % 10 == 0
    }
}
