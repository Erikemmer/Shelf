import Foundation

/// Writes a CBZ nobody wrote: a handful of PNG pages and, optionally, a
/// `ComicInfo.xml`.
///
/// A CBZ really is just a zip of images, so unlike the MOBI fixture this one is
/// not a re-implementation of anything — it is the format. The pages are
/// deliberately named out of order (`page10`, `page2`) in one of the tests,
/// because natural-order sorting is the part of reading a comic that is easy to
/// get wrong and impossible to notice: the cover comes out as page 10.
public struct SyntheticComic: Sendable {
    public var pageNames: [String]
    public var comicInfo: String?
    /// The seed for each page's colours, so two runs make the same file.
    public var seed: UInt8
    /// The page size. Not decoration: it is the second thing that makes one
    /// generated comic's bytes differ from another's.
    ///
    /// The proof run's first attempt seeded on `index % 200` and nothing else,
    /// so comics 0, 200 and 400 came out **byte for byte identical**. The
    /// importer skipped 300 of 500 as duplicates of each other — correctly, by
    /// SHA-256 — and the run measured the duplicate check instead of the comic
    /// reader. A fixture that collides with itself measures the wrong thing.
    public var pageWidth: Int
    public var pageHeight: Int

    public init(
        pageNames: [String] = ["01.png", "02.png", "03.png"], comicInfo: String? = nil, seed: UInt8 = 3,
        pageWidth: Int = 8, pageHeight: Int = 12
    ) {
        self.pageNames = pageNames
        self.comicInfo = comicInfo
        self.seed = seed
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
    }

    /// The page images, by name, so a test can check *which* page became the
    /// cover rather than only that there is one.
    public func pages() -> [(name: String, data: Data)] {
        pageNames.enumerated().map { index, name in
            (name, MinimalPNG.cover(width: pageWidth, height: pageHeight, seed: seed &+ UInt8(index % 200)))
        }
    }

    public func data() -> Data {
        var items = pages().map { ZipWriter.Item(path: $0.name, data: $0.data) }
        if let comicInfo {
            items.append(ZipWriter.Item(path: ComicMetadata.comicInfoName, text: comicInfo))
        }
        return ZipWriter().archive(items)
    }

    /// A `ComicInfo.xml` with the fields Shelf reads.
    public static func comicInfo(
        series: String? = nil, number: String? = nil, title: String? = nil, writer: String? = nil,
        publisher: String? = nil, year: String? = nil, month: String? = nil, genre: String? = nil,
        summary: String? = nil, language: String? = nil
    ) -> String {
        var lines = ["<?xml version=\"1.0\"?>", "<ComicInfo>"]
        func element(_ name: String, _ value: String?) {
            guard let value else { return }
            lines.append("  <\(name)>\(value)</\(name)>")
        }
        element("Series", series)
        element("Number", number)
        element("Title", title)
        element("Writer", writer)
        element("Publisher", publisher)
        element("Year", year)
        element("Month", month)
        element("Genre", genre)
        element("Summary", summary)
        element("LanguageISO", language)
        lines.append("</ComicInfo>")
        return lines.joined(separator: "\n")
    }
}
