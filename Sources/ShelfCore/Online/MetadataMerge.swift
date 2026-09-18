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
    /// **Who** says it, in `MetadataSource`'s own order.
    ///
    /// Two entries when both services said the same thing, and the line names
    /// both: two catalogues agreeing is a different fact from one catalogue
    /// asserting, and a sheet that hid it was asking for a decision with half
    /// the evidence. Where they *disagree* there is no combined line at all —
    /// there are two lines, one per service, and `sameTarget` makes them
    /// exclusive.
    public let sources: [MetadataSource]
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

    public init(
        target: Target, label: String, current: String, proposed: String,
        sources: [MetadataSource], kind: Kind, isTickedByDefault: Bool
    ) {
        self.target = target
        self.label = label
        self.current = current
        self.proposed = proposed
        self.sources = sources
        self.kind = kind
        self.isTickedByDefault = isTickedByDefault
    }

    /// Which **field** the line is about. Two services that disagree make two
    /// lines sharing this and differing in `id`.
    public var targetID: String {
        switch target {
        case .field(let field): return field.rawValue
        case .tags: return "tags"
        case .identifier(let scheme): return "identifier:\(scheme)"
        }
    }

    /// The field *and* who offered it, because the field alone is no longer
    /// unique. Stable across runs: the sources are in `MetadataSource` order.
    public var id: String { "\(targetID)@\(sources.map(\.slug).joined(separator: "+"))" }

    /// What the sheet writes beside the field's name: "Open Library", or
    /// "Open Library · Google Books" where the two agree.
    public var sourceLabel: String { sources.map(\.name).joined(separator: " · ") }

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
        proposals(for: book, from: [candidate])
    }

    /// The same, from **every** record the comparison covers — which is more
    /// than one whenever both services answered about this edition.
    ///
    /// With two services, "what the service says" is not a sentence any more.
    /// So each line names who said it, and where the two say *different*
    /// things there are **two lines**, one per service, each with its own box.
    /// Folding them into one line would have meant picking a winner without
    /// saying so; showing one and dropping the other would have meant hiding an
    /// answer that had already been fetched.
    ///
    /// Two consequences, both deliberate:
    ///
    /// - **A contested field arrives unticked**, even where both answers would
    ///   fill a gap. Two catalogues disagreeing is the clearest possible signal
    ///   that this one is a person's decision.
    /// - **Rival lines are exclusive** (`ticking`): a field holds one value, so
    ///   ticking Google Books' publisher unticks Open Library's. Tags are the
    ///   exception — they are added, so both services' subjects can be taken.
    ///
    /// Which records belong in one comparison is `EditionMatch`'s decision, not
    /// this function's: it draws whatever it is handed.
    public static func proposals(for book: Book, from candidates: [MetadataCandidate]) -> [FieldProposal] {
        let ordered = candidates.sorted {
            (MetadataSource.allCases.firstIndex(of: $0.source) ?? 0)
                < (MetadataSource.allCases.firstIndex(of: $1.source) ?? 0)
        }
        return lines(from: ordered.flatMap { offers(for: book, from: $0) })
    }

    /// One service's answer about one field, before the lines are built.
    struct Offer: Equatable {
        let target: FieldProposal.Target
        let label: String
        let current: String
        let proposed: String
        let source: MetadataSource
        /// False for a publisher, a language or a year out of a *work* record:
        /// they belong to some edition and not necessarily to this one.
        let trustworthy: Bool
    }

    /// Everything one candidate has an opinion about, in the order the
    /// inspector shows the fields.
    static func offers(for book: Book, from candidate: MetadataCandidate) -> [Offer] {
        var offers = bookFieldOffers(for: book, from: candidate)

        func add(_ target: FieldProposal.Target, _ label: String, current: String, proposed: String?) {
            guard let proposed, !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            offers.append(
                Offer(
                    target: target, label: label, current: current, proposed: proposed,
                    source: candidate.source,
                    trustworthy: candidate.describesOneEdition
                        || !FieldProposal.editionLevel.contains(target)))
        }

        if let isbn = candidate.identifiers["isbn"], ISBN.isValid(isbn) {
            add(
                .identifier("isbn"), "ISBN", current: book.identifiers["isbn"] ?? "",
                proposed: ISBN.normalised(isbn))
        }
        let newTags = tagsToAdd(for: book, from: candidate)
        if !newTags.isEmpty {
            add(
                .tags, "Tags", current: book.tags.joined(separator: ", "),
                proposed: newTags.joined(separator: ", "))
        }
        return offers
    }

    private static func bookFieldOffers(for book: Book, from candidate: MetadataCandidate) -> [Offer] {
        var offers: [Offer] = []

        func add(_ target: FieldProposal.Target, _ label: String, current: String, proposed: String?) {
            guard let proposed, !proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            offers.append(
                Offer(
                    target: target, label: label, current: current, proposed: proposed,
                    source: candidate.source,
                    trustworthy: candidate.describesOneEdition
                        || !FieldProposal.editionLevel.contains(target)))
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
        return offers
    }

    /// The offers grouped into lines: one line per distinct answer, naming
    /// every service that gave it.
    ///
    /// The field order is the order the offers arrive in — the inspector's —
    /// and within one field the answers are in the order the services are
    /// asked, so the sheet reads the same way on every run.
    static func lines(from offers: [Offer]) -> [FieldProposal] {
        var order: [FieldProposal.Target] = []
        var grouped: [FieldProposal.Target: [Offer]] = [:]
        for offer in offers {
            if grouped[offer.target] == nil { order.append(offer.target) }
            grouped[offer.target, default: []].append(offer)
        }
        return order.flatMap { rows(for: grouped[$0] ?? []) }
    }

    /// The lines for one field: one per distinct value.
    static func rows(for offers: [Offer]) -> [FieldProposal] {
        var representatives: [Offer] = []
        var sources: [String: [MetadataSource]] = [:]
        var trusted: [String: Bool] = [:]
        for offer in offers {
            if sources[offer.proposed] == nil { representatives.append(offer) }
            sources[offer.proposed, default: []].append(offer.source)
            trusted[offer.proposed] = (trusted[offer.proposed] ?? true) && offer.trustworthy
        }
        // Two services with two different answers: neither is ticked. The
        // disagreement is the thing worth showing, and resolving it silently in
        // favour of whichever was asked first would be the opposite of showing
        // it.
        let contested = representatives.count > 1
        return representatives.map { offer in
            let kind = kind(of: offer)
            let fillsAGap = kind == .add && (trusted[offer.proposed] ?? false) && !contested
            return FieldProposal(
                target: offer.target, label: offer.label, current: offer.current,
                proposed: offer.proposed, sources: sources[offer.proposed] ?? [offer.source],
                kind: kind,
                // Tags are never ticked for somebody: a catalogue's subjects
                // are catalogue vocabulary and a person's tags are their own.
                isTickedByDefault: offer.target == .tags ? false : fillsAGap)
        }
    }

    static func kind(of offer: Offer) -> FieldProposal.Kind {
        // Tags are never a replacement: `apply` adds these and removes nothing
        // (`TagEdit`), so a line saying "would replace" would be describing
        // something that does not happen.
        if offer.target == .tags { return offer.current.isEmpty ? .add : .append }
        if offer.current == offer.proposed { return .same }
        return offer.current.isEmpty ? .add : .replace
    }

    /// Ticking a line, with the rule that two answers to one field are a
    /// choice between them.
    ///
    /// A field holds one value: applying Open Library's publisher *and* Google
    /// Books' would let whichever `apply` reached last win, quietly. So ticking
    /// one rival unticks the other. Tags are exempt — they are added, and two
    /// catalogues' subjects can both be wanted.
    public static func ticking(
        _ proposal: FieldProposal, in proposals: [FieldProposal], ticked: Set<String>
    ) -> Set<String> {
        guard proposal.kind != .same else { return ticked }
        var result = ticked
        if result.contains(proposal.id) {
            result.remove(proposal.id)
            return result
        }
        if proposal.target != .tags {
            for rival in proposals where rival.targetID == proposal.targetID && rival.id != proposal.id {
                result.remove(rival.id)
            }
        }
        result.insert(proposal.id)
        return result
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
