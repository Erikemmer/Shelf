import Foundation

/// One book in the library: the metadata, not the files.
///
/// A value type on purpose – every rule that can be wrong about a book (its
/// folder name, whether it duplicates another, what its OPF should say) is a
/// pure function over this, testable without a disk. The files belong to it
/// through `BookFormat`.
///
/// The identity is a UUID, taken over from Calibre when there is one and minted
/// otherwise (CONCEPT §5.3). It is stored in `metadata.opf` as
/// `dc:identifier opf:scheme="uuid"`, so the folder alone is enough to rebuild
/// the index.
public struct Book: Identifiable, Equatable, Hashable, Sendable, Codable {
    public var id: UUID
    public var title: String
    /// How the title sorts: "Hobbit, The" for "The Hobbit". Calibre keeps the
    /// same field, and a library imported from it must sort the way it did.
    public var titleSort: String
    /// In the order they are printed on the cover. The first one decides the
    /// author folder, which is why the order is data and not a set.
    public var authors: [String]
    public var series: SeriesRef?
    /// 0 = unrated. Calibre stores 0…10 (half stars); Shelf shows five stars
    /// and keeps the finer value so a round trip loses nothing.
    public var rating: Int
    public var isRead: Bool
    public var publisher: String?
    public var published: Date?
    /// BCP 47 where the file says so, otherwise whatever it said. Not validated
    /// on the way in: a library full of "eng" must not become a library of
    /// errors.
    public var language: String?
    public var description: String?
    /// Keywords, sorted by name and treated as a set.
    ///
    /// Sorted because everything else that holds them is: the OPF writes one
    /// `dc:subject` per tag in sorted order, and the index reads them back
    /// `ORDER BY t.name`. If the model kept a third order, the same book read
    /// from its folder and read from the index would differ in a field nobody
    /// had touched, and a rebuild would report changes that are not changes.
    /// Unlike `authors`, the order carries no information — no tag is "first".
    public var tags: [String]
    /// The shelves the book stands on, as stored paths: `Fiction/Sci-Fi`.
    ///
    /// **In the book, not beside it.** A shelf is the one thing a library knows
    /// that a book file does not, so Shelf mirrors it into each book's
    /// `metadata.opf` as `shelf:shelves` — which makes it, like everything else
    /// here, something a rebuild reads back off the disk (ADR 0001, ADR 0008).
    /// Keeping it in `Book` rather than as a value carried alongside is what
    /// gives shelf membership the same undo, the same "write the file, then the
    /// index", and the same multiple-selection editing as every other field,
    /// instead of a second mechanism that has to be kept in step with the first.
    ///
    /// The *paths* are here and the *tree* is in `library.json`: a book knows
    /// which shelves it is on, the library knows what the shelves are and in
    /// what order. An empty shelf therefore survives in `library.json` with no
    /// book to remember it.
    ///
    /// Sorted, and for the same reason `tags` is: the OPF, the index and the
    /// model must agree on one order or a round trip reports a change nobody
    /// made.
    public var shelves: [String]
    /// ISBN, ASIN, DOI, Google, Goodreads… keyed by scheme, lower-cased.
    public var identifiers: [String: String]
    /// Calibre's own columns, by label without the `#`, already rendered as the
    /// text the inspector shows: `["read_date": "2023-10-01T00:00:00+00:00"]`.
    ///
    /// **Read-only in v1.0** (CONCEPT §4, "Should"). Shelf takes them over on
    /// import, carries them through every edit and writes them back, and offers
    /// no way to change them — a field Shelf cannot validate is a field Shelf
    /// should not let anybody type into.
    ///
    /// In the book, for the same reason the shelves are (ADR 0008): the folder
    /// is the truth, so anything the folders cannot hold is mirrored into each
    /// book's `metadata.opf` and comes back from a rebuild. *What the columns
    /// are* — their names and their kinds — belongs to the library and lives
    /// in `library.json`, exactly as the shelf tree does (ADR 0010).
    public var customValues: [String: String]
    /// How many times this book's cover has been replaced.
    ///
    /// **Not a fact about the picture — a fact about the cache key.** The cover
    /// cache is keyed by UUID, size and generation (ADR 0005, decision 4),
    /// because a cover belongs to the *book* and outlives any one of its files:
    /// a path and a modification date, which is what Selector keys on, would
    /// name the wrong thing here. The generation is what that decision left for
    /// a replaced cover to move, and until Sprint 9 nothing moved it, because
    /// until Sprint 9 a cover could not be replaced.
    ///
    /// In the book, so it is in `metadata.opf`, for the reason the shelves are
    /// (ADR 0008) and Calibre's columns are (ADR 0010): the folder is the truth
    /// and the index is a cache (ADR 0001). A number the index alone remembered
    /// would be forgotten by `Library ▸ Rebuild Index from Folders`, and the
    /// grid would go straight back to a thumbnail of the picture the person
    /// had just replaced — which is the failure this field exists to prevent.
    ///
    /// Zero for every book that has never had its cover changed, which is every
    /// book in every library imported before this sprint.
    public var coverGeneration: Int

