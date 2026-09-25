import Foundation

/// Where an Amazon ASIN is found on a book, and what counts as one — Teil B3.
///
/// Shelf's own MOBI/AZW3 reader writes it under the identifier scheme
/// `asin` (`MobiMetadata`). A Calibre import carries whatever scheme
/// Calibre itself used for the value, most often `mobi-asin` — found
/// against the real library, not assumed: 308 of its identifiers carry that
/// scheme, and some of those values are Calibre's own UUIDs for an
/// identifier kind this project has never seen filled in, not a real ASIN.
/// **The pattern, not the scheme, is what decides "asin"**: a real ASIN is
/// always `B` followed by nine letters or digits (Amazon's own format),
/// which the UUID-shaped values never match.
public enum AmazonASIN {
    static let schemes = ["asin", "mobi-asin", "amazon"]

    /// The first scheme that carries a value shaped like a real ASIN, or
    /// `nil` when none does.
    public static func valid(in identifiers: [String: String]) -> String? {
        for scheme in schemes {
            if let value = identifiers[scheme], isValid(value) { return value }
        }
        return nil
    }

    public static func isValid(_ value: String) -> Bool {
        value.range(of: "^B[0-9A-Z]{9}$", options: .regularExpression) != nil
    }
}
