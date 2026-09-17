import Foundation

/// A library folder on disk.
///
/// The folder is the truth and the index is a cache of it
/// (`docs/adr/0001-folder-is-the-truth.md`). This type owns the layout and
/// nothing else: where `.shelf/` sits, where a book's folder goes, what
/// `library.json` says. It never reads a book file and never writes one.
public struct Library: Equatable, Sendable {
    /// The library's root folder – the one the user picked.
    public let root: URL

    /// Everything Shelf keeps about the library rather than about a book.
    /// A dot folder, so a library that is also browsed in the Finder does not
    /// look like it has a stray folder in it.
    public static let privateFolderName = ".shelf"
    public static let descriptorFileName = "library.json"
    public static let indexFileName = "library.sqlite"
    public static let coversFolderName = "covers"
    public static let reportFileName = "Import-Report.txt"

    public init(root: URL) {
        self.root = root
    }

    public var privateFolder: URL { root.appendingPathComponent(Self.privateFolderName, isDirectory: true) }
    public var descriptorURL: URL { privateFolder.appendingPathComponent(Self.descriptorFileName) }
    public var indexURL: URL { privateFolder.appendingPathComponent(Self.indexFileName) }
    public var coversFolder: URL { privateFolder.appendingPathComponent(Self.coversFolderName, isDirectory: true) }
    public var reportURL: URL { privateFolder.appendingPathComponent(Self.reportFileName) }

    public var name: String { root.lastPathComponent }

    /// The folder one book lives in.
    public func folder(for book: Book, number: Int) -> URL {
        root.appendingPathComponent(BookFolderName.relativePath(for: book, number: number), isDirectory: true)
    }

    // MARK: Opening and creating

    public enum Failure: Error, Equatable {
        case notALibrary(String)
        case alreadyALibrary(String)
        case cannotCreate(String)
        case cannotWriteDescriptor(String)
        /// The descriptor is from a newer Shelf. Opening it read-write could
        /// drop fields this version does not know about, so it is refused
        /// rather than risked.
        case newerSchema(found: Int, supported: Int)
    }

    /// Whether this folder is a Shelf library.
    public static func isLibrary(_ url: URL) -> Bool {
        let candidate = Library(root: url)
        return FileManager.default.fileExists(atPath: candidate.descriptorURL.path)
    }

    /// Creates a library in an existing, ideally empty folder.
    ///
    /// Refuses a folder that already holds one: overwriting `library.json`
    /// would orphan an index and, with it, every shelf the user built by hand.
    /// Existing *books* in the folder are fine – they are picked up by a
    /// rebuild, which is the whole point of the folder being the truth.
    @discardableResult
    public static func create(at url: URL, name: String? = nil) throws -> (Library, LibraryDescriptor) {
        let library = Library(root: url)
        guard !isLibrary(url) else { throw Failure.alreadyALibrary(url.lastPathComponent) }

        do {
            try FileManager.default.createDirectory(at: library.coversFolder, withIntermediateDirectories: true)
        } catch {
            throw Failure.cannotCreate(url.lastPathComponent)
        }
        let descriptor = LibraryDescriptor(name: name ?? url.lastPathComponent)
        try library.write(descriptor)
        return (library, descriptor)
    }

    /// Opens an existing library and returns what `library.json` says.
    public static func open(_ url: URL) throws -> (Library, LibraryDescriptor) {
        let library = Library(root: url)
        guard isLibrary(url) else { throw Failure.notALibrary(url.lastPathComponent) }
        let descriptor = try library.readDescriptor()
        guard descriptor.schemaVersion <= LibraryDescriptor.currentSchemaVersion else {
            throw Failure.newerSchema(
                found: descriptor.schemaVersion, supported: LibraryDescriptor.currentSchemaVersion)
        }
        // A library restored from a backup may have lost the empty covers
        // folder; recreating it is cheaper than a failure the user cannot act on.
        try? FileManager.default.createDirectory(at: library.coversFolder, withIntermediateDirectories: true)
        return (library, descriptor)
    }

    public func readDescriptor() throws -> LibraryDescriptor {
        guard let data = try? Data(contentsOf: descriptorURL),
            let descriptor = try? LibraryDescriptor.decoder.decode(LibraryDescriptor.self, from: data)
        else { throw Failure.notALibrary(name) }
        return descriptor
    }

    /// Writes `library.json` atomically. It holds the shelves the user built by
    /// hand, so a half-written one would cost real work.
    public func write(_ descriptor: LibraryDescriptor) throws {
        do {
            try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
            let data = try LibraryDescriptor.encoder.encode(descriptor)
            try data.write(to: descriptorURL, options: .atomic)
        } catch {
            throw Failure.cannotWriteDescriptor(name)
        }
    }

    // MARK: Warnings about where the library lives

