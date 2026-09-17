import Foundation
import Testing

@testable import ShelfCore

/// The one place that decides which reader a file gets.
///
/// Worth its own tests because it is the piece that replaced a single
/// `if format.hasReadableMetadata` — and the failure it can have is the quiet
/// kind: a format routed to the wrong reader still produces a book, just one
/// named after its file, and nobody notices for a sprint.
@Suite("Choosing a reader for a file")
struct BookFileReaderTests {

    private func write(_ folder: TemporaryFolder, _ name: String, _ data: Data) throws -> URL {
        try folder.write(name, data: data)
    }

    @Test("an EPUB is read by the EPUB reader")
    func epub() throws {
        let folder = try TemporaryFolder()
        let book = Book(title: "Emma", authors: ["Jane Austen"], tags: ["classic"])
        let url = try write(
            folder, "anything.epub",
            SyntheticEPUB(book: book, cover: MinimalPNG.cover(width: 8, height: 12, seed: 1)).data())

        let read = BookFileReader.read(url: url, format: .epub)
        #expect(read.fromTheFile)
        #expect(read.book.title == "Emma")
        #expect(read.book.authors == ["Jane Austen"])
        #expect(read.cover != nil)
    }

    @Test("a MOBI and an AZW3 are read by the MOBI reader")
    func mobiAndAZW3() throws {
        let folder = try TemporaryFolder()
        let book = Book(title: "Ancillary Justice", authors: ["Ann Leckie"])

        for (name, format, isAZW3) in [("a.mobi", BookFileFormat.mobi, false), ("a.azw3", .azw3, true)] {
            let url = try write(folder, name, SyntheticMobi(book: book, isAZW3: isAZW3).data())
            let read = BookFileReader.read(url: url, format: format)
            #expect(read.fromTheFile, "\(format.label) should be read from the file")
            #expect(read.book.title == "Ancillary Justice")
            #expect(read.book.authors == ["Ann Leckie"])
        }
    }

    @Test("a CBZ is read by the comic reader")
    func cbz() throws {
        let folder = try TemporaryFolder()
        let comic = SyntheticComic(comicInfo: SyntheticComic.comicInfo(series: "Saga", number: "12"))
        let url = try write(folder, "whatever.cbz", comic.data())

        let read = BookFileReader.read(url: url, format: .cbz)
        #expect(read.book.title == "Saga 12")
        #expect(read.cover != nil)
        #expect(read.fromTheFile)
    }

    /// A CBZ with no `ComicInfo.xml` is read — it gives a cover and a title —
    /// but `fromTheFile` is false, because the title came off the *name*. The
    /// report has to be able to say which.
    @Test("a CBZ with no ComicInfo says its metadata did not come from the file")
    func cbzWithoutComicInfo() throws {
        let folder = try TemporaryFolder()
        let url = try write(folder, "Saga 012 (2019).cbz", SyntheticComic().data())

        let read = BookFileReader.read(url: url, format: .cbz)
        #expect(read.book.title == "Saga 12")
        #expect(read.cover != nil)
        #expect(!read.fromTheFile)
    }

    /// The core is honest about what it cannot do rather than silent. A caller
    /// with no app layer — this test, the command-line tool, the Linux CI job —
    /// gets the file name *and the reason*.
    @Test("PDF and CBR come back named after the file, saying the app reads them")
    func appLayerFormats() throws {
        let folder = try TemporaryFolder()
        for (name, format) in [("The Hobbit - Tolkien.pdf", BookFileFormat.pdf), ("Saga 012 (2019).cbr", .cbr)] {
            let url = try write(folder, name, Data("not really one of these".utf8))
            let read = BookFileReader.read(url: url, format: format)

            #expect(!read.fromTheFile)
            #expect(read.cover == nil)
            #expect(read.warnings.contains { $0.contains("read by the app") })
        }
    }

    @Test("a KFX is named and counted and nothing else")
    func kfx() throws {
        let folder = try TemporaryFolder()
        let url = try write(folder, "The Hobbit - J.R.R. Tolkien.kfx", Data("CONT".utf8))

        let read = BookFileReader.read(url: url, format: .kfx)
        #expect(read.book.title == "The Hobbit")
        #expect(read.book.authors == ["J.R.R. Tolkien"])
        #expect(!read.fromTheFile)
        #expect(read.cover == nil)
        #expect(read.warnings.contains { $0.contains("KFX") })
    }

    /// The rule the whole family follows: a file that will not parse is still a
    /// book, named after itself, with the reason in the report. Nothing here
    /// throws and nothing is refused.
    @Test("a file of the right name and the wrong bytes is still a book")
    func rubbishBytes() throws {
        let folder = try TemporaryFolder()
        let rubbish = Data("this is not a book at all".utf8)

        for format in BookFileFormat.allCases {
            let url = try write(folder, "The Hobbit - J.R.R. Tolkien.\(format.fileExtension)", rubbish)
            let read = BookFileReader.read(url: url, format: format)

            #expect(read.book.title == "The Hobbit", "\(format.label) lost the title")
            #expect(read.book.authors == ["J.R.R. Tolkien"], "\(format.label) lost the author")
            #expect(!read.warnings.isEmpty, "\(format.label) said nothing about failing")
        }
    }

    @Test("a file that is not there at all is a book, not a crash")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nowhere/Dune - Frank Herbert.epub")
        let read = BookFileReader.read(url: url, format: .epub)
        #expect(read.book.title == "Dune")
        #expect(!read.warnings.isEmpty)
    }
}
