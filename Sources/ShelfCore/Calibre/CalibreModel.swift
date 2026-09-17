import Foundation

/// What a Calibre library says about itself, and what Shelf makes of it.
///
/// These are values, not queries: `CalibreReader` reads the database once and
/// hands back this, so the counting protocol, the plan and the import all work
/// from the same reading rather than asking the database three times and
/// possibly getting three answers.

/// One of Calibre's own columns, as its `custom_columns` table describes it.
public struct CalibreCustomColumn: Equatable, Sendable {
    /// Calibre's row id. It is what the `custom_column_<id>` tables are named
    /// after, so it is carried rather than discarded.
    public var number: Int
    /// Calibre's label without the `#`: `read_date`. Unique in a library.
    public var label: String
    /// What the user called it: "Date read".
    public var name: String
    public var kind: Kind
    /// A column that holds several values per book (Calibre's tag-like
    /// columns). They come back joined by ", ".
    public var isMultiple: Bool
    /// Whether the values live in their own table with a link table
    /// (`normalized`) or directly in `custom_column_<id>`. Calibre decides this
    /// per datatype and Shelf has to read both shapes.
    public var isNormalized: Bool

    /// Calibre's `datatype`, spelled as Calibre spells it.
    ///
    /// A `String` behind a known set rather than a bare enum, because a Calibre
    /// version may add one and an unknown datatype is a line in the report, not
    /// a failed import (CONCEPT §13).
    public enum Kind: String, Sendable, CaseIterable {
        case text
        case comments
        case series
        case datetime
        case float
        case int
        case bool
        case rating
        case enumeration
        /// Computed by Calibre from a template; there is no stored value to
        /// read, so there is nothing to import.
        case composite

        /// The four the inspector draws in v1.0 (CONCEPT §4, "Should":
        /// "Text, Ja/Nein, Datum, Zahl").
        public var isShown: Bool {
            switch self {
            case .text, .comments, .enumeration, .series: return true
            case .bool: return true
            case .datetime: return true
            case .int, .float, .rating: return true
            case .composite: return false
            }
        }

        /// How the inspector labels the kind, in one word.
        public var label: String {
            switch self {
            case .text, .comments, .enumeration, .series: return "Text"
            case .bool: return "Yes/No"
            case .datetime: return "Date"
            case .int, .float, .rating: return "Number"
            case .composite: return "Computed"
            }
        }
    }

    public init(
        number: Int, label: String, name: String, kind: Kind, isMultiple: Bool = false,
        isNormalized: Bool = false
    ) {
        self.number = number
        self.label = label
        self.name = name
        self.kind = kind
        self.isMultiple = isMultiple
        self.isNormalized = isNormalized
    }

    /// How Calibre writes it, and how the OPF stores it: `#read_date`.
    public var hashLabel: String { "#" + label }
}

/// A datatype Calibre knows and this version of Shelf does not.
///
/// Its own type because it is *reported*, never thrown: a library with one
/// exotic column must still import the other 7 999 books (CONCEPT §13).
public struct CalibreUnknownColumn: Equatable, Sendable {
    public var label: String
    public var name: String
    public var datatype: String

    public init(label: String, name: String, datatype: String) {
        self.label = label
        self.name = name
        self.datatype = datatype
    }
}

/// One file Calibre lists for a book, from its `data` table.
public struct CalibreFile: Equatable, Sendable {
    /// `data.name` – the file's name without its extension.
    public var name: String
    /// `data.format`, as Calibre stores it: `EPUB`, `AZW3`, `PDF`.
    public var calibreFormat: String
    /// `data.uncompressed_size`. What the database *believes*; the file on disk
    /// is measured separately and a difference is worth reporting.
    public var claimedSize: Int64
    /// Relative to the Calibre library folder: `Austen, Jane/Emma (3)/Emma.epub`.
    public var relativePath: String

    public init(name: String, calibreFormat: String, claimedSize: Int64, relativePath: String) {
        self.name = name
        self.calibreFormat = calibreFormat
        self.claimedSize = claimedSize
        self.relativePath = relativePath
    }

    /// The Shelf format, or `nil` for one Shelf does not import.
    public var format: BookFileFormat? {
        BookFileFormat(rawValue: calibreFormat.lowercased())
    }
}

/// One book, as Calibre has it and as Shelf will hold it.
public struct CalibreBook: Equatable, Sendable {
    /// Calibre's `books.id`. Not Shelf's identity – it is the number in the
    /// folder name and the key the link tables use.
    public var number: Int
    /// The Shelf book, with Calibre's UUID taken over as its identity
    /// (CONCEPT §5.3). Everything Shelf models is already in here.
    public var book: Book
    /// `books.path`, relative to the Calibre library folder.
    public var folder: String
    public var files: [CalibreFile]
    /// `books.has_cover`. Whether `cover.jpg` is actually there is a question
    /// for the file system, and the census asks it.
    public var claimsCover: Bool
    /// Custom column values by label (`read_date`), already turned into text.
    /// Read-only in v1.0.
    public var customValues: [String: String]
    /// What could not be read cleanly. Never a reason to skip the book.
    public var warnings: [String]

    public init(
        number: Int, book: Book, folder: String, files: [CalibreFile] = [],
        claimsCover: Bool = false, customValues: [String: String] = [:], warnings: [String] = []
    ) {
        self.number = number
        self.book = book
        self.folder = folder
        self.files = files
        self.claimsCover = claimsCover
        self.customValues = customValues
        self.warnings = warnings
    }
}

/// What the database says about its own version.
///
/// An unknown version is a **warning, not a refusal** (CONCEPT §13): Calibre
/// bumps `user_version` for changes that usually do not touch the tables Shelf
/// reads, and refusing would make a Calibre update break the import for
/// everybody at once.
public struct CalibreSchema: Equatable, Sendable {
    public var userVersion: Int
    /// `library_id` from Calibre's own `library_id` table, when it has one.
    public var libraryID: String?
    public var isKnown: Bool
    /// The sentence the sheet and the report show. `nil` when there is nothing
    /// to say.
    public var warning: String?

    public init(userVersion: Int, libraryID: String? = nil, isKnown: Bool, warning: String? = nil) {
        self.userVersion = userVersion
        self.libraryID = libraryID
        self.isKnown = isKnown
        self.warning = warning
    }
}

/// Everything one reading of a Calibre library produced.
public struct CalibreLibrary: Equatable, Sendable {
    /// The folder the books are in, which is also where `metadata.db` was.
    /// Only ever read.
    public var folder: URL
    public var schema: CalibreSchema
    public var books: [CalibreBook]
    public var customColumns: [CalibreCustomColumn]
    /// Columns whose datatype this Shelf does not know. Reported, not fatal.
    public var unknownColumns: [CalibreUnknownColumn]
    /// Anything odd about the database as a whole.
    public var warnings: [String]

    public init(
        folder: URL, schema: CalibreSchema, books: [CalibreBook] = [],
        customColumns: [CalibreCustomColumn] = [], unknownColumns: [CalibreUnknownColumn] = [],
        warnings: [String] = []
    ) {
        self.folder = folder
        self.schema = schema
        self.books = books
        self.customColumns = customColumns
        self.unknownColumns = unknownColumns
        self.warnings = warnings
    }
}