    /// Whether the library sits in a folder a sync service manages.
    ///
    /// SQLite in iCloud Drive is a known way to lose a database: the service
    /// may upload a file mid-write, and it evicts files it thinks are unused.
    /// Shelf opens such a library anyway – the folder is still the truth and
    /// the index can be rebuilt – but it says so first (CONCEPT §12).
    public var syncWarning: String? {
        let path = root.path
        let services: [(String, String)] = [
            ("/Library/Mobile Documents/", "iCloud Drive"),
            ("/Dropbox/", "Dropbox"),
            ("/OneDrive", "OneDrive"),
            ("/Google Drive", "Google Drive"),
        ]
        guard let service = services.first(where: { path.contains($0.0) })?.1 else { return nil }
        return "This library is in \(service). Shelf's index can be rebuilt, but a synced database "
            + "can be corrupted while it is being written. Keeping the library on a local disk is safer."
    }
}

/// `library.json`: what the library is, apart from its books.
///
/// Small on purpose. The books live in the folders and the index; this file
/// holds what has nowhere else to live – the name, the schema version, and the
/// shelves, which are the one thing a rebuild could not reconstruct from the
/// folders alone if the OPFs were ever lost.
public struct LibraryDescriptor: Codable, Equatable, Sendable {
    /// Raised when the on-disk layout changes in a way an older Shelf could
    /// not read. A library with a higher number is not opened (see
    /// `Library.Failure.newerSchema`).
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var createdAt: Date
    /// The next number for a book folder: `Pride and Prejudice (17)`.
    ///
    /// Stored rather than derived from the highest existing one, so a book that
    /// was deleted from the Finder cannot make the next import reuse its
    /// number and land in a folder that still has files in it.
    public var nextBookNumber: Int
    public var shelves: [Shelf]
    /// How this library was last being looked at: grid or table, in what order,
    /// with which columns.
    ///
    /// Per library rather than per app, because it is a fact about *this*
    /// collection: a library of comics wants different columns from a library
    /// of novels, and a person who sorts one by date added has not said
    /// anything about the other.
    public var view: LibraryViewSettings
    /// Calibre's custom columns as this library knows them: what each one is
    /// called and what kind it is.
    ///
    /// The *shape*, exactly as the shelves are: which columns exist belongs to
    /// the library, and which values a book has belongs to the book
    /// (`Book.customValues`, ADR 0010). An imported column with nothing in it
    /// survives here for the same reason an empty shelf does — no book can
    /// remember it.
    public var customColumns: [CalibreCustomColumn]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        name: String,
        createdAt: Date = Date(),
        nextBookNumber: Int = 1,
        shelves: [Shelf] = [],
        view: LibraryViewSettings = LibraryViewSettings(),
        customColumns: [CalibreCustomColumn] = []
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.createdAt = createdAt
        self.nextBookNumber = nextBookNumber
        self.shelves = shelves
        self.view = view
        self.customColumns = customColumns
    }

    /// Decoded by hand so that a field added later can be missing.
    ///
    /// The synthesised initialiser refuses a file without `view`, and every
    /// `library.json` written before this sprint is such a file. A new field
    /// that makes existing libraries unopenable is a migration, and this is not
    /// worth one: a missing setting means "the default", which is exactly what
    /// a library that has never been arranged should get.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        nextBookNumber = try values.decodeIfPresent(Int.self, forKey: .nextBookNumber) ?? 1
        shelves = try values.decodeIfPresent([Shelf].self, forKey: .shelves) ?? []
        view = try values.decodeIfPresent(LibraryViewSettings.self, forKey: .view) ?? LibraryViewSettings()
        customColumns = try values.decodeIfPresent([CalibreCustomColumn].self, forKey: .customColumns) ?? []
    }

    public var shelfTree: ShelfTree { ShelfTree(shelves) }

    /// Hands out the next folder number and moves the counter on.
    public mutating func takeBookNumber() -> Int {
        let number = max(1, nextBookNumber)
        nextBookNumber = number + 1
        return number
    }

    /// Pretty-printed with sorted keys and ISO-8601 dates – a file a person may
    /// well open in a text editor, and one whose diffs should mean something.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// How a library was last being looked at.
///
/// Saved in `library.json` and not in the app's preferences: it describes this
/// collection, and it should travel with the folder to another Mac the way the
/// shelves do.
public struct LibraryViewSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case grid
        case table

        public var label: String {
            switch self {
            case .grid: return "Grid"
            case .table: return "Table"
            }
        }

        public var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .table: return "list.bullet"
            }
        }
    }

    public var mode: Mode
    public var order: BookOrder
    /// The table's hidden columns and their widths, as SwiftUI's own
    /// customisation writes them. Opaque on purpose: it is SwiftUI's format,
    /// and a second interpretation of it here would be a second thing to keep
    /// in step with a framework that owns it.
    public var tableColumns: String?

    public init(mode: Mode = .grid, order: BookOrder = .byTitle, tableColumns: String? = nil) {
        self.mode = mode
        self.order = order
        self.tableColumns = tableColumns
    }
}
