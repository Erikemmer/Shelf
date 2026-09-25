import Foundation

/// Filling every book's missing fields at once, strictly by ISBN — Teil C4.
///
/// The one-book-at-a-time "Fetch Metadata…" sheet (ADR 0015) exists because a
/// **title search** can return nine editions and a translation, and needs a
/// person to pick between them. An **ISBN search names one edition by
/// construction** — there is nothing to pick between, only an answer or none —
/// so the same trust rules that sheet already applies per field
/// (`MetadataMerge.isTickedByDefault`: fill an empty field, only from a record
/// that is about this edition, never where two services disagree) can run for
/// every book with a valid ISBN in one pass, shown as one combined preview
/// before anything writes. See the dated addendum on ADR 0015 for why this is
/// not the "automatic bulk match" that ADR's own rule 5 rules out.
///
/// **Never a title+author search for an arbitrary field.** A book with no
/// ISBN, or whose ISBN search comes back empty, is left exactly as it is by
/// the ISBN pass. The one exception is `description`, gated by
/// `DescriptionFill`'s own four conditions, applied on top of whatever the
/// ISBN pass already did — a book can end up with both an ISBN-sourced
/// publisher and a Title+Author-sourced description in the same run, and the
/// preview names which is which.
public enum FillMissingFields {
    /// One field a run would fill, and where the value came from — the
    /// preview's own line, and the exact value `apply` writes (ADR 0018).
    public struct Proposal: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            case isbn(MetadataSource)
            /// Teil B3: an ASIN search that named exactly one work with
            /// exactly one edition, trusted the same way an ISBN is.
            case asin(MetadataSource)
            case titleAuthor(MetadataSource)
        }
        public var label: String
        public var current: String
        public var proposed: String
        public var source: Source
    }

    public struct BookPlan: Sendable {
        public var entry: LibraryEntry
        public var proposals: [Proposal]
        public var change: MetadataChange
    }

    /// Why a book is not in `plans` — the report's own "left untouched, and
    /// why" line, never a silent omission.
    public enum UnchangedReason: Sendable {
        /// No valid ISBN, and no title to ask a Title+Author question with
        /// either — there was nothing to ask.
        case nothingToAskWith
        /// A question was asked; nothing came back to answer it.
        case noAnswer
        /// An answer came back; every field it could fill, the book already
        /// had, or the record disagreed with itself, or with the language.
        case nothingToFill
    }

    public struct Unchanged: Sendable {
        public var entry: LibraryEntry
        public var reason: UnchangedReason
    }

    public struct Result: Sendable {
        public var plans: [BookPlan]
        public var unchanged: [Unchanged]
        /// One line per service failure, deduplicated across the whole run —
        /// a service down for ten minutes should not repeat itself four
        /// hundred times in the report.
        public var problems: [String]
        /// How many books' lookups skipped a service outright because it had
        /// already answered 429 earlier in this same run — the count behind
        /// `problems`' one "answered 429" line, for a report that wants to
        /// say how much of the run that one refusal actually covered.
        public var serviceSkips: [MetadataSource: Int]
    }

    /// Runs the ISBN pass and the description exception across every entry,
    /// sequentially. `MetadataFetcher` is an actor that already paces its own
    /// calls per service across every request it is given (Sprint 6), so this
    /// is a plain loop and needs no rate limiting of its own.
    ///
    /// `progress`, when given, is called after every book with how many have
    /// been asked about so far — a real library paced at one request per
    /// second per service can take minutes, and a window with nothing moving
    /// in it for minutes is indistinguishable from one that has hung.
    public static func plan(
        over entries: [LibraryEntry], fetcher: MetadataFetcher, at now: Date = Date(),
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Result {
        var plans: [BookPlan] = []
        var unchanged: [Unchanged] = []
        var problems: Set<String> = []
        // Once a service answers 429 for one book, it is not asked again for
        // any later one — "stop" said once covers the rest of this run, the
        // same way `NetworkPolicy` already treats it within one request.
        var blockedSources: Set<MetadataSource> = []
        var serviceSkips: [MetadataSource: Int] = [:]

        for (done, entry) in entries.enumerated() {
            defer { progress?(done + 1, entries.count) }
            var working = entry.book
            var proposals: [Proposal] = []
            var reason: UnchangedReason = .nothingToAskWith

            if let query = MetadataQuery.about(entry.book), case .isbn(let isbn) = query {
                reason = .noAnswer
                let result = await fetcher.candidates(for: query, skipping: blockedSources)
                problems.formUnion(result.problems)
                for source in result.skippedSources { serviceSkips[source, default: 0] += 1 }
                blockedSources.formUnion(result.refusedTooManyRequests)

                // Teil B2: Open Library's own per-ISBN edition endpoint
                // genuinely answers one edition (Sprint 21, Teil A1), folded
                // into the `/search.json` candidate above rather than shown
                // beside it — never asked once Open Library has already said
                // "stop" this run, in this book's own answer above or an
                // earlier book's.
                var candidates = result.candidates
                var editionRecord: OpenLibraryEdition?
                if !blockedSources.contains(.openLibrary) {
                    let edition = await fetcher.openLibraryEdition(forISBN: isbn)
                    if edition.refusedTooManyRequests { blockedSources.insert(.openLibrary) }
                    if let record = edition.edition {
                        editionRecord = record
                        candidates = EditionMerge.folding(record, into: candidates)
                    }
                }

                let ranked = MetadataScore.ranked(candidates, for: query)
                if let best = ranked.first {
                    reason = .nothingToFill
                    let comparison = EditionMatch.comparison(of: best.candidate, among: ranked, asked: query)
                    let ticked = MetadataMerge.proposals(for: working, from: comparison).filter(\.isTickedByDefault)
                    if !ticked.isEmpty {
                        working = MetadataMerge.apply(ticked, to: working).book
                        proposals += ticked.map {
                            Proposal(
                                label: $0.label, current: $0.current, proposed: $0.proposed,
                                source: .isbn($0.sources.first ?? .openLibrary))
                        }
                    }
                }

                // Teil B1, chained from B2's own edition record: its work
                // key is the one place Open Library ever carries a
                // description at all.
                if (working.description ?? "").isEmpty, let workKey = editionRecord?.workKey {
                    let described = await DescriptionFill.fromEdition(
                        workKey: workKey, editionLanguage: editionRecord?.language, bookLanguage: working.language,
                        fetcher: fetcher)
                    if described.refused.contains(.openLibrary) { blockedSources.insert(.openLibrary) }
                    if let found = described.summary {
                        working.description = found.summary
                        proposals.append(
                            Proposal(
                                label: BookField.description.label, current: entry.book.description ?? "",
                                proposed: found.summary, source: .isbn(.openLibrary)))
                    }
                }
            } else if let asin = AmazonASIN.valid(in: entry.book.identifiers) {
                // Teil B3: the same trust rule as B2, reached through an ASIN
                // instead of an ISBN — only when the search named exactly
                // one work with exactly one edition (`OpenLibraryASINSearch`,
                // ADR 0015's own addendum on this). Counts as a skip, the same
                // way the ISBN branch's own `candidates(for:skipping:)` call
                // does, rather than silently looking like nothing to ask.
                reason = .noAnswer
                if blockedSources.contains(.openLibrary) {
                    serviceSkips[.openLibrary, default: 0] += 1
                } else {
                    let lookup = await fetcher.openLibraryEditionForASIN(asin)
                    if lookup.refusedTooManyRequests { blockedSources.insert(.openLibrary) }
                    if let record = lookup.edition {
                        reason = .nothingToFill
                        let candidate = record.asCandidate(extraIdentifiers: ["asin": asin])
                        let ticked = MetadataMerge.proposals(for: working, from: candidate).filter(\.isTickedByDefault)
                        if !ticked.isEmpty {
                            working = MetadataMerge.apply(ticked, to: working).book
                            proposals += ticked.map {
                                Proposal(
                                    label: $0.label, current: $0.current, proposed: $0.proposed,
                                    source: .asin($0.sources.first ?? .openLibrary))
                            }
                        }

                        // Teil B1, chained from B3's own edition record —
                        // identical to the ISBN branch above.
                        if (working.description ?? "").isEmpty, let workKey = record.workKey {
                            let described = await DescriptionFill.fromEdition(
                                workKey: workKey, editionLanguage: record.language, bookLanguage: working.language,
                                fetcher: fetcher)
                            if described.refused.contains(.openLibrary) { blockedSources.insert(.openLibrary) }
                            if let found = described.summary {
                                working.description = found.summary
                                proposals.append(
                                    Proposal(
                                        label: BookField.description.label, current: entry.book.description ?? "",
                                        proposed: found.summary, source: .asin(.openLibrary)))
                            }
                        }
                    }
                }
            }

            let described = await DescriptionFill.find(for: working, fetcher: fetcher, skipping: blockedSources)
            problems.formUnion(described.problems)
            for source in described.skipped { serviceSkips[source, default: 0] += 1 }
            blockedSources.formUnion(described.refused)
            if let found = described.summary {
                working.description = found.summary
                proposals.append(
                    Proposal(
                        label: BookField.description.label, current: entry.book.description ?? "",
                        proposed: found.summary, source: .titleAuthor(found.source)))
            }

            let change = MetadataChange.make(from: entry.book, at: now) { $0 = working }
            if !change.isEmpty {
                plans.append(BookPlan(entry: entry, proposals: proposals, change: change))
            } else {
                unchanged.append(Unchanged(entry: entry, reason: reason))
            }
        }

        return Result(plans: plans, unchanged: unchanged, problems: problems.sorted(), serviceSkips: serviceSkips)
    }
}

