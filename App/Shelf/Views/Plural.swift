import Foundation

/// Counting things in the words a person writes.
///
/// "10 folder(s)" is the spelling of a program that could not be bothered, and
/// a dialog that is about to move somebody's files should not read like a form.
/// One rule, in one place, because the orphan sheet counted in four places and
/// would have drifted.
///
/// English only, which is honest rather than lazy: German plurals are not a
/// trailing "s" and Sprint 7 is where the whole interface is translated
/// properly (CONCEPT §3.4). This is the shape that will be replaced then, not a
/// scheme that pretends to generalise.
enum Plural {
    static func folders(_ count: Int) -> String { Loc.count("%lld folders", count) }
    static func files(_ count: Int) -> String { Loc.count("%lld files", count) }
}
