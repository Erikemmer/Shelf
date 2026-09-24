import Foundation

/// A shop's own legal-form suffix, folded away the same way a merchant's
/// bracketed edition annotation is (`TitleNormalization`) — never part of
/// the publisher's own name.
public enum PublisherNameFold {
    static let legalSuffixWords: [[String]] = [
        ["gmbh", "co", "kg"],
        ["gmbh"],
        ["verlag"],
        ["kg"],
        ["ltd"],
        ["inc"],
    ]

    /// Case, punctuation and a trailing legal-form suffix folded away —
    /// nothing else. Unlike a title or an author, a publisher's spelling
    /// differences C2 is asked to merge are narrower on purpose: "Canongate
    /// Books" and "Canongate Books Ltd" are the same publisher; two
    /// different imprints of one larger house are not, and this rule never
    /// tries to know that.
    public static func normalized(_ name: String) -> String {
        var words = DuplicateKey.fold(name).split(separator: " ").map(String.init)
        var changed = true
        while changed {
            changed = false
            for suffix in legalSuffixWords
            where words.count > suffix.count && Array(words.suffix(suffix.count)) == suffix {
                words.removeLast(suffix.count)
                changed = true
            }
        }
        return words.joined(separator: " ")
    }
}

/// A group of spellings C2 proposes are the same author or the same
/// publisher — a *proposal*, never an automatic merge (ADR 0018): nothing
/// here writes anything, it only fills the same preview list a person fills
/// by hand, which is what "Merge into…" already executes.
public struct SimilarSpellingGroup: Equatable, Sendable, Identifiable {
    public var kind: NameKind
    /// The most complete spelling, by display rule, tied broken by book
    /// count.
    public var winner: String
    /// Every spelling that would fold into `winner`, `winner` itself
    /// included — the same shape `NameMerge.sources` wants once a person
    /// (or this suggester) has decided who wins.
    public var spellings: [String]
    public var bookCounts: [String: Int]

    public var id: String { "\(kind.rawValue)/\(winner)" }

    /// The `NameMerge` this group becomes once accepted — every spelling but
    /// the winner folds into it.
    public var asMerge: NameMerge {
        NameMerge(kind: kind, sources: spellings.filter { $0 != winner }, target: winner)
    }
}

/// Proposing groups of author or publisher spellings that are probably one
/// person or one publisher — never merging anything itself.
public enum SimilarSpellings {
    /// A name whose given-name part is written as initials — `"J. Zeh"`,
    /// `"J. K. Rowling"` — every token before the last one is a single
    /// letter with a period. The riskier of C2's two rules only applies
    /// when this is true of one side and false of the other; two full names
    /// or two initialed ones are never folded by it.
    static func isInitialsForm(_ name: String) -> Bool {
        let words = name.split(separator: " ").map(String.init)
        guard words.count > 1 else { return false }
        let given = words.dropLast()
        return !given.isEmpty && given.allSatisfy { $0.count == 2 && $0.hasSuffix(".") }
    }

    /// A folded stand-in for "surname" — the part before the comma in
    /// "Surname, Given", or the last word otherwise. **Not**
    /// `AuthorNameFold.normalized`: that sorts its words alphabetically so
    /// that order stops mattering for the *safe* fold, which is exactly
    /// wrong here — taking `.last` of an alphabetically sorted string is
    /// "whichever word sorts last", not the surname.
    private static func foldedSurname(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let comma = trimmed.firstIndex(of: ",") {
            return DuplicateKey.fold(String(trimmed[..<comma]))
        }
        let words = trimmed.split(separator: " ").map(String.init)
        return DuplicateKey.fold(words.last ?? trimmed)
    }

