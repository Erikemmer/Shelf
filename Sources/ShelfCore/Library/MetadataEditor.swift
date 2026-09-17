import Foundation

/// One metadata change, as the pair a change really is: what the book was, and
/// what it becomes.
///
/// Undo is the reason for the shape. Selector's rule, and the one Sprint 2
/// follows: register the *previous value* with the window's `UndoManager` at
/// the moment of the change, before anything is written. A change that only
/// knows its new value cannot be undone without asking the disk what the old
/// one was, and by then the disk has the new one.
///
/// `fields` is what actually differs, which is both the guard against writing a
/// file for nothing and the name the Edit menu shows ("Undo Rating").
public struct MetadataChange: Equatable, Sendable {
    public var before: Book
    public var after: Book

    public init(before: Book, after: Book) {
        self.before = before
        self.after = after
    }

    /// Builds a change and stamps the modification date.
    ///
    /// The stamp is cut to whole seconds because that is the precision
    /// `dc:date` and `dcterms:modified` have. A `Date` with a fractional part
    /// would come back from the file slightly different, and "undo restores
    /// exactly the previous state" would be false by a few microseconds – true
    /// enough to pass a careless test and false enough to make a round trip
    /// through the folder disagree with the index.
    public static func make(
        from book: Book, at now: Date = Date(), _ edit: (inout Book) -> Void
    ) -> MetadataChange {
        var after = book
        edit(&after)
        after.modifiedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return MetadataChange(before: book, after: after)
    }

    /// The same change the other way round. Applying this after the change
    /// gives back `before` whole, timestamps included – it is the *value* that
    /// is restored, not a re-derivation of it.
    public var inverse: MetadataChange {
        MetadataChange(before: after, after: before)
    }

    /// What differs, in the fixed order of `Field.allCases` so two equal
    /// changes describe themselves the same way.
    public var fields: [Field] {
        Field.allCases.filter { $0.differs(before, after) }
    }

    /// A change that changes nothing is not written. Without this, clicking the
    /// third star on a book already rated three rewrites its `metadata.opf` and
    /// puts an entry on the undo stack that does nothing.
    public var isEmpty: Bool { fields.isEmpty }

    /// What the Edit menu says after "Undo". One field is named; more than one
    /// is "Metadata", because "Undo Title, Authors and Tags" is not a menu item.
    public var actionName: String {
        let changed = fields
        guard let only = changed.first, changed.count == 1 else { return "Metadata" }
        return only.label
    }

    /// The fields a person can edit. Reference data rather than an `if` chain:
    /// adding a field to the editor is a case here and nothing else, and both
    /// "what changed" and "copy what changed" read from the same list.
    ///
    /// `addedAt` and `modifiedAt` are deliberately absent. They are not edited;
    /// they are consequences, and counting them as differences would make every
    /// change non-empty.
    public enum Field: String, CaseIterable, Sendable {
        case title, titleSort, authors, series, rating, isRead
        case publisher, published, language, description, tags, identifiers

        public var label: String {
            switch self {
            case .title: return "Title"
            case .titleSort: return "Title Sort"
            case .authors: return "Authors"
            case .series: return "Series"
            case .rating: return "Rating"
            case .isRead: return "Read Status"
            case .publisher: return "Publisher"
            case .published: return "Publication Date"
            case .language: return "Language"
            case .description: return "Description"
            case .tags: return "Tags"
            case .identifiers: return "Identifiers"
            }
        }

        public func differs(_ one: Book, _ other: Book) -> Bool {
            switch self {
            case .title: return one.title != other.title
            case .titleSort: return one.titleSort != other.titleSort
            case .authors: return one.authors != other.authors
            case .series: return one.series != other.series
            case .rating: return one.rating != other.rating
            case .isRead: return one.isRead != other.isRead
            case .publisher: return one.publisher != other.publisher
            case .published: return one.published != other.published
            case .language: return one.language != other.language
            case .description: return one.description != other.description
            case .tags: return one.tags != other.tags
            case .identifiers: return one.identifiers != other.identifiers
            }
        }

