import Foundation

/// A file format a book can be held in.
///
/// Reference data, not `if` chains: one row per format, and everything the app
/// wants to know about it – the extension, whether Shelf can read metadata from
/// it, which devices take it – reads off that row. Adding KFX later is a row.
public enum BookFileFormat: String, CaseIterable, Sendable, Codable, Comparable {
    case epub
    case azw3
    case mobi
    case pdf
    case cbz
    case cbr
    /// Amazon's newer container. Listed on purpose: Shelf can name the file and
    /// its size and nothing more, and saying so is better than pretending the
    /// book is broken (CONCEPT §6).
    case kfx
    /// Kobo's EPUB variant. Read like an EPUB; written only to a Kobo.
    case kepub

    public var fileExtension: String { rawValue }

    /// How the format is written where a person reads it: "EPUB", never "epub".
    ///
    /// Here rather than at each call site, because it was at each call site and
    /// they disagreed: the inspector uppercased the raw value and the sidebar's
    /// Formats section printed it as it comes out of SQLite, so one window said
    /// "epub" on the left and "EPUB" on the right. The same class of defect as
    /// the two number formats Sprint 2a found — small, and exactly the kind of
    /// thing that makes an app look unfinished.
    public var label: String { rawValue.uppercased() }

    /// Whether `ShelfCore` can read metadata out of the file itself.
    /// Everything else falls back to the file name.
    public var hasReadableMetadata: Bool {
        switch self {
        case .epub, .kepub: return true
        // Sprint 4 adds these; today they import by file name.
        case .azw3, .mobi, .pdf, .cbz, .cbr: return false
        case .kfx: return false
        }
    }

    /// Whether Shelf can pull a cover out of the file in Sprint 1.
    public var hasReadableCover: Bool {
        switch self {
        case .epub, .kepub: return true
        case .azw3, .mobi, .pdf, .cbz, .cbr, .kfx: return false
        }
    }

    /// Which format wins when a book has several and one has to be picked –
    /// for the inspector's preview, and later for a device that takes more than
    /// one. EPUB first because it is the one format everything reads.
    public var preferenceRank: Int {
        switch self {
        case .epub: return 0
        case .kepub: return 1
        case .azw3: return 2
        case .mobi: return 3
        case .pdf: return 4
        case .cbz: return 5
        case .cbr: return 6
        case .kfx: return 7
        }
    }

    public static func < (lhs: BookFileFormat, rhs: BookFileFormat) -> Bool {
        lhs.preferenceRank < rhs.preferenceRank
    }

    /// The format of a file name, or nil for anything that is not a book.
    /// Case-insensitive: cards and downloads write `.EPUB` as happily as `.epub`.
    public static func from(fileExtension ext: String) -> BookFileFormat? {
        BookFileFormat(rawValue: ext.lowercased())
    }

    public static func of(_ url: URL) -> BookFileFormat? {
        from(fileExtension: url.pathExtension)
    }

    /// The formats a v1.0 import accepts (CONCEPT §4, Must).
    public static let importable: [BookFileFormat] = [.epub, .kepub, .azw3, .mobi, .pdf, .cbz, .cbr]
}

/// One file of one book, as the index knows it.
///
/// The SHA-256 is what makes a file identifiable across libraries and devices
/// (CONCEPT §5.3). It is computed once, at import, and stored – re-hashing
/// 8 000 books on every launch would make opening a library a minute-long job.
/// The file's size and modification date are stored next to it so a file that
/// changed on disk can be noticed without reading it.
public struct BookFormat: Identifiable, Equatable, Hashable, Sendable, Codable {
    public var id: String { "\(bookID.uuidString)/\(fileName)" }

    public var bookID: UUID
    public var format: BookFileFormat
    /// Name inside the book's folder. The folder is known from the book, so a
    /// moved library still finds its files.
    public var fileName: String
    public var byteSize: Int64
    public var sha256: String
    public var modifiedAt: Date
    /// DRM found in the file. Shelf shows it as a badge and otherwise leaves
    /// the file alone – it is never removed, never worked around (CONCEPT §12).
    public var drm: DRMKind?

    public init(
        bookID: UUID,
        format: BookFileFormat,
        fileName: String,
        byteSize: Int64,
        sha256: String,
        modifiedAt: Date = Date(),
        drm: DRMKind? = nil
    ) {
        self.bookID = bookID
        self.format = format
        self.fileName = fileName
        self.byteSize = byteSize
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
        self.drm = drm
    }
}

/// The kinds of copy protection Shelf can recognise.
///
/// Recognising is the whole of it: a protected file is shown, badged, and
/// otherwise untouched. Detection exists so the user is told why a book has no
/// metadata, not as a step towards anything else.
public enum DRMKind: String, Sendable, Codable, CaseIterable {
    /// `META-INF/encryption.xml` in an EPUB – Adobe ADEPT and its relatives.
    case adobeADEPT
    /// Kindle's, announced by EXTH record 209.
    case kindle
    /// Encrypted, but by something this app does not recognise.
    case unknown

    public var label: String {
        switch self {
        case .adobeADEPT: return "Adobe DRM"
        case .kindle: return "Kindle DRM"
        case .unknown: return "DRM"
        }
    }
}
