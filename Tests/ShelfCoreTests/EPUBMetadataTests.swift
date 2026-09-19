import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// Reading EPUBs. Every fixture is built here, by `SyntheticEPUB` for the
/// ordinary cases and by hand for the broken ones – because the broken ones are
/// the point: a library of 8 000 books contains files assembled by tools nobody
/// remembers, and losing a book because its `container.xml` is odd is not
/// acceptable.
@Suite("Reading EPUBs")
struct EPUBMetadataTests {

    // MARK: The ordinary case

    @Test("title, author, tags, series and identifiers come out of the OPF")
    func fullMetadata() throws {
        let book = Book(
            title: "The Left Hand of Darkness",
            authors: ["Ursula K. Le Guin"],
            series: SeriesRef(name: "Hainish Cycle", index: 4),
            publisher: "Gollancz",
            language: "en",
            description: "Winter is a planet of ice.",
            tags: ["science fiction", "classics"],
            identifiers: ["isbn": "9780441478125"])
        let data = SyntheticEPUB(book: book, cover: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])).data()

        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "ignored")
        #expect(read.book.title == "The Left Hand of Darkness")
        #expect(read.book.authors == ["Ursula K. Le Guin"])
        #expect(read.book.series == SeriesRef(name: "Hainish Cycle", index: 4))
        #expect(read.book.publisher == "Gollancz")
        #expect(read.book.language == "en")
        #expect(read.book.description == "Winter is a planet of ice.")
        #expect(read.book.tags.sorted() == ["classics", "science fiction"])
        #expect(read.book.identifiers["isbn"] == "9780441478125")
        #expect(read.book.isbn == "9780441478125")
        #expect(read.drm == nil)
        #expect(read.warnings.isEmpty)
    }

    /// The UUID is the book's identity and the reason the index can be thrown
    /// away and rebuilt, so it has to survive the round trip exactly.
    @Test("the UUID in the OPF becomes the book's identity")
    func identity() throws {
        let id = UUID()
        let data = SyntheticEPUB(book: Book(id: id, title: "A Book"), cover: Data([1])).data()
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "ignored")
        #expect(read.book.id == id)
    }

    @Test("the cover is found through the manifest and comes back as bytes")
    func cover() throws {
        let image = MinimalPNG.cover(width: 20, height: 30, seed: 7)
        let data = SyntheticEPUB(book: Book(title: "A Book"), cover: image).data()
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "ignored")
        #expect(read.cover == image)
        #expect(read.coverName == "cover.png")
    }

    @Test("reading without the cover leaves it out but keeps the metadata")
    func withoutCover() throws {
        let data = SyntheticEPUB(book: Book(title: "A Book"), cover: Data([1, 2])).data()
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "x", readCover: false)
        #expect(read.cover == nil)
        #expect(read.book.title == "A Book")
    }

    // MARK: Files that are not quite right

    /// The OPF's href is relative to the OPF, not to the archive root. Getting
    /// this wrong loses the cover of every EPUB that keeps its files in a
    /// subfolder, which is most of them.
    @Test("a cover href is resolved against the OPF's own folder")
    func hrefResolution() {
        #expect(EPUBMetadata.resolve("cover.jpg", relativeTo: "OEBPS/content.opf") == "OEBPS/cover.jpg")
        #expect(EPUBMetadata.resolve("images/cover.jpg", relativeTo: "OEBPS/content.opf") == "OEBPS/images/cover.jpg")
        #expect(EPUBMetadata.resolve("../cover.jpg", relativeTo: "OEBPS/content.opf") == "cover.jpg")
        #expect(EPUBMetadata.resolve("./cover.jpg", relativeTo: "OEBPS/content.opf") == "OEBPS/cover.jpg")
        #expect(EPUBMetadata.resolve("/cover.jpg", relativeTo: "OEBPS/content.opf") == "cover.jpg")
        #expect(EPUBMetadata.resolve("cover.jpg", relativeTo: "content.opf") == "cover.jpg")
        // `..` that would climb past the root stays at the root rather than
        // producing a path with ".." in it.
        #expect(EPUBMetadata.resolve("../../cover.jpg", relativeTo: "OEBPS/content.opf") == "cover.jpg")
    }

    @Test("a percent-encoded href is decoded, because a ZIP path is not a URL")
    func percentEncodedHref() {
        #expect(
            EPUBMetadata.resolve("images/my%20cover.jpg", relativeTo: "OEBPS/content.opf")
                == "OEBPS/images/my cover.jpg")
    }

    @Test("without container.xml the first OPF in the archive is used, with a warning")
    func missingContainer() throws {
        let data = ZipWriter().archive([
            .init(path: "mimetype", text: "application/epub+zip"),
            .init(path: "book.opf", text: Self.minimalOPF(title: "Found Anyway")),
            .init(path: "text.xhtml", text: "<html/>"),
        ])
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "file name")
        #expect(read.book.title == "Found Anyway")
        #expect(read.warnings.contains { $0.contains("book.opf") })
    }

    @Test("a container.xml pointing at nothing falls back to the OPF that is there")
    func containerPointsAtNothing() throws {
        let container = """
            <?xml version="1.0"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="MISSING/content.opf"/></rootfiles>
            </container>
            """
        let data = ZipWriter().archive([
            .init(path: "META-INF/container.xml", text: container),
            .init(path: "real.opf", text: Self.minimalOPF(title: "Still Here")),
        ])
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "x")
        #expect(read.book.title == "Still Here")
    }

    /// No OPF at all is still a book – named after its file, with a warning.
    /// The alternative is refusing to import a file the user can see is a book.
    @Test("with no OPF the file name becomes the metadata")
    func noOPF() throws {
        let data = ZipWriter().archive([
            .init(path: "mimetype", text: "application/epub+zip"),
            .init(path: "text.xhtml", text: "<html/>"),
        ])
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "The Hobbit - J.R.R. Tolkien")
        #expect(read.book.title == "The Hobbit")
        #expect(read.book.authors == ["J.R.R. Tolkien"])
        #expect(read.warnings.contains { $0.contains("file name") })
    }

    @Test("an OPF with no author borrows one from the file name")
    func authorFromFileName() throws {
        let data = ZipWriter().archive([
            .init(path: "META-INF/container.xml", text: SyntheticEPUB.container),
            .init(path: "OEBPS/content.opf", text: Self.minimalOPF(title: "A Title")),
        ])
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "A Title - Some Author")
        #expect(read.book.title == "A Title")
        #expect(read.book.authors == ["Some Author"])
        #expect(read.warnings.contains { $0.contains("author") })
    }

    /// When the manifest names no cover, the first image is taken. For a
    /// hand-made EPUB or a comic that is the front page, and a wrong cover is
    /// easier to notice and fix than a missing one.
    @Test("with no cover in the manifest the first image alphabetically is used")
    func coverFallback() throws {
        let data = ZipWriter().archive([
            .init(path: "META-INF/container.xml", text: SyntheticEPUB.container),
            .init(path: "OEBPS/content.opf", text: Self.minimalOPF(title: "No Manifest Cover")),
            .init(path: "OEBPS/img/002.png", data: Data([2])),
            .init(path: "OEBPS/img/001.png", data: Data([1])),
        ])
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "x")
        #expect(read.cover == Data([1]))
        #expect(read.coverName == "001.png")
    }

    @Test("EPUB 2's meta name=cover is followed")
    func epub2Cover() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Old Style</dc:title>
                <meta name="cover" content="my-cover"/>
              </metadata>
              <manifest>
                <item id="my-cover" href="pictures/front.png" media-type="image/png"/>
                <item id="other" href="pictures/back.png" media-type="image/png"/>
              </manifest>
            </package>
            """
        let data = ZipWriter().archive([
            .init(path: "META-INF/container.xml", text: SyntheticEPUB.container),
            .init(path: "OEBPS/content.opf", text: opf),
            .init(path: "OEBPS/pictures/back.png", data: Data([9])),
            .init(path: "OEBPS/pictures/front.png", data: Data([7])),
        ])
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "x")
        #expect(read.cover == Data([7]))
    }

    // MARK: DRM
    //
    // Recognised, badged, and otherwise left entirely alone. Never removed,
    // never worked around (CONCEPT §12).

    @Test("an encrypted EPUB is recognised and still imported")
    func drm() throws {
        let data = ZipWriter().archive([
            .init(path: "META-INF/container.xml", text: SyntheticEPUB.container),
            .init(path: "META-INF/encryption.xml", text: "<encryption/>"),
            .init(path: "OEBPS/content.opf", text: Self.minimalOPF(title: "Protected")),
        ])
        let read = EPUBMetadata.read(try ZipReader(data: data), fallbackTitle: "x")
        #expect(read.drm == .adobeADEPT)
        #expect(read.book.title == "Protected")
    }

    @Test("a file that is not a ZIP is not an EPUB")
    func notAnEPUB() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("broken.epub", text: "not an archive")
        #expect(throws: EPUBMetadata.Failure.notAnEPUB("broken.epub")) {
            try EPUBMetadata.read(url: url)
        }
    }

    @Test("reading from disk works the same as reading bytes")
    func fromDisk() throws {
        let folder = try TemporaryFolder()
        let epub = SyntheticEPUB(book: Book(title: "On Disk"), cover: Data([1])).data()
        let url = try folder.write("book.epub", data: epub)
        #expect(try EPUBMetadata.read(url: url).book.title == "On Disk")
    }

    static func minimalOPF(title: String) -> String {
        """
        <?xml version='1.0' encoding='utf-8'?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
          </metadata>
          <manifest/>
        </package>
        """
    }
}

@Suite("What a file name says about a book")
struct FileNameMetadataTests {

    @Test("title before the dash, author after – the way downloads are named")
    func titleAndAuthor() {
        #expect(FileNameMetadata.title(from: "The Hobbit - J.R.R. Tolkien") == "The Hobbit")
        #expect(FileNameMetadata.authors(from: "The Hobbit - J.R.R. Tolkien") == ["J.R.R. Tolkien"])
    }

    @Test("an en dash and an em dash count as separators too")
    func dashes() {
        #expect(FileNameMetadata.title(from: "Dune – Frank Herbert") == "Dune")
        #expect(FileNameMetadata.authors(from: "Dune — Frank Herbert") == ["Frank Herbert"])
    }

    @Test("a name without a separator is all title, and no author is invented")
    func noSeparator() {
        #expect(FileNameMetadata.title(from: "Piranesi") == "Piranesi")
        #expect(FileNameMetadata.authors(from: "Piranesi").isEmpty)
    }

    /// A wrong author files the book under the wrong folder, so a guess is
    /// worse than nothing.
    @Test("underscores become spaces and a shop's prefix is dropped")
    func noise() {
        #expect(
            FileNameMetadata.title(from: "_OceanofPDF.com_The_Wife_Upstairs_-_Freida_McFadden")
                == "The Wife Upstairs")
        #expect(
            FileNameMetadata.authors(from: "_OceanofPDF.com_The_Wife_Upstairs_-_Freida_McFadden")
                == ["Freida McFadden"])
    }

    @Test("the first separator wins, so a title containing a dash keeps its tail")
    func severalSeparators() {
        #expect(FileNameMetadata.title(from: "Book One - Part Two - An Author") == "Book One")
    }

    @Test("an empty name produces an empty title rather than a crash")
    func empty() {
        #expect(FileNameMetadata.title(from: "") == "")
        #expect(FileNameMetadata.authors(from: "").isEmpty)
    }
}