        public func copy(from source: Book, into target: inout Book) {
            switch self {
            case .title: target.title = source.title
            case .titleSort: target.titleSort = source.titleSort
            case .authors: target.authors = source.authors
            case .series: target.series = source.series
            case .rating: target.rating = source.rating
            case .isRead: target.isRead = source.isRead
            case .publisher: target.publisher = source.publisher
            case .published: target.published = source.published
            case .language: target.language = source.language
            case .description: target.description = source.description
            case .tags: target.tags = source.tags
            case .identifiers: target.identifiers = source.identifiers
            }
        }
    }
}

/// Applies a metadata change to the folder and then to the index, in that order.
///
/// That order is the whole point. The folder is the truth and the index is a
/// cache (ADR 0001), so the file is written first and the index follows; if the
/// write fails, nothing was cached that the folder does not say.
///
/// **It never touches a book file.** It writes exactly one file, the
/// `metadata.opf` beside the book, and it writes it atomically (CONCEPT §4,
/// "Won't": a book file is never written, deleted or overwritten in v1.0).
///
/// The delta is applied *onto what the file already says*, not onto what the
/// index believes. The index does not hold Calibre's custom columns, and until
/// this sprint it did not read identifiers back either: writing the index's
/// idea of a book over the file would quietly drop an imported library's own
/// columns and its ISBNs. Only the fields that actually changed are copied
/// across; everything else stays exactly as the folder has it.
public struct MetadataEditor: Sendable {
    /// The library root. Book folders are relative to it, as `LibraryEntry`
    /// keeps them.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public init(library: Library) {
        self.root = library.root
    }

    /// Writes the change and updates the index. Returns the entry as it now is.
    @discardableResult
    public func apply(
        _ change: MetadataChange, to entry: LibraryEntry, in index: LibraryIndex
    ) async throws -> LibraryEntry {
        let merged = merged(change, in: entry.folder)
        try OPFDocument.write(
            merged.book, to: folderURL(entry.folder),
            shelfPaths: merged.shelfPaths, unmappedMetas: merged.unmappedMetas)

        var updated = entry
        updated.book = merged.book
        // `shelfIDs: []` on purpose: an empty list leaves `book_shelves` alone,
        // so editing a rating does not take a book off its shelves.
        try await index.save(updated)
        return updated
    }

    /// The OPF text a change produces, without writing anything – what the
    /// proof run diffs and what a test can read.
    public func opfText(for change: MetadataChange, in folder: String) -> String {
        let merged = merged(change, in: folder)
        return OPFDocument.render(
            merged.book, shelfPaths: merged.shelfPaths, unmappedMetas: merged.unmappedMetas)
    }

    /// The book as it will be written: what the file says, with the changed
    /// fields laid over it.
    private func merged(
        _ change: MetadataChange, in folder: String
    ) -> (book: Book, shelfPaths: [String], unmappedMetas: [String: String]) {
        let url = folderURL(folder).appendingPathComponent(OPFDocument.fileName)
        guard let data = try? Data(contentsOf: url),
            let parsed = try? OPFDocument.read(data, fallbackTitle: change.after.title),
            // A file holding a different book is not this book's file. Merging
            // it would mix two books' identifiers; the change is written on its
            // own instead, and the folder gets a file that says what it is.
            parsed.book.id == change.after.id
        else {
            return (change.after, [], [:])
        }

        var book = parsed.book
        for field in change.fields { field.copy(from: change.after, into: &book) }
        book.modifiedAt = change.after.modifiedAt
        return (book, parsed.shelfPaths, parsed.unmappedMetas)
    }

    private func folderURL(_ folder: String) -> URL {
        root.appendingPathComponent(folder, isDirectory: true)
    }
}
