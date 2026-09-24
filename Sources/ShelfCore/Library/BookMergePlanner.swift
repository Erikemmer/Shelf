import Foundation

/// What asking a format file "how good is this copy" turns out to answer —
/// the three questions B3's tie-break rule asks after DRM and before size,
/// each one requiring the bytes to actually be read, which is why this is a
/// question the core asks *through* an injected probe rather than answering
/// itself: `ShelfCore` reads what it can (EPUB, MOBI, AZW3), the app layer
/// reads the rest (PDF, CBR), and neither reads KFX at all (ADR 0011).
public struct FormatQuality: Sendable, Equatable {
    public var opensSuccessfully: Bool
    public var hasCover: Bool
    public var filledFieldCount: Int

    public init(opensSuccessfully: Bool, hasCover: Bool, filledFieldCount: Int) {
        self.opensSuccessfully = opensSuccessfully
        self.hasCover = hasCover
        self.filledFieldCount = filledFieldCount
    }
}

public typealias FormatQualityProbe = @Sendable (URL, BookFileFormat) -> FormatQuality

/// B3's own tie-break, for two files of the *same* format whose bytes
/// differ: without DRM beats protected, opens beats does not, has a cover
/// beats does not, more filled fields beats fewer, and only then does size
/// decide. Never asked of two files of different formats — those are never
/// in competition, they are simply both formats the merged book now has.
enum FormatPreference {
    static func preferred(
        _ a: BookFormat, _ aQuality: FormatQuality, over b: BookFormat, _ bQuality: FormatQuality
    ) -> Bool {
        if (a.drm == nil) != (b.drm == nil) { return a.drm == nil }
        if aQuality.opensSuccessfully != bQuality.opensSuccessfully { return aQuality.opensSuccessfully }
        if aQuality.hasCover != bQuality.hasCover { return aQuality.hasCover }
        if aQuality.filledFieldCount != bQuality.filledFieldCount {
            return aQuality.filledFieldCount > bQuality.filledFieldCount
        }
        return a.byteSize > b.byteSize
    }
}

/// Filling a survivor's empty fields from the books it absorbs, per B1: a
/// field the survivor already answers keeps its answer, and a disagreement
/// among the absorbed books that would have filled an empty field is left
/// empty rather than guessed at — the same "nichts raten" the rest of this
/// project holds to.
public enum BookMetadataMerge {
    public struct Fill: Equatable, Sendable {
        public var field: MetadataChange.Field
        public var value: String
        public var fromBookID: UUID
    }

    public struct Conflict: Equatable, Sendable {
        public var field: MetadataChange.Field
        /// Empty when the survivor itself had nothing to contribute – the
        /// conflict is then only among the absorbed books, and the field
        /// stays empty rather than picking one of them.
        public var survivingValue: String
        public var otherValues: [(bookID: UUID, value: String)]

        public static func == (lhs: Conflict, rhs: Conflict) -> Bool {
            lhs.field == rhs.field && lhs.survivingValue == rhs.survivingValue
                && lhs.otherValues.map(\.bookID) == rhs.otherValues.map(\.bookID)
                && lhs.otherValues.map(\.value) == rhs.otherValues.map(\.value)
        }
    }

    public struct Result: Sendable {
        public var book: Book
        public var fills: [Fill]
        public var conflicts: [Conflict]
    }

