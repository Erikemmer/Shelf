import Foundation
import Testing

@testable import ShelfCore

/// Reading comics: the file name, `ComicInfo.xml`, and which page is the cover.
///
/// For most of a comics collection the file name is the *only* metadata there
/// will ever be, which is why these rules are in the core and tested rather
/// than in a regex somewhere in a view.
@Suite("Reading comics")
struct ComicMetadataTests {

    // MARK: The file name

    /// The shape the brief names, and the shapes that turn up next to it.
    @Test(
        "a comic's file name gives series, issue and year",
        arguments: [
            ("Serie 012 (2019)", "Serie", 12.0, 2019),
            ("Saga 001 (2012)", "Saga", 1.0, 2012),
            ("The Sandman #12 (1990)", "The Sandman", 12.0, 1990),
            ("The Sandman v02 (1990)", "The Sandman", 2.0, 1990),
            ("Black Hammer 004", "Black Hammer", 4.0, nil),
            ("Monstress 12.5 (2018)", "Monstress", 12.5, 2018),
            ("The.Sandman.v01.(1989)", "The Sandman", 1.0, 1989),
            ("Preacher_025_(1997)", "Preacher", 25.0, 1997),
        ])
    func fileNameShapes(name: String, series: String, number: Double, year: Int?) {
        let parsed = ComicFileName.parse(name)
        #expect(parsed.series == series)
        #expect(parsed.number == number)
        #expect(parsed.year == year)
    }

    /// The reason the year is taken out before the number is looked for.
    /// `Battle 2000 15` is series "Battle 2000", issue 15 — a pattern that
    /// searched anywhere in the name would call it series "Battle", issue 2000.
    @Test("a number inside the series name is not mistaken for the issue")
    func numberInsideTheSeriesName() {
        let parsed = ComicFileName.parse("Battle 2000 15")
        #expect(parsed.series == "Battle 2000")
        #expect(parsed.number == 15)
    }

    @Test("scanner noise in brackets is dropped, not made part of the series")
    func bracketNoise() {
        let parsed = ComicFileName.parse("Saga 012 (2019) (Digital) (Empire)")
        #expect(parsed.series == "Saga")
        #expect(parsed.number == 12)
        #expect(parsed.year == 2019)
    }

    @Test("a name with no number at all is a title, not a series of one")
    func noNumber() {
        let parsed = ComicFileName.parse("Watchmen")
        #expect(parsed.series == nil)
        #expect(parsed.number == nil)
        #expect(parsed.title == "Watchmen")

        let book = ComicFileName.book(from: "Watchmen")
        #expect(book.title == "Watchmen")
        #expect(book.series == nil)
    }

    /// Forty books all called "Saga" is a shelf nobody can use, so the issue
    /// number is part of the title as well as of the series index.
    @Test("the title carries the issue number, and the series carries it as an index")
    func titleCarriesTheNumber() {
        let book = ComicFileName.book(from: "Saga 012 (2019)")
        #expect(book.title == "Saga 12")
        #expect(book.series?.name == "Saga")
        #expect(book.series?.index == 12)
        #expect(book.published != nil)
    }

    @Test("a half issue keeps its half")
    func halfIssue() {
        let book = ComicFileName.book(from: "Monstress 12.5")
        #expect(book.title == "Monstress 12.5")
        #expect(book.series?.index == 12.5)
    }

    @Test("a four-digit group that is not a plausible year stays an issue number")
    func implausibleYear() {
        #expect(ComicFileName.parse("Series (3019)").year == nil)
        #expect(ComicFileName.parse("Series (1750)").year == nil)
        #expect(ComicFileName.parse("Series (1800)").year == 1800)
        #expect(ComicFileName.parse("Series (2099)").year == 2099)
    }

    // MARK: The archive

    @Test("the first page alphabetically is the cover")
    func firstPageIsTheCover() throws {
        let comic = SyntheticComic(pageNames: ["03.png", "01.png", "02.png"])
        let result = try ComicMetadata.read(ZipReader(data: comic.data()), fallbackName: "Saga 012 (2019)")

        let expected = try #require(comic.pages().first { $0.name == "01.png" }?.data)
        #expect(result.cover == expected)
        #expect(result.coverName == "cover.png")
    }

    /// The part that is easy to get wrong and impossible to notice: plain
    /// string order puts `page10` before `page2`, so the cover comes out as
    /// page ten.
    @Test("pages sort in natural order, so page 2 comes before page 10")
    func naturalOrder() throws {
        let comic = SyntheticComic(pageNames: ["page10.png", "page2.png", "page1.png"])
        let result = try ComicMetadata.read(ZipReader(data: comic.data()), fallbackName: "Saga 001")

        let expected = try #require(comic.pages().first { $0.name == "page1.png" }?.data)
        #expect(result.cover == expected)
    }

    @Test("an archive with no images is still a book, and says it has no cover")
    func noImages() throws {
        let archive = ZipWriter().archive([ZipWriter.Item(path: "readme.txt", text: "nothing here")])
        let result = try ComicMetadata.read(ZipReader(data: archive), fallbackName: "Saga 012 (2019)")

        #expect(result.cover == nil)
        #expect(result.book.title == "Saga 12")
        #expect(result.warnings.contains { $0.contains("no cover") })
    }

