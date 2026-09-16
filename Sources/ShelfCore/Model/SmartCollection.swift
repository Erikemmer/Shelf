import Foundation

/// A view of the library that is a rule, not a list.
///
/// The sidebar's top section. Rules rather than stored lists, so they are
/// always right: a book that is marked read leaves "Unread" the moment it is
/// marked, with nothing to keep in step.
///
/// `Duplicates` and `Missing cover` are in here deliberately, next to the
/// pleasant ones: an app that hides what is wrong with a library is an app that
/// lets it rot.
public enum SmartCollection: Equatable, Hashable, Sendable, CaseIterable {
    case all
    case unread
    case recentlyAdded
    case notOnAnyShelf
    case missingCover
    case duplicates

    /// The order they appear in the sidebar. `allCases` gives this order, and
    /// the sidebar reads it rather than listing them again.
    public static let allCases: [SmartCollection] = [
        .all, .unread, .recentlyAdded, .notOnAnyShelf, .missingCover, .duplicates,
    ]

    /// What Sprint 1 can actually show. The other two need the index questions
    /// Sprint 2 adds; they are drawn, disabled, rather than hidden – a menu
    /// that grows between versions is harder to learn than one that is whole
    /// and partly greyed.
    public static let availableInSprintOne: Set<SmartCollection> = [.all, .unread, .recentlyAdded, .missingCover]

    public var title: String {
        switch self {
        case .all: return "All Books"
        case .unread: return "Unread"
        case .recentlyAdded: return "Recently Added"
        case .notOnAnyShelf: return "Not on any Shelf"
        case .missingCover: return "Missing Cover"
        case .duplicates: return "Duplicates"
        }
    }

    /// SF Symbol name.
    public var icon: String {
        switch self {
        case .all: return "books.vertical"
        case .unread: return "book.closed"
        case .recentlyAdded: return "clock"
        case .notOnAnyShelf: return "tray"
        case .missingCover: return "photo.badge.exclamationmark"
        case .duplicates: return "doc.on.doc"
        }
    }

    /// How many days back "recently added" reaches.
    public static let recentDays = 30

    /// Whether one book belongs in this collection.
    ///
    /// A pure function over what the app already knows, so the same rule runs
    /// in the sidebar count and in the grid filter. `coversOnDisk` is passed in
    /// because whether a cover file exists is a fact about the disk, and a
    /// column holding it would be a second copy that can go stale.
    public func contains(
        _ entry: LibraryEntry,
        coversOnDisk: Set<UUID> = [],
        shelvedBooks: Set<UUID> = [],
        duplicateBooks: Set<UUID> = [],
        now: Date = Date()
    ) -> Bool {
        switch self {
        case .all:
            return true
        case .unread:
            return !entry.book.isRead
        case .recentlyAdded:
            return entry.book.addedAt >= now.addingTimeInterval(-Double(Self.recentDays) * 86_400)
        case .notOnAnyShelf:
            return !shelvedBooks.contains(entry.id)
        case .missingCover:
            return !coversOnDisk.contains(entry.id)
        case .duplicates:
            return duplicateBooks.contains(entry.id)
        }
    }
}

/// What the grid is showing: one collection, plus whatever the sidebar and the
/// search field narrow it down to.
///
/// A value type so the whole state of "what am I looking at" is one thing that
/// can be compared, stored and restored – and so the window's title and the
/// status bar cannot describe two different filters.
public struct LibraryFilter: Equatable, Sendable {
    public var collection: SmartCollection
    public var shelfID: UUID?
    public var tag: String?
    public var author: String?
    public var series: String?
    public var format: BookFileFormat?
    public var searchText: String

    public init(
        collection: SmartCollection = .all,
        shelfID: UUID? = nil,
        tag: String? = nil,
        author: String? = nil,
        series: String? = nil,
        format: BookFileFormat? = nil,
        searchText: String = ""
    ) {
        self.collection = collection
        self.shelfID = shelfID
        self.tag = tag
        self.author = author
        self.series = series
        self.format = format
        self.searchText = searchText
    }

    public static let everything = LibraryFilter()

    /// Whether anything beyond the collection is narrowing the view – what the
    /// status bar uses to decide between "8 412 books" and "312 of 8 412".
    public var isNarrowed: Bool {
        shelfID != nil || tag != nil || author != nil || series != nil || format != nil
            || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the window shows as its subject: "Science Fiction", "Jane Austen",
    /// or the collection's own name.
    public var title: String {
        tag ?? author ?? series ?? format?.rawValue.uppercased() ?? collection.title
    }

    /// Applies everything except the search text, which the index answers.
    ///
    /// Kept out of SQL on purpose: the sidebar's facets are one word each and
    /// filtering 8 000 loaded entries in memory takes well under a millisecond,
    /// where a query per click would be a round trip and a new sort order.
    public func matches(
        _ entry: LibraryEntry,
        coversOnDisk: Set<UUID> = [],
        shelvedBooks: Set<UUID> = [],
        booksOnShelf: Set<UUID> = [],
        duplicateBooks: Set<UUID> = [],
        now: Date = Date()
    ) -> Bool {
        guard
            collection.contains(
                entry, coversOnDisk: coversOnDisk, shelvedBooks: shelvedBooks,
                duplicateBooks: duplicateBooks, now: now)
        else { return false }
        if shelfID != nil, !booksOnShelf.contains(entry.id) { return false }
        if let tag, !entry.book.tags.contains(tag) { return false }
        if let author, !entry.book.authors.contains(author) { return false }
        if let series, entry.book.series?.name != series { return false }
        if let format, !entry.formats.contains(where: { $0.format == format }) { return false }
        return true
    }
}
