import Foundation

/// One line of the comparison: what the book says, what the service says, and
/// what would happen if it were ticked.
public struct FieldProposal: Identifiable, Equatable, Sendable {
    /// What the line would change. Not a `BookField` alone: tags are a set and
    /// an ISBN is keyed, and neither is a text field.
    public enum Target: Equatable, Hashable, Sendable {
        case field(BookField)
        /// Tags are **added**, never replaced — see `apply`.
        case tags
        case identifier(String)
    }

    /// Whether the line offers something new, something different, something
    /// additional, or nothing.
    public enum Kind: Equatable, Sendable {
        /// The book has nothing there.
        case add
        /// The book has something else there.
        case replace
        /// Added to what the book has, taking nothing away. Tags, and only
        /// tags: every other field holds one value, so offering it is always a
        /// choice between two. Drawing this as `replace` said "would replace"
        /// over a line that replaces nothing — found in the first screenshot of
        /// the sheet.
        case append
        /// The two agree. Drawn, not tickable: "these already match" is worth
        /// seeing, and a list of only the differences hides how good the match
        /// was.
        case same
    }

    public let target: Target
    public let label: String
    /// What the book holds now, as the inspector would show it. Empty means the
    /// field is empty.
    public let current: String
    /// What the service says.
    public let proposed: String
    public let kind: Kind
    /// Whether the line is ticked when the sheet opens.
    ///
    /// **Only what fills a gap, and only where the record is about this
    /// edition.** Taking over a field the book already has is a decision about
    /// somebody's own library, and a sheet that arrives with eleven
    /// replacements pre-ticked is a sheet whose "Apply" button quietly
    /// overwrites work.
    ///
    /// Filling an empty field is the thing that was asked for — except from a
    /// record that describes a *work* rather than one edition, where the
    /// publisher, the language and the year belong to some edition and not
    /// necessarily to this one. See `MetadataCandidate.describesOneEdition`
    /// and ADR 0015.
    ///
    /// Tags are not ticked either, although they take nothing away: the
    /// subjects a catalogue carries are catalogue vocabulary — "Reliability",
    /// "Accessible book" — and a person's tags are their own.
    public let isTickedByDefault: Bool

    public var id: String {
        switch target {
        case .field(let field): return field.rawValue
        case .tags: return "tags"
        case .identifier(let scheme): return "identifier:\(scheme)"
        }
    }

    /// The three fields that belong to a *printing* rather than to a book, and
    /// so cannot be trusted from a work-level record.
    static let editionLevel: Set<Target> = [
        .field(.publisher), .field(.published), .field(.language),
    ]
}