/// The one Title+Author exception C4 allows, and only for `description`.
///
/// Every other field is ISBN-only: a title and an author name a *book*, of
/// which there may be nine editions, and offering a publisher or a date from
/// a guessed edition is exactly what `MetadataQuery`'s own doc comment warns
/// against. A description is different — the same on every printing, close
/// enough — so the risk worth gating is not "the wrong edition" but "the
/// wrong *book*", and that is what all four conditions below are for.
public enum DescriptionFill {
    /// The shortest a real synopsis is ever seen to be; short of it, a
    /// snippet ("Winner of the Booker Prize") is more likely than a summary.
    static let minimumLength = 80

    /// One try at filling `description`, and everything a batch run needs to
    /// know about the services it spent doing so.
    struct Attempt {
        var summary: (summary: String, source: MetadataSource)?
        var problems: [String] = []
        /// Services not asked this time because an earlier book in the same
        /// run already had one refuse with 429.
        var skipped: Set<MetadataSource> = []
        /// Services that answered 429 to *this* book's own question.
        var refused: Set<MetadataSource> = []
    }

    /// An empty `summary` when any of the four conditions fails — never a
    /// guess, and never applied where the field already holds something.
    static func find(
        for book: Book, fetcher: MetadataFetcher, skipping: Set<MetadataSource> = []
    ) async -> Attempt {
        // (a) the field is empty.
        guard (book.description ?? "").isEmpty else { return Attempt() }
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return Attempt() }
        guard let bookLanguage = book.language, !bookLanguage.isEmpty else { return Attempt() }
        guard !book.authors.isEmpty else { return Attempt() }