    public static func merge(surviving: Book, absorbed: [(id: UUID, book: Book)]) -> Result {
        var book = surviving
        var fills: [Fill] = []
        var conflicts: [Conflict] = []

        resolve(
            .series, survivor: surviving.series, absorbed: absorbed.map { ($0.id, $0.book.series) },
            display: { $0.display }, into: &fills, &conflicts
        ) { book.series = $0 }
        resolve(
            .publisher, survivor: nonEmpty(surviving.publisher),
            absorbed: absorbed.map { ($0.id, nonEmpty($0.book.publisher)) }, display: { $0 }, into: &fills,
            &conflicts
        ) { book.publisher = $0 }
        // Normalised before comparing, not only before grouping (`MergeCandidates`
        // does the same): a MOBI's EXTH record saying `eng` beside an EPUB's
        // `dc:language` saying `en` is the same language, not a conflict, and
        // filling from it should write the canonical two-letter form C3 asks
        // for rather than whichever raw spelling happened to be read first.
        resolve(
            .language, survivor: nonEmpty(surviving.language).map(LanguageCode.normalised),
            absorbed: absorbed.map { ($0.id, nonEmpty($0.book.language).map(LanguageCode.normalised)) },
            display: { $0 }, into: &fills, &conflicts
        ) { book.language = $0 }
        resolve(
            .description, survivor: nonEmpty(surviving.description),
            absorbed: absorbed.map { ($0.id, nonEmpty($0.book.description)) }, display: { $0 }, into: &fills,
            &conflicts
        ) { book.description = $0 }
        resolve(
            .published, survivor: surviving.published, absorbed: absorbed.map { ($0.id, $0.book.published) },
            display: { OPFDate.render($0) }, into: &fills, &conflicts
        ) { book.published = $0 }
        resolve(
            .identifiers, survivor: surviving.isbn, absorbed: absorbed.map { ($0.id, $0.book.isbn) },
            display: { $0 }, into: &fills, &conflicts
        ) { if let value = $0 { book.identifiers["isbn"] = value } }

        book.tags = Array(Set(surviving.tags + absorbed.flatMap(\.book.tags))).sorted()
        book.shelves = Array(Set(surviving.shelves + absorbed.flatMap(\.book.shelves))).sorted()

        return Result(book: book, fills: fills, conflicts: conflicts)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// One field's whole rule, generic over whatever equatable value the
    /// field holds: an empty survivor is filled only when every absorbed
    /// book that has an answer agrees on it; a non-empty survivor keeps its
    /// own value and counts a disagreement rather than acting on it.
    private static func resolve<Value: Hashable>(
        _ field: MetadataChange.Field, survivor: Value?, absorbed: [(UUID, Value?)],
        display: (Value) -> String, into fills: inout [Fill], _ conflicts: inout [Conflict],
        apply: (Value?) -> Void
    ) {
        let present = absorbed.compactMap { id, value in value.map { (id, $0) } }
        if let survivor {
            let disagreeing = present.filter { $0.1 != survivor }
            if !disagreeing.isEmpty {
                conflicts.append(
                    Conflict(
                        field: field, survivingValue: display(survivor),
                        otherValues: disagreeing.map { ($0.0, display($0.1)) }))
            }
            return
        }
        let distinctValues = Set(present.map(\.1))
        guard let first = present.first else { return }
        if distinctValues.count == 1 {
            apply(first.1)
            fills.append(Fill(field: field, value: display(first.1), fromBookID: first.0))
        } else {
            conflicts.append(
                Conflict(field: field, survivingValue: "", otherValues: present.map { ($0.0, display($0.1)) }))
        }
    }
}

/// One file that will move into the surviving book's folder.
public struct BookMergeMove: Equatable, Sendable, Identifiable {
    public var sourceBookID: UUID
    public var format: BookFormat
    public var id: String { format.id }
}

/// One file that goes straight to the Trash instead of moving anywhere —
/// either a byte-for-byte copy of a file the survivor already keeps, or the
/// loser of `FormatPreference`'s tie-break among several different-content
/// files of the same format.
public struct BookMergeDiscard: Equatable, Sendable, Identifiable {
    public enum Reason: String, Sendable {
        case byteIdenticalDuplicate
        case losingTiebreak
    }
    public var sourceBookID: UUID
    public var format: BookFormat
    public var reason: Reason
    public var id: String { format.id }
}

/// The whole plan for one group of books becoming one: the preview a person
/// sees, executed exactly as shown (ADR 0018) — nothing here is recomputed
/// once a run starts.
public struct BookMergeGroupPlan: Equatable, Sendable, Identifiable {
    public var survivingID: UUID
    public var survivingTitle: String
    public var absorbedIDs: [UUID]
    public var moves: [BookMergeMove]
    public var discards: [BookMergeDiscard]
    public var fills: [BookMetadataMerge.Fill]
    public var conflicts: [BookMetadataMerge.Conflict]
    /// The book whose cover file should be copied in, when the survivor has
    /// none of its own. `nil` means either the survivor already has one, or
    /// nobody in the group does.
    public var coverFromBookID: UUID?

    public var id: UUID { survivingID }
}

public struct BookMergePlan: Equatable, Sendable {
    public var groups: [BookMergeGroupPlan]

    public init(groups: [BookMergeGroupPlan] = []) {
        self.groups = groups
    }

    public static let empty = BookMergePlan()
    public var isEmpty: Bool { groups.isEmpty }

    public func summary() -> String {
        let books = groups.reduce(0) { $0 + 1 + $1.absorbedIDs.count }
        let discarded = groups.reduce(0) { $0 + $1.discards.count }
        return "\(groups.count) groups · \(books) books · \(discarded) files to the Trash"
    }
}

/// Turning `MergeGroup`s into a full `BookMergePlan` — the file-preference
/// tie-break (B3), the metadata union (`BookMetadataMerge`), and the cover
/// rule, all as one preview.
///
/// Disk questions arrive through injected closures, the same seam
/// `OrganizeBookProbe` uses for the same reason: the *decision* stays
/// testable without a folder on disk, and only the app layer's real probe
/// ever has to know how to actually open a PDF or a CBR.
public enum BookMergePlanner {
    public static func plan(
        groups: [MergeGroup], entries: [UUID: LibraryEntry], library: Library,
        quality: FormatQualityProbe, hasCover: @Sendable (URL) -> Bool,
        chooseSurvivor: ([LibraryEntry]) -> LibraryEntry = defaultSurvivor
    ) -> BookMergePlan {
        let groupPlans = groups.compactMap { group -> BookMergeGroupPlan? in
            let members = group.bookIDs.compactMap { entries[$0] }
            guard members.count > 1 else { return nil }
            return planGroup(
                members: members, library: library, quality: quality, hasCover: hasCover,
                chooseSurvivor: chooseSurvivor)
        }
        return BookMergePlan(groups: groupPlans)
    }

