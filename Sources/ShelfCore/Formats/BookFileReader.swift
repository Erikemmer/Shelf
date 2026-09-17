import Foundation

/// The one place that decides which reader a file gets.
///
/// Before Sprint 4 the choice was a single `if format.hasReadableMetadata` in
/// `ImportModel`, with EPUB on one side of it and everything else on the other.
/// With five formats and two layers it has to be a table, and it has to be in
/// the core — the *decision* is a rule, even where the reading is not.
///
/// What this type reads is what `BookFileFormat.readerLayer` calls `.core`:
/// EPUB, KEPUB, MOBI, AZW3 and CBZ. PDF and CBR need Apple's frameworks and are
/// read in the app layer, which calls this for everything else and fills those
/// two in itself (`BookFileFormat.readerLayer == .app`). A caller that has no
/// app layer — the command-line tool, the Linux tests — gets the file name for
/// those two and a warning saying so, rather than nothing.
public enum BookFileReader {

    /// What reading one file turned out to give, whichever reader gave it.
    ///
    /// One shape for all of them, so the importer has one code path rather than
    /// five. `EPUBMetadata.Result`, `MobiMetadata.Result` and
    /// `ComicMetadata.Result` all collapse into this.
    public struct Result: Equatable, Sendable {
        public var book: Book
        public var cover: Data?
        public var coverName: String?
        public var drm: DRMKind?
        public var warnings: [String]
        /// Whether the metadata came out of the file or off its name. The
        /// import report says which, because "the file says so" and "Shelf
        /// guessed from the name" are very different claims about a title.
        public var fromTheFile: Bool

        public init(
            book: Book, cover: Data? = nil, coverName: String? = nil, drm: DRMKind? = nil,
            warnings: [String] = [], fromTheFile: Bool = false
        ) {
            self.book = book
            self.cover = cover
            self.coverName = coverName
            self.drm = drm
            self.warnings = warnings
            self.fromTheFile = fromTheFile
        }
    }

    /// Reads a file of a format the core handles.
    ///
    /// Never throws and never refuses: a file that will not parse still becomes
    /// a book named after itself, and what went wrong is in the warnings and
    /// therefore in `Import-Report.txt`. That is the rule every reader here
    /// already follows on its own; this makes it true of the dispatch too.
    public static func read(url: URL, format: BookFileFormat, readCover: Bool = true) -> Result {
        let stem = url.deletingPathExtension().lastPathComponent

        switch format {
        case .epub, .kepub:
            guard let read = try? EPUBMetadata.read(url: url, readCover: readCover) else {
                return fromName(stem, warning: "the EPUB could not be opened – the metadata comes from the file name")
            }
            return Result(
                book: read.book, cover: read.cover, coverName: read.coverName, drm: read.drm,
                warnings: read.warnings, fromTheFile: true)

        case .mobi, .azw3:
            guard let read = try? MobiMetadata.read(url: url, readCover: readCover) else {
                return fromName(
                    stem, warning: "the \(format.label) could not be opened – the metadata comes from the file name")
            }
            return Result(
                book: read.book, cover: read.cover, coverName: read.coverName, drm: read.drm,
                warnings: read.warnings, fromTheFile: true)

        case .cbz:
            guard let read = try? ComicMetadata.read(url: url, readCover: readCover) else {
                return fromName(stem, warning: "the CBZ could not be opened – the metadata comes from the file name")
            }
            return Result(
                book: read.book, cover: read.cover, coverName: read.coverName,
                warnings: read.warnings, fromTheFile: read.hadComicInfo)

        case .pdf, .cbr:
            // Not this layer's file. The app layer answers these; a caller
            // without one gets the name and is told why, rather than being left
            // to wonder.
            return fromName(
                stem,
                warning:
                    "\(format.label) is read by the app, not by the core – this run has the file name only")

        case .kfx:
            return fromName(stem, warning: format.unreadableNote ?? "Shelf cannot read this format")
        }
    }

    /// The fallback every reader shares: the file name, and a warning saying so.
    public static func fromName(_ stem: String, warning: String) -> Result {
        Result(
            book: Book(
                title: FileNameMetadata.title(from: stem),
                authors: FileNameMetadata.authors(from: stem)),
            warnings: [warning],
            fromTheFile: false)
    }
}