    @Test("a file that is not a zip is refused")
    func notAZip() {
        #expect(throws: (any Error).self) {
            try ComicMetadata.read(ZipReader(data: Data("not a zip".utf8)), fallbackName: "x")
        }
    }

    // MARK: ComicInfo.xml

    @Test("ComicInfo.xml wins over the file name")
    func comicInfoWins() throws {
        let info = SyntheticComic.comicInfo(
            series: "The Sandman", number: "12", writer: "Neil Gaiman",
            publisher: "Vertigo", year: "1990", month: "3", genre: "Fantasy, Horror",
            summary: "A story.", language: "en")
        // The file name says something else entirely, so there is no doubt
        // which of the two the result came from.
        let comic = SyntheticComic(comicInfo: info)
        let result = try ComicMetadata.read(ZipReader(data: comic.data()), fallbackName: "Rubbish 999 (2001)")

        #expect(result.hadComicInfo)
        #expect(result.book.title == "The Sandman 12")
        #expect(result.book.series?.name == "The Sandman")
        #expect(result.book.series?.index == 12)
        #expect(result.book.authors == ["Neil Gaiman"])
        #expect(result.book.publisher == "Vertigo")
        #expect(result.book.description == "A story.")
        #expect(result.book.language == "en")
        #expect(result.book.tags == ["Fantasy", "Horror"])
        #expect(result.book.published != nil)
    }

    @Test("the writer comes before the artist, and nobody is listed twice")
    func authorOrder() throws {
        let info = """
            <?xml version="1.0"?>
            <ComicInfo>
              <Series>Saga</Series>
              <Number>1</Number>
              <Writer>Brian K. Vaughan</Writer>
              <Penciller>Fiona Staples</Penciller>
              <CoverArtist>Fiona Staples</CoverArtist>
            </ComicInfo>
            """
        let result = try ComicMetadata.read(
            ZipReader(data: SyntheticComic(comicInfo: info).data()), fallbackName: "x")
        #expect(result.book.authors == ["Brian K. Vaughan", "Fiona Staples"])
    }

    @Test("an unreadable ComicInfo.xml falls back to the file name and says so")
    func brokenComicInfo() throws {
        let comic = SyntheticComic(comicInfo: "<ComicInfo><Series>unclosed")
        let result = try ComicMetadata.read(ZipReader(data: comic.data()), fallbackName: "Saga 012 (2019)")

        #expect(!result.hadComicInfo)
        #expect(result.book.title == "Saga 12")
        #expect(result.warnings.contains { $0.contains("ComicInfo.xml") })
    }

    /// A `ComicInfo.xml` that parses but names nothing is not better than the
    /// file name, and using it would make a book called "".
    @Test("an empty ComicInfo.xml is ignored in favour of the file name")
    func emptyComicInfo() throws {
        let comic = SyntheticComic(comicInfo: "<?xml version=\"1.0\"?><ComicInfo><PageCount>20</PageCount></ComicInfo>")
        let result = try ComicMetadata.read(ZipReader(data: comic.data()), fallbackName: "Saga 012 (2019)")

        #expect(!result.hadComicInfo)
        #expect(result.book.title == "Saga 12")
    }

    @Test("a series with a title but no number reads as 'Series: Title'")
    func seriesAndTitle() throws {
        let info = SyntheticComic.comicInfo(series: "Hellboy", title: "Seed of Destruction")
        let result = try ComicMetadata.read(
            ZipReader(data: SyntheticComic(comicInfo: info).data()), fallbackName: "x")
        #expect(result.book.title == "Hellboy: Seed of Destruction")
    }

    // MARK: The way in the app layer uses for CBR

    /// A CBR is read through libarchive in the app layer, which hands the entry
    /// names and the bytes of exactly one page here. The rules are the same
    /// ones, which is the point of the second entry point.
    @Test("a CBR read through the app layer follows the same rules")
    func throughTheAppLayerEntryPoint() {
        let pages = ["page10.jpg", "page2.jpg", "cover.txt"]
        let bytes = MinimalPNG.cover(width: 8, height: 12, seed: 5)
        var asked: [String] = []

        let result = ComicMetadata.read(
            pageNames: pages, comicInfo: nil, fallbackName: "Saga 012 (2019)",
            readPage: { name in
                asked.append(name)
                return bytes
            })

        // Natural order again, and only *one* page is ever read: a 400 MB comic
        // must not be unpacked to find its cover.
        #expect(asked == ["page2.jpg"])
        #expect(result.cover == bytes)
        #expect(result.book.title == "Saga 12")
    }

    @Test("a CBR libarchive could not open falls back to the name and says there is no cover")
    func cbrWithNoReadablePages() {
        let result = ComicMetadata.read(
            pageNames: [], comicInfo: nil, fallbackName: "Saga 012 (2019)", readPage: { _ in nil })
        #expect(result.cover == nil)
        #expect(result.book.title == "Saga 12")
        #expect(result.warnings.contains { $0.contains("no cover") })
    }
}
