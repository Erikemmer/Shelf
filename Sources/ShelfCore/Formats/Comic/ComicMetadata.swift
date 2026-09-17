import Foundation

/// Reads a comic: `ComicInfo.xml` when there is one, the file name when there
/// is not, and the first page as the cover.
///
/// A CBZ is a zip of images and nothing else, so this reader is mostly about
/// what to do when a file says nothing about itself. The order is: `ComicInfo.xml`
/// (the de-facto standard, written by ComicRack and read by everything since),
/// then the file name (`ComicFileName`), then the file name as a plain title.
///
/// **CBR is the same reader with a different way in.** A RAR is not a ZIP and
/// the core has no RAR code — unpacking one needs libarchive, which is not
/// Linux-portable in the way the core must be (ADR 0003). So the app layer
/// opens a CBR and hands the entries here; a CBR that libarchive on this Mac
/// cannot open falls back to `ComicFileName` and says so, visibly, rather than
/// failing silently (CONCEPT §13).
public enum ComicMetadata {

    public struct Result: Equatable, Sendable {
        public var book: Book
        public var cover: Data?
        public var coverName: String?
        public var warnings: [String]
        /// Whether `ComicInfo.xml` was found and read. The inspector says so,
        /// because "this is all the file knows" and "Shelf could not read it"
        /// look identical otherwise.
        public var hadComicInfo: Bool

        public init(
            book: Book, cover: Data? = nil, coverName: String? = nil, warnings: [String] = [],
            hadComicInfo: Bool = false
        ) {
            self.book = book
            self.cover = cover
            self.coverName = coverName
            self.warnings = warnings
            self.hadComicInfo = hadComicInfo
        }
    }

    public enum Failure: Error, Equatable {
        case notAComic(String)
    }

    public static let comicInfoName = "ComicInfo.xml"

    /// A CBZ on disk.
    public static func read(url: URL, readCover: Bool = true) throws -> Result {
        let archive: ZipReader
        do {
            archive = try ZipReader(url: url)
        } catch {
            throw Failure.notAComic(url.lastPathComponent)
        }
        return read(archive, fallbackName: url.deletingPathExtension().lastPathComponent, readCover: readCover)
    }

    public static func read(_ archive: ZipReader, fallbackName: String, readCover: Bool = true) -> Result {
        // The pages, in reading order. Alphabetical and not archive order:
        // pages are named in reading order and archive order is whatever the
        // writer felt like — `page10.jpg` before `page2.jpg` is wrong either
        // way, but at least alphabetical is the order the scanner intended.
        let pages = archive.files
            .filter { EPUBMetadata.imageExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        let comicInfo = archive.files.first {
            ($0.path as NSString).lastPathComponent.lowercased() == comicInfoName.lowercased()
        }
        let comicInfoData = comicInfo.flatMap { try? archive.data(for: $0) }

        var result = build(comicInfoData, fallbackName: fallbackName, pageCount: pages.count)

        if readCover {
            if let first = pages.first, let data = try? archive.data(for: first) {
                result.cover = data
                result.coverName = CoverFile.name(for: data)
            } else {
                result.warnings.append("no image in the archive – the comic has no cover")
            }
        }
        return result
    }

    /// The same, for an archive the app layer opened (a CBR through libarchive).
    ///
    /// `pages` are the image entries' names in the order the archive gives them;
    /// this sorts them. `readPage` is asked for the bytes of exactly one of them
    /// — the first — so a 400 MB comic is not unpacked to find its cover.
    public static func read(
        pageNames: [String], comicInfo: Data?, fallbackName: String,
        readPage: (String) -> Data?
    ) -> Result {
        let pages =
            pageNames
            .filter { EPUBMetadata.imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var result = build(comicInfo, fallbackName: fallbackName, pageCount: pages.count)
        if let first = pages.first, let data = readPage(first) {
            result.cover = data
            result.coverName = CoverFile.name(for: data)
        } else {
            result.warnings.append("no image could be read – the comic has no cover")
        }
        return result
    }

    /// The book, from `ComicInfo.xml` if it parsed and from the name if not.
    static func build(_ comicInfo: Data?, fallbackName: String, pageCount: Int) -> Result {
        var warnings: [String] = []

        if let comicInfo {
            if let root = try? XMLTree.parse(comicInfo), let book = ComicInfo.book(from: root, fallback: fallbackName) {
                return Result(book: book, warnings: warnings, hadComicInfo: true)
            }
            warnings.append("\(comicInfoName) could not be read – the metadata comes from the file name")
        }

        let book = ComicFileName.book(from: fallbackName)
        if book.authors.isEmpty {
            // Not "Unknown" in the field: an empty author is what every other
            // reader leaves, and the *display* decides what to call it.
            warnings.append("no author – a comic's file name rarely names one")
        }
        _ = pageCount
        return Result(book: book, warnings: warnings, hadComicInfo: false)
    }
}

/// `ComicInfo.xml`, the de-facto standard ComicRack wrote and everything since
/// reads.
///
/// A flat list of elements, so the mapping is a table. Only the fields Shelf
/// models are taken; the rest is left where it is rather than invented a home
/// for.
enum ComicInfo {
    /// Which element fills which field. Reference data, not an `if` chain.
    static let writerElements = ["Writer", "Penciller", "Artist", "CoverArtist"]

    static func book(from root: XMLTree.Element, fallback: String) -> Book? {
        func text(_ name: String) -> String? {
            let value = root.descendants(named: name).first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }

        let series = text("Series")
        let number = text("Number").flatMap(Double.init)
        let issueTitle = text("Title")

        // Nothing at all in the file: not a usable ComicInfo, so the caller
        // falls back to the name rather than making a book called "".
        guard series != nil || issueTitle != nil else { return nil }

        // `Saga 12` rather than bare `Saga`, for the same reason the file-name
        // route does it: forty books all called "Saga" is a shelf nobody can use.
        let title: String
        switch (series, number, issueTitle) {
        case (let series?, let number?, _):
            let printed = number == number.rounded() ? String(Int(number)) : String(number)
            title = "\(series) \(printed)"
        case (let series?, nil, let issueTitle?):
            title = "\(series): \(issueTitle)"
        case (let series?, nil, nil):
            title = series
        default:
            title = issueTitle ?? fallback
        }

        var book = Book(title: title)
        if let series {
            book.series = SeriesRef(name: series, index: number)
        }
        book.authors =
            writerElements
            .compactMap(text)
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, name in
                // First mention wins and the order is kept: the writer comes
                // before the artist in this list, and the first author decides
                // the folder.
                if !result.contains(name) { result.append(name) }
            }
        book.publisher = text("Publisher")
        book.description = text("Summary")
        book.language = text("LanguageISO")
        book.tags = Set(
            (text("Genre") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        ).sorted()

        if let year = text("Year").flatMap(Int.init), (1800...2099).contains(year) {
            var components = DateComponents()
            components.year = year
            components.month = text("Month").flatMap(Int.init) ?? 1
            components.day = text("Day").flatMap(Int.init) ?? 1
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            book.published = calendar.date(from: components)
        }
        return book
    }
}