/// What a candidate would do to a book, field by field — and what it does when
/// a person agrees to some of it.
///
/// The two halves are one type on purpose: the list the sheet draws and the
/// change it applies must be built from the same rule, or a line can say one
/// thing and do another. Every application goes through the *same* field rules
/// the inspector uses (`BookField`, `TagEdit`, `IdentifierEdit`), so a value
/// from the net is validated exactly as a typed one is — an ISBN with a wrong
/// check digit is refused whether a person or Google Books offered it.
public enum MetadataMerge {
    /// Every field the candidate has an opinion about, in the order the
    /// inspector shows them.
    public static func proposals(for book: Book, from candidate: MetadataCandidate) -> [FieldProposal] {
        var lines: [FieldProposal] = []

        func add(_ target: FieldProposal.Target, _ label: String, current: String, proposed: String?) {
            guard let proposed, !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            let kind: FieldProposal.Kind =
                current == proposed ? .same : (current.isEmpty ? .add : .replace)
            let trustworthy = candidate.describesOneEdition || !FieldProposal.editionLevel.contains(target)
            lines.append(
                FieldProposal(
                    target: target, label: label, current: current, proposed: proposed, kind: kind,
                    isTickedByDefault: kind == .add && trustworthy))
        }

        add(.field(.title), BookField.title.label, current: book.title, proposed: candidate.title)
        add(
            .field(.authors), BookField.authors.label,
            current: BookField.authors.text(of: book),
            proposed: candidate.authors.isEmpty ? nil : candidate.authors.joined(separator: " & "))
        add(
            .field(.seriesName), BookField.seriesName.label,
            current: BookField.seriesName.text(of: book), proposed: candidate.series?.name)
        add(
            .field(.seriesIndex), BookField.seriesIndex.label,
            current: BookField.seriesIndex.text(of: book),
            proposed: candidate.series?.index.map(BookField.number))
        add(
            .field(.publisher), BookField.publisher.label,
            current: BookField.publisher.text(of: book), proposed: candidate.publisher)
        // The *parsed* date, not the text the service printed: what is offered
        // has to be what would be stored. A date the reader could not parse
        // offers nothing, and the sheet says the service's own wording beside
        // it (`MetadataCandidate.publishedText`).
        add(
            .field(.published), BookField.published.label,
            current: BookField.published.text(of: book),
            proposed: candidate.published.map(BookField.day))
        add(
            .field(.language), BookField.language.label,
            current: BookField.language.text(of: book), proposed: candidate.language)
        add(
            .field(.description), BookField.description.label,
            current: BookField.description.text(of: book), proposed: candidate.summary)

        if let isbn = candidate.identifiers["isbn"], ISBN.isValid(isbn) {
            add(
                .identifier("isbn"), "ISBN", current: book.identifiers["isbn"] ?? "",
                proposed: ISBN.normalised(isbn))
        }

        let newTags = tagsToAdd(for: book, from: candidate)
        if !newTags.isEmpty {
            lines.append(
                FieldProposal(
                    target: .tags, label: "Tags",
                    current: book.tags.joined(separator: ", "),
                    proposed: newTags.joined(separator: ", "),
                    // Never a replacement: `apply` adds these and removes
                    // nothing (`TagEdit`), so a line saying "would replace"
                    // would be describing something that does not happen.
                    kind: book.tags.isEmpty ? .add : .append,
                    isTickedByDefault: false))
        }
        return lines
    }

    /// The subjects the book does not already carry, case-insensitively.
    ///
    /// Case-insensitively because `TagEdit` is: "Science Fiction" and "science
    /// fiction" are one keyword, and offering the second to a library that
    /// holds the first is offering a duplicate.
    static func tagsToAdd(for book: Book, from candidate: MetadataCandidate) -> [String] {
        let held = Set(book.tags.map { $0.lowercased() })
        var seen: Set<String> = []
        return candidate.subjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !held.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
    }

    /// Applies the ticked lines, and nothing else.
    ///
    /// Each line goes through the field rule that owns it, so a value from the
    /// net is checked exactly as a typed one: a title may not be emptied, a
    /// series index must be a number, an ISBN must pass its check digit. A line
    /// whose rule refuses it is **left out and named** in the result rather than
    /// failing the whole application — one bad ISBN must not cost the other ten
    /// fields.
    ///
    /// Tags are *added*. Nothing a person put on a book is taken off it because
    /// a service has not heard of it.
    public static func apply(_ chosen: [FieldProposal], to book: Book) -> Applied {
        var edited = book
        var refused: [(label: String, why: BookFieldRejection)] = []

        for line in chosen {
            switch line.target {
            case .field(let field):
                switch field.apply(line.proposed, to: edited) {
                case .changed(let updated): edited = updated
                case .unchanged: break
                case .rejected(let why): refused.append((line.label, why))
                }
            case .identifier(let scheme):
                switch IdentifierEdit.set(scheme: scheme, value: line.proposed, in: edited) {
                case .changed(let updated): edited = updated
                case .unchanged: break
                case .rejected(let why): refused.append((line.label, why))
                }
            case .tags:
                for tag in line.proposed.components(separatedBy: ", ") {
                    if case .changed(let updated) = TagEdit.add(tag, to: edited) { edited = updated }
                }
            }
        }
        return Applied(book: edited, refused: refused.map { Refusal(label: $0.label, why: $0.why) })
    }

    public struct Applied: Equatable, Sendable {
        public var book: Book
        public var refused: [Refusal]
    }

    public struct Refusal: Equatable, Sendable {
        public var label: String
        public var why: BookFieldRejection
        public var message: String { "\(label): \(why.message)" }
    }
}
