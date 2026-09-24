import Foundation

/// The narrow, display-preserving half of C3's title rule.
///
/// `TitleNormalization.matchable` (`MergeMatching.swift`) folds a title down
/// to "is this the same work" — case, accents and punctuation all gone. That
/// is right for matching two books and wrong for *editing* one: a person's
/// title keeps its own capitalisation and accents, and only the whitespace
/// and the merchant's own bracketed annotation are C3's business.
public enum TitleStandardization {
    /// The same phrases `TitleNormalization.merchantSuffixWords` matches by
    /// folded word, spelled out as a case-insensitive pattern over the real
    /// text so the surrounding title is never touched.
    private static let merchantSuffixPattern: String = {
        let phrases = ["german edition", "kindle edition", "deutsche ausgabe", "ebook"]
        let alternation = phrases.map { $0.replacingOccurrences(of: " ", with: "\\s+") }
            .joined(separator: "|")
        return "\\s*[\\(\\[]\\s*(?:\(alternation))\\s*[\\)\\]]\\s*$"
    }()

    /// Whitespace collapsed to single spaces and trimmed, and a trailing
    /// merchant annotation removed, repeatedly — "Title (German Edition)
    /// (Kindle Edition)" sheds both. Never strips a title down to nothing:
    /// if removing the last recognised suffix would leave no words at all,
    /// that suffix is kept and the loop stops, the same guard
    /// `TitleNormalization.matchable` uses.
    public static func standardized(_ title: String) -> String {
        var working = title
        while let range = working.range(
            of: merchantSuffixPattern, options: [.regularExpression, .caseInsensitive])
        {
            let stripped = String(working[..<range.lowerBound])
            guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            working = stripped
        }
        return collapseWhitespace(working)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// C3's ISBN rule: only a valid ISBN stays, and it stays as an ISBN-13 —
/// the one direction Bookland's own numbering allows, since a 13 never had a
/// 10. Unlike the importer, which never validates what a file says
/// (`ISBN.swift`'s own reasoning), this is a deliberate, previewed command,
/// which is the one place allowed to say a stored identifier is simply wrong
/// and drop it.
public enum ISBNStandardization {
    /// `nil` when the raw value is not a valid ISBN at all — dropped, never
    /// guessed at. Already-13 values are returned normalised, not reparsed.
    public static func standardized(_ raw: String) -> String? {
        let normalised = ISBN.normalised(raw)
        guard ISBN.isValid(normalised) else { return nil }
        return normalised.count == 13 ? normalised : toISBN13(normalised)
    }

    /// ISBN-10 → ISBN-13: drop the old check digit, prefix the Bookland
    /// `978` group, recompute the ISBN-13 check digit over the new 12.
    private static func toISBN13(_ isbn10: String) -> String? {
        guard isbn10.count == 10 else { return nil }
        let core = "978" + isbn10.dropLast()
        let digits = core.compactMap(\.wholeNumberValue)
        guard digits.count == 12 else { return nil }
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        let check = (10 - sum % 10) % 10
        return core + String(check)
    }
}

/// The fold C3's own tag rule allows, and no more: case and whitespace,
/// nothing else. Deliberately narrower than `DuplicateKey.fold` — two tags
/// that only look the same once accents or punctuation are stripped are not
/// what "only a case or whitespace variant" means, and folding them would be
/// C2's similarity guess wearing a different name.
public enum TagFold {
    public static func normalized(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// What a "Standardize Fields" run would do, before anything is written —
/// C3's own preview, the same shape `NameMergePlan` already gives "Merge
/// into…": the value shown is the value executed (ADR 0002, decision 6).
public struct FieldStandardizationPlan: Equatable, Sendable {
    /// One per book that really changes. A book already standardized is not
    /// in here — a change that changes nothing is not written
    /// (`MetadataChange.isEmpty`).
    public var changes: [(entry: LibraryEntry, change: MetadataChange)]

    public init(changes: [(entry: LibraryEntry, change: MetadataChange)]) {
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }
    public var bookCount: Int { changes.count }

    public static func == (one: FieldStandardizationPlan, other: FieldStandardizationPlan) -> Bool {
        one.changes.count == other.changes.count
            && zip(one.changes, other.changes).allSatisfy { $0.entry == $1.entry && $0.change == $1.change }
    }

    /// "14 books" — there is no name to fold in, unlike a merge, so the
    /// summary is only ever the count.
    public func summary() -> String {
        isEmpty ? "No book needs standardizing" : "\(bookCount) book\(bookCount == 1 ? "" : "s")"
    }
}

/// Teil C3: the field rules that are not a proposal at all, unlike C2's
/// spellings — each one is a pure function with exactly one right answer, so
/// there is nothing to choose between and nothing to reject, only to preview
/// and confirm (ADR 0018's "preview that is the plan" still applies; there is
/// simply no judgement call underneath this one).
///
/// **What this never does:** it never touches `series` (a series or its
/// number is filled only from a source, never guessed at — that is C4's
/// concern) and it never touches `description` (fill-only, never rewritten —
/// also C4). Both stay exactly as the folder has them.
public enum FieldStandardization {
    /// The tag merges this run would make, computed once over the whole
    /// library and then held fixed — every book's standardization uses the
    /// same list, so two books that both carry "Science Fiction" and
    /// "science fiction" fold to the same winner rather than each picking
    /// its own.
    public static func tagMerges(among entries: [LibraryEntry]) -> [NameMerge] {
        SimilarSpellings.tagGroups(among: entries).map(\.asMerge)
    }

    /// Applies every C3 rule to one book in place: title trimmed and its
    /// merchant suffix removed, language folded to its short form, the ISBN
    /// standardized to a valid ISBN-13 or dropped outright when it never was
    /// a valid ISBN, and every tag merge already decided for the library.
    public static func standardize(_ book: inout Book, tagMerges: [NameMerge]) {
        book.title = TitleStandardization.standardized(book.title)
        if let language = book.language, !language.isEmpty {
            book.language = LanguageCode.normalised(language)
        }
        if let isbn = book.identifiers["isbn"], !isbn.isEmpty {
            if let standardized = ISBNStandardization.standardized(isbn) {
                book.identifiers["isbn"] = standardized
            } else {
                book.identifiers.removeValue(forKey: "isbn")
            }
        }
        for merge in tagMerges {
            if let updated = NameEdit.replacing(merge, in: book) { book = updated }
        }
    }

    /// One book's change, or `nil` when standardizing it changes nothing.
    public static func change(
        for book: Book, tagMerges: [NameMerge], at now: Date = Date()
    ) -> MetadataChange? {
        let made = MetadataChange.make(from: book, at: now) { standardize(&$0, tagMerges: tagMerges) }
        return made.isEmpty ? nil : made
    }

    /// Everything a run across the whole library would touch. This is the
    /// value the sheet shows and the value the model executes — computed
    /// once, held fixed, never recomputed between preview and confirm.
    public static func plan(over entries: [LibraryEntry], at now: Date = Date()) -> FieldStandardizationPlan {
        let merges = tagMerges(among: entries)
        let changes = entries.compactMap { entry in
            change(for: entry.book, tagMerges: merges, at: now).map { (entry, $0) }
        }
        return FieldStandardizationPlan(changes: changes)
    }
}