        let query = MetadataQuery.titleAuthor(title: title, author: book.authors.first)
        let result = await fetcher.candidates(for: query, skipping: skipping)
        var attempt = Attempt(
            problems: result.problems, skipped: result.skippedSources, refused: result.refusedTooManyRequests)

        let ourTitle = TitleNormalization.matchable(title)
        let ourAuthors = Set(book.authors.map(AuthorNameFold.normalized))
        // (b) exactly one candidate shares the exact normalized title and
        // every author — corroborating identity by two words agreeing
        // stands in for the ISBN this book does not have, or whose search
        // came back with nothing.
        let matches = result.candidates.filter {
            TitleNormalization.matchable($0.title) == ourTitle
                && Set($0.authors.map(AuthorNameFold.normalized)) == ourAuthors
        }
        guard matches.count == 1, let candidate = matches.first else { return attempt }
        // (c) a known language, and it agrees with the book's own — ignoring
        // a region or script subtag on either side (`LanguageCode.matches`).
        guard let candidateLanguage = candidate.language, !candidateLanguage.isEmpty,
            LanguageCode.matches(candidateLanguage, bookLanguage)
        else { return attempt }

        // Teil B1: `/search.json` never carries a description at all
        // (`OpenLibraryReader`'s own `summary: nil`) — its *work* record
        // might. Google Books' answer already carries its own description
        // inline, so this is asked only when the unique match is Open
        // Library's, and only once — the work key is right there in the
        // candidate this run already fetched.
        var summary = candidate.summary
        if summary == nil, candidate.source == .openLibrary,
            let workKey = OpenLibraryReader.workKey(fromCandidateID: candidate.id)
        {
            let work = await fetcher.openLibraryWorkDescription(key: workKey)
            if work.refusedTooManyRequests { attempt.refused.insert(.openLibrary) }
            summary = work.description
        }

        // (d) long enough to be a summary, and no markup beyond a paragraph
        // break — never an HTML fragment the inspector would show verbatim.
        guard let summary, isPlainEnough(summary) else { return attempt }

        attempt.summary = (summary, candidate.source)
        return attempt
    }

    /// Teil B1's own chain from an edition record the ISBN or ASIN route
    /// already found (`FillMissingFields`' own branches): the same language
    /// and plain-text checks as conditions (c)/(d) above, without condition
    /// (b) — an ISBN or a uniquely-resolved ASIN is a stronger identity
    /// guarantee than a Title+Author match ever is, so there is no second
    /// candidate here to disambiguate against.
    static func fromEdition(
        workKey: String, editionLanguage: String?, bookLanguage: String?, fetcher: MetadataFetcher
    ) async -> Attempt {
        guard let editionLanguage, !editionLanguage.isEmpty,
            let bookLanguage, !bookLanguage.isEmpty,
            LanguageCode.matches(editionLanguage, bookLanguage)
        else { return Attempt() }
        let work = await fetcher.openLibraryWorkDescription(key: workKey)
        var attempt = Attempt()
        if work.refusedTooManyRequests { attempt.refused.insert(.openLibrary) }
        guard let summary = work.description, isPlainEnough(summary) else { return attempt }
        attempt.summary = (summary, .openLibrary)
        return attempt
    }

    static func isPlainEnough(_ text: String) -> Bool {
        guard text.count > minimumLength else { return false }
        let allowedTags = ["<p>", "</p>", "<br>", "<br/>", "<br />"]
        var stripped = text
        for tag in allowedTags {
            stripped = stripped.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        return stripped.range(of: "<[^>]+>", options: .regularExpression) == nil
    }
}