    public static func authorGroups(among entries: [LibraryEntry]) -> [SimilarSpellingGroup] {
        var countsByName: [String: Int] = [:]
        var titlesByName: [String: Set<String>] = [:]
        var seriesByName: [String: Set<String>] = [:]
        for entry in entries {
            for author in entry.book.authors {
                countsByName[author, default: 0] += 1
                titlesByName[author, default: []].insert(TitleNormalization.matchable(entry.book.title))
                if let series = entry.book.series?.name { seriesByName[author, default: []].insert(series) }
            }
        }
        let names = Array(countsByName.keys)

        var groups: [[String]] = Array(Dictionary(grouping: names, by: AuthorNameFold.normalized).values)
            .filter { $0.count > 1 }
        var alreadyGrouped = Set(groups.flatMap { $0 })

        // The riskier rule: an initialed name against exactly one full name
        // sharing its surname, and only when they share a work or a series.
        let remaining = names.filter { !alreadyGrouped.contains($0) }
        for initialed in remaining where isInitialsForm(initialed) {
            let surname = foldedSurname(initialed)
            let fullCandidates = remaining.filter {
                $0 != initialed && !isInitialsForm($0) && foldedSurname($0) == surname
            }
            guard fullCandidates.count == 1, let full = fullCandidates.first else { continue }
            let sharesWork = !(titlesByName[initialed] ?? []).isDisjoint(with: titlesByName[full] ?? [])
            let sharesSeries = !(seriesByName[initialed] ?? []).isDisjoint(with: seriesByName[full] ?? [])
            guard sharesWork || sharesSeries else { continue }
            groups.append([initialed, full])
            alreadyGrouped.insert(initialed)
            alreadyGrouped.insert(full)
        }

        return groups.map { spellings in
            build(.author, spellings: spellings, counts: countsByName)
        }
    }

    public static func publisherGroups(among entries: [LibraryEntry]) -> [SimilarSpellingGroup] {
        var countsByName: [String: Int] = [:]
        for entry in entries {
            guard let publisher = entry.book.publisher, !publisher.isEmpty else { continue }
            countsByName[publisher, default: 0] += 1
        }
        let groups = Dictionary(grouping: countsByName.keys, by: PublisherNameFold.normalized).values
            .filter { $0.count > 1 }
        return groups.map { spellings in
            build(.publisher, spellings: Array(spellings), counts: countsByName)
        }
    }

    /// The winner: the most complete display form, the most frequent among
    /// ties. "Most complete" for an author is simply "not the initialed
    /// one" when the group has exactly one of those; for a publisher it is
    /// the longer spelling, which is what carrying the legal-form suffix
    /// (or not folding two words into one) actually looks like in practice.
    private static func build(
        _ kind: NameKind, spellings: [String], counts: [String: Int]
    ) -> SimilarSpellingGroup {
        let winner =
            spellings.max { a, b in
                let completeness = (completenessScore(a, kind: kind), counts[a] ?? 0)
                let otherCompleteness = (completenessScore(b, kind: kind), counts[b] ?? 0)
                if completeness.0 != otherCompleteness.0 { return completeness.0 < otherCompleteness.0 }
                if completeness.1 != otherCompleteness.1 { return completeness.1 < otherCompleteness.1 }
                // Still tied on both: alphabetically first wins, deterministically —
                // never left to a Dictionary's own (hash-randomised) iteration order,
                // which is what `spellings.max` would otherwise fall back on.
                return a > b
            } ?? spellings[0]
        return SimilarSpellingGroup(
            kind: kind, winner: winner, spellings: spellings.sorted(),
            bookCounts: counts.filter { spellings.contains($0.key) })
    }

    /// Higher wins. For an author: never the initialed form over a full
    /// one, and never the sort form ("Surname, Given") over the display one
    /// ("Given Surname") — C1's own display rule is "Vorname Nachname", and
    /// a comma is what marks the sort form, not a display preference.
    private static func completenessScore(_ name: String, kind: NameKind) -> Int {
        switch kind {
        case .author:
            var score = isInitialsForm(name) ? 0 : 2
            if name.contains(",") { score -= 1 }
            return score
        default: return name.count
        }
    }
}
