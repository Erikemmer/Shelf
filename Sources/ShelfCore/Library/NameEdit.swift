import Foundation

/// A name that many books share: an author, a series, a publisher, a tag.
///
/// Reference data rather than four near-identical code paths. Everything that
/// differs between the four — where the name sits in a `Book`, what the menu
/// calls the command, what the undo step is named — is a case here, and adding
/// a fifth kind would be a case and nothing else.
public enum NameKind: String, CaseIterable, Sendable, Codable {
    case author
    case series
    case publisher
    case tag

    /// Singular, as a menu item and a sheet's title use it.
    public var label: String {
        switch self {
        case .author: return "Author"
        case .series: return "Series"
        case .publisher: return "Publisher"
        case .tag: return "Tag"
        }
    }

    /// Plural, as the undo step and the report use it.
    public var pluralLabel: String {
        switch self {
        case .author: return "Authors"
        case .series: return "Series"
        case .publisher: return "Publishers"
        case .tag: return "Tags"
        }
    }

    /// Whether a book can carry several of these at once. That is the whole
    /// difference between the two halves of `replacing`: an author or a tag is
    /// one of a list and can collide with a sibling after the replacement; a
    /// series or a publisher is a single value and cannot.
    public var isMultiValued: Bool {
        switch self {
        case .author, .tag: return true
        case .series, .publisher: return false
        }
    }

    /// Every spelling of this kind a book carries.
    public func names(of book: Book) -> [String] {
        switch self {
        case .author: return book.authors
        case .series: return book.series.map { [$0.name] } ?? []
        case .publisher: return book.publisher.map { [$0] } ?? []
        case .tag: return book.tags
        }
    }
}

/// Renaming one spelling, or folding several spellings into one.
///
/// The same value is what the sheet previews and what the model executes —
/// the rule `ImportPlan` and `TransferPlan` already follow (ADR 0002,
/// decision 6). Nothing here guesses which spellings belong together:
/// `sources` is a selection somebody made (ADR 0018).
public struct NameMerge: Equatable, Sendable {
    public var kind: NameKind
    /// The spellings being replaced, exactly as the sidebar lists them.
    ///
    /// Exact, not folded: the facets the person clicked are exact strings, and
    /// a rename whose only change *is* the capitalisation — "fitzek" to
    /// "Fitzek" — has to be possible.
    public var sources: [String]
    /// What they all become.
    public var target: String

    public init(kind: NameKind, sources: [String], target: String) {
        self.kind = kind
        self.sources = sources
        self.target = target
    }

    /// A rename is a merge of one.
    public static func rename(_ kind: NameKind, from old: String, to new: String) -> NameMerge {
        NameMerge(kind: kind, sources: [old], target: new)
    }

    /// Whether this is one spelling being corrected or several being folded
    /// together. Only the wording differs; the work is the same.
    public var isRename: Bool { sources.count <= 1 }

    /// Why this cannot be done, in the sentence the sheet shows. `nil` when it
    /// can.
    public var refusal: String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // It does not name the kind, and that is deliberate: interpolating
            // it would be four catalogue entries for one sentence, and the
            // sheet's own title has already said which kind this is.
            return "A name cannot be empty. Type the spelling the ticked ones should all have."
        }
        if sources.isEmpty {
            return "Nothing was selected to rename."
        }
        // The one character that is a structure everywhere else in this
        // program: a shelf path is separated by it, and a name holding one
        // would mean two things (ADR 0008, decision 4).
        if trimmed.contains(ShelfTree.pathSeparator) {
            return "A name cannot contain “\(ShelfTree.pathSeparator)”."
        }
        return nil
    }

    /// The target with the whitespace taken off, which is what actually gets
    /// written. Trimmed for the same reason every typed field is: the XML
    /// parser trims on the way back in, so an untrimmed value would come back
    /// different from what was stored (`BookField.apply`).
    public var trimmedTarget: String {
        target.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the Edit menu says after "Undo", **without the count**: "Merge
    /// Authors", "Rename Author".
    ///
    /// Without it on purpose. The window adds "(37 books)" through the frame
    /// it already uses for every other edit across a selection, so the count
    /// is pluralised by the catalogue rather than by a `== 1` in here — and
    /// the eight sentences this can be are eight catalogue keys a test can
    /// walk, instead of one string built at run time that no test can see.
    /// That is exactly what went wrong with `MetadataChange.actionName` in
    /// Sprint 6 and was fixed in Sprint 7: a German window offered
    /// "Widerrufen Title".
    public var actionName: String {
        switch (isRename, kind) {
        case (true, .author): return "Rename Author"
        case (true, .series): return "Rename Series"
        case (true, .publisher): return "Rename Publisher"
        case (true, .tag): return "Rename Tag"
        case (false, .author): return "Merge Authors"
        case (false, .series): return "Merge Series"
        case (false, .publisher): return "Merge Publishers"
        case (false, .tag): return "Merge Tags"
        }
    }

    /// Both spellings of the action name, for the localisation test to walk in.
    public static var allActionNames: [String] {
        NameKind.allCases.flatMap {
            [
                NameMerge(kind: $0, sources: ["a"], target: "b").actionName,
                NameMerge(kind: $0, sources: ["a", "b"], target: "c").actionName,
            ]
        }
    }
}