    /// The lowest book number survives by default — stable, and the same
    /// "first by number" order the rest of this project already treats as
    /// canonical (`Scripts/proof-run.sh`'s own "first N books by number").
    /// An interactive "Merge Books…" on an explicit selection overrides this
    /// with whichever book the person designated.
    public static func defaultSurvivor(_ members: [LibraryEntry]) -> LibraryEntry {
        members.min { $0.number < $1.number } ?? members[0]
    }

    private static func planGroup(
        members: [LibraryEntry], library: Library, quality: FormatQualityProbe,
        hasCover: @Sendable (URL) -> Bool, chooseSurvivor: ([LibraryEntry]) -> LibraryEntry
    ) -> BookMergeGroupPlan {
        let survivor = chooseSurvivor(members)
        let absorbed = members.filter { $0.id != survivor.id }

        let candidatesByFormat = Dictionary(grouping: members.flatMap { member in member.formats.map { (member, $0) } })
        {
            $0.1.format
        }

        var moves: [BookMergeMove] = []
        var discards: [BookMergeDiscard] = []
        for candidates in candidatesByFormat.values {
            let winner = chooseWinner(
                candidates, survivorID: survivor.id, library: library, quality: quality, discards: &discards)
            if winner.0.id != survivor.id {
                moves.append(BookMergeMove(sourceBookID: winner.0.id, format: winner.1))
            }
        }

        let merged = BookMetadataMerge.merge(surviving: survivor.book, absorbed: absorbed.map { ($0.id, $0.book) })
        let coverFromBookID = chooseCover(survivor: survivor, absorbed: absorbed, library: library, hasCover: hasCover)

        return BookMergeGroupPlan(
            survivingID: survivor.id, survivingTitle: survivor.book.title, absorbedIDs: absorbed.map(\.id),
            moves: moves, discards: discards, fills: merged.fills, conflicts: merged.conflicts,
            coverFromBookID: coverFromBookID)
    }

    /// One format type's whole story: byte-identical copies collapse to one
    /// (preferring the survivor's own, else the lowest book number), and only
    /// then, if distinct content remains, does `FormatPreference` decide.
    private static func chooseWinner(
        _ candidates: [(LibraryEntry, BookFormat)], survivorID: UUID, library: Library,
        quality: FormatQualityProbe, discards: inout [BookMergeDiscard]
    ) -> (LibraryEntry, BookFormat) {
        guard candidates.count > 1 else { return candidates[0] }

        let bySha = Dictionary(grouping: candidates) { $0.1.sha256 }
        var reduced: [(LibraryEntry, BookFormat)] = []
        for group in bySha.values {
            guard group.count > 1 else {
                reduced.append(group[0])
                continue
            }
            let keeper = group.first { $0.0.id == survivorID } ?? group.min { $0.0.number < $1.0.number }!
            reduced.append(keeper)
            for (entry, format) in group where format.id != keeper.1.id {
                discards.append(
                    BookMergeDiscard(sourceBookID: entry.id, format: format, reason: .byteIdenticalDuplicate))
            }
        }

        guard reduced.count > 1 else { return reduced[0] }
        var best = reduced[0]
        var bestQuality = quality(fileURL(for: best, library: library), best.1.format)
        for candidate in reduced.dropFirst() {
            let candidateQuality = quality(fileURL(for: candidate, library: library), candidate.1.format)
            if FormatPreference.preferred(candidate.1, candidateQuality, over: best.1, bestQuality) {
                discards.append(BookMergeDiscard(sourceBookID: best.0.id, format: best.1, reason: .losingTiebreak))
                best = candidate
                bestQuality = candidateQuality
            } else {
                discards.append(
                    BookMergeDiscard(sourceBookID: candidate.0.id, format: candidate.1, reason: .losingTiebreak))
            }
        }
        return best
    }

    private static func fileURL(for pair: (LibraryEntry, BookFormat), library: Library) -> URL {
        library.root.appendingPathComponent(pair.0.folder, isDirectory: true)
            .appendingPathComponent(pair.1.fileName)
    }

    /// The survivor's own cover stays, untouched, if it has one — never
    /// asked which absorbed cover might be "better". Only when the survivor
    /// has none at all does an absorbed book's cover get a say, and the
    /// first one found (in book-number order) is taken: at most one book in
    /// a real merge group has ever lacked a cover to begin with, so choosing
    /// among several is a case this rule has not needed to resolve yet.
    private static func chooseCover(
        survivor: LibraryEntry, absorbed: [LibraryEntry], library: Library, hasCover: @Sendable (URL) -> Bool
    ) -> UUID? {
        let survivorFolder = library.root.appendingPathComponent(survivor.folder, isDirectory: true)
        guard !hasCover(survivorFolder) else { return nil }
        for entry in absorbed.sorted(by: { $0.number < $1.number }) {
            let folder = library.root.appendingPathComponent(entry.folder, isDirectory: true)
            if hasCover(folder) { return entry.id }
        }
        return nil
    }
}