    /// When Shelf first saw the book. Calibre's `timestamp` on import.
    public var addedAt: Date
    /// Last time any metadata field changed. Drives "Recently Added"'s sibling
    /// column in the table and the OPF's `dcterms:modified`.
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        titleSort: String? = nil,
        authors: [String] = [],
        series: SeriesRef? = nil,
        rating: Int = 0,
        isRead: Bool = false,
        publisher: String? = nil,
        published: Date? = nil,
        language: String? = nil,
        description: String? = nil,
        tags: [String] = [],
        shelves: [String] = [],
        identifiers: [String: String] = [:],
        customValues: [String: String] = [:],
        coverGeneration: Int = 0,
        addedAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.titleSort = titleSort ?? TitleSort.of(title)
        self.authors = authors
        self.series = series
        self.rating = rating
        self.isRead = isRead
        self.publisher = publisher
        self.published = published
        self.language = language
        self.description = description
        self.tags = tags.sorted()
        self.shelves = shelves.sorted()
        self.identifiers = identifiers
        self.customValues = customValues
        self.coverGeneration = coverGeneration
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
    }

    /// The author shown in one line: "Jane Austen" or "Gaiman & Pratchett".
    /// Three or more become "Gaiman et al.", because a grid caption has room
    /// for one line and a list of six names tells the reader nothing.
    ///
    /// A book with no author shows **nothing**, not a placeholder. A caption
    /// reading "Unknown" is a word the library did not contain: it looks like
    /// an author called Unknown, it sorts among the authors, and it says
    /// nothing a blank line does not already say. Where a name is *required* —
    /// a folder on disk, a file name on a device — `unknownAuthor` still
    /// supplies one, because a path cannot be blank.
    public var authorLine: String {
        switch authors.count {
        case 0: return ""
        case 1: return authors[0]
        case 2: return "\(authors[0]) & \(authors[1])"
        default: return "\(authors[0]) et al."
        }
    }

    /// The author whose folder the book lives in. Calibre uses the first one
    /// too, which is what keeps an imported library's paths unchanged.
    public var primaryAuthor: String { authors.first ?? Self.unknownAuthor }

    /// What an author-less book is **filed** under — a folder name, a device
    /// file name, a duplicate key. Never something the window shows: see
    /// `authorLine`. Calibre's own word, so a folder tree stays compatible in
    /// both directions.
    public static let unknownAuthor = "Unknown"

    /// The rating as the five stars the inspector shows and the keys 1–5 set.
    ///
    /// `rating` itself is Calibre's scale, 0…10, because that is what
    /// `calibre:rating` holds and a library that goes back to Calibre must not
    /// lose half stars somebody set there. Five stars are 10, so the conversion
    /// is ×2 one way and ÷2 rounded up the other: a book Calibre rated 7 shows
    /// four stars rather than three and a half, and setting four stars writes 8.
    ///
    /// Both directions live here so no view can invent a third answer – the
    /// inspector handed `rating` straight to a five-star control in Sprint 1,
    /// which drew five full stars for everything rated 5 or more.
    public var stars: Int {
        get { (rating + 1) / 2 }
        set { rating = max(0, min(5, newValue)) * 2 }
    }

    /// ISBN in whatever form the file gave it, digits and X only, upper-cased.
    /// The importer compares these, so normalising here is what makes two
    /// spellings of one ISBN the same book.
    public var isbn: String? {
        guard let raw = identifiers["isbn"] else { return nil }
        let cleaned = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Which series a book belongs to, and where in it.
///
/// The index is a `Double` because Calibre's is: half numbers are how readers
/// name novellas ("Mistborn 3.5"), and rounding them away would lose the order
/// of the very books the field exists to order.
public struct SeriesRef: Equatable, Hashable, Sendable, Codable {
    public var name: String
    public var index: Double?

    public init(name: String, index: Double? = nil) {
        self.name = name
        self.index = index
    }

    /// "Mistborn #3" / "Mistborn #3.5" / "Mistborn" – the index without a
    /// trailing ".0", because nobody writes the third book as 3.0.
    public var display: String {
        guard let index else { return name }
        let rounded = index.rounded()
        let number =
            abs(index - rounded) < 0.001
            ? String(Int(rounded))
            : String(format: "%g", index)
        return "\(name) #\(number)"
    }
}

/// How a title sorts.
///
/// A rule, not a table: the leading article moves to the end, the way Calibre
/// and every library catalogue do it. Kept in the core and tested, because a
/// library that sorts "The Hobbit" under T is a library nobody can find
/// anything in.
public enum TitleSort {
    /// Articles worth moving, per language. English, German, French, Spanish,
    /// Italian and Dutch – the languages a European eBook library actually
    /// holds. Reference data, so adding a language is a row, not a branch.
    public static let articles: [String] = [
        "the", "a", "an",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "le", "la", "les", "un", "une", "des",
        "el", "los", "las", "unos", "unas",
        "il", "lo", "gli", "uno",
        "de", "het", "een",
    ]

    public static func of(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(of: " ") else { return trimmed }
        let first = String(trimmed[trimmed.startIndex..<space]).lowercased()
        guard articles.contains(first) else { return trimmed }
        let rest = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        // "The" on its own is the whole title; moving it would leave nothing.
        guard !rest.isEmpty else { return trimmed }
        return "\(rest), \(trimmed[trimmed.startIndex..<space])"
    }
}

/// How an author's name sorts and how their folder is named.
///
/// Calibre files authors as "Austen, Jane"; the display form stays "Jane
/// Austen". One place for the rule, because the folder name and the sidebar
/// have to agree or the same author appears twice.
public enum AuthorSort {
    /// Suffixes that are part of the name, not the surname: "Martin Luther
    /// King Jr." sorts under King, not under Jr.
    public static let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv", "phd", "ph.d."]

    public static func of(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name that already has a comma in it is already in sort form, and
        // sorting it again is how "Albrecht, Nora" became "Nora, Albrecht,".
        // Real EPUBs write `dc:creator` both ways – found in a shop download,
        // and in a large share of any real library.
        guard !trimmed.contains(",") else {
            return trimmed.split(separator: " ").filter { !$0.isEmpty }.joined(separator: " ")
        }

        let parts = trimmed.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard parts.count > 1 else { return trimmed }

        var words = parts
        var suffix: String?
        if let last = words.last, suffixes.contains(last.lowercased()) {
            suffix = words.removeLast()
        }
        guard words.count > 1, let surname = words.popLast() else { return trimmed }

        let given = words.joined(separator: " ")
        let tail = suffix.map { "\(given) \($0)" } ?? given
        return "\(surname), \(tail)"
    }
}