/// What a merge would do, before anything is written.
public struct NameMergePlan: Equatable, Sendable {
    public var merge: NameMerge
    /// One per book that really changes, in the order the entries came in.
    /// A book already carrying the target spelling and nothing else is not in
    /// here: a change that changes nothing is not written (`MetadataChange`).
    public var changes: [(entry: LibraryEntry, change: MetadataChange)]
    /// How many books carry one of the chosen spellings at all — whether or
    /// not the merge would change them.
    ///
    /// It exists to tell two quite different nothings apart, and looking at a
    /// screenshot is what found them being told alike. Ticking "Sebastian
    /// Fitzek" and typing "Sebastian Fitzek" changes nothing, and the sheet
    /// said **"No book carries that name"** — with three of them listed one
    /// line above, each saying "3 books". Both are empty plans; only one of
    /// them is a library that has never heard of the name.
    public var carrying: Int

    public init(
        merge: NameMerge, changes: [(entry: LibraryEntry, change: MetadataChange)],
        carrying: Int = 0
    ) {
        self.merge = merge
        self.changes = changes
        self.carrying = carrying
    }

    public var bookCount: Int { changes.count }
    public var isEmpty: Bool { changes.isEmpty }

    public static func == (one: NameMergePlan, other: NameMergePlan) -> Bool {
        one.merge == other.merge && one.carrying == other.carrying
            && one.changes.count == other.changes.count
            && zip(one.changes, other.changes).allSatisfy { $0.entry == $1.entry && $0.change == $1.change }
    }

    /// "37 books · 3 spellings → “Sebastian Fitzek”".
    public func summary() -> String {
        guard !isEmpty else {
            if carrying == 0 {
                return merge.isRename
                    ? "No book carries that spelling" : "No book carries any of those spellings"
            }
            return "\(carrying) book\(carrying == 1 ? "" : "s") already read that way — nothing to change"
        }
        var parts = ["\(bookCount) book\(bookCount == 1 ? "" : "s")"]
        if !merge.isRename {
            parts.append("\(merge.sources.count) spellings")
        }
        parts.append("→ “\(merge.trimmedTarget)”")
        return parts.joined(separator: " · ")
    }
}

/// Renaming and merging the names many books share.
///
/// Pure: it turns entries into `MetadataChange` values and writes nothing. The
/// writing is the ordinary Sprint 2a chain — undo first, then `metadata.opf`,
/// then the index — so a merge of 37 books is 37 of the same writes one edit
/// makes, wrapped in one undo group. No second path through the editor, and
/// therefore no second set of rules about what a valid book is.
///
/// **It does not move a folder.** A book's path is built from its metadata at
/// import and left alone afterwards (ADR 0007); putting the folders back in
/// step is `OrganizePlanner`'s job and is a command of its own (ADR 0018).
public enum NameEdit {

    /// The book after the replacement, or `nil` if it carries none of the
    /// source spellings.
    public static func replacing(_ merge: NameMerge, in book: Book) -> Book? {
        let target = merge.trimmedTarget
        let sources = Set(merge.sources)
        guard merge.kind.names(of: book).contains(where: sources.contains) else { return nil }

        var edited = book
        switch merge.kind {
        case .author:
            edited.authors = folded(book.authors.map { sources.contains($0) ? target : $0 }, preferring: target)
        case .tag:
            edited.tags = folded(book.tags.map { sources.contains($0) ? target : $0 }, preferring: target).sorted()
        case .series:
            edited.series = book.series.map { SeriesRef(name: target, index: $0.index) }
        case .publisher:
            edited.publisher = target
        }
        return edited
    }

    /// One book's change, or `nil` when the book does not carry any of the
    /// spellings or when the replacement changes nothing.
    public static func change(
        _ merge: NameMerge, to book: Book, at now: Date = Date()
    ) -> MetadataChange? {
        guard merge.refusal == nil, let edited = replacing(merge, in: book) else { return nil }
        let change = MetadataChange.make(from: book, at: now) { $0 = edited }
        return change.isEmpty ? nil : change
    }

    /// Everything the merge touches. This is the value the sheet shows and the
    /// value the model executes.
    public static func plan(
        _ merge: NameMerge, over entries: [LibraryEntry], at now: Date = Date()
    ) -> NameMergePlan {
        var changes: [(entry: LibraryEntry, change: MetadataChange)] = []
        var carrying = 0
        let sources = Set(merge.sources)
        for entry in entries {
            if merge.kind.names(of: entry.book).contains(where: sources.contains) { carrying += 1 }
            guard let change = change(merge, to: entry.book, at: now) else { continue }
            changes.append((entry, change))
        }
        return NameMergePlan(merge: merge, changes: changes, carrying: carrying)
    }

    /// De-duplicates a list of names case-insensitively, keeping the first
    /// position — but writing the *target's* spelling wherever the target is
    /// one of the collided names.
    ///
    /// Case-insensitively because that is what the rest of this model already
    /// does with tags: "Science Fiction" and "science fiction" are one keyword
    /// to everyone except a string comparison (`TagEdit.add`). The target wins
    /// the spelling because somebody has just typed it and said that is how it
    /// should read — which is the one place where `TagEdit`'s "the library's
    /// existing spelling wins" is the wrong rule.
    static func folded(_ names: [String], preferring target: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for name in names {
            let key = name.lowercased()
            guard !seen.contains(key) else {
                // Already have it. If this one is the target and the kept one
                // is a different spelling, the target replaces it in place.
                if name == target, let at = result.firstIndex(where: { $0.lowercased() == key }) {
                    result[at] = target
                }
                continue
            }
            seen.insert(key)
            result.append(name)
        }
        return result
    }
}
