import Foundation
import Testing

@testable import ShelfCore

/// The fix behind Sprint 21, Teil B4's own finding: a `metadata.opf` already
/// beside a book file, about to be imported for the first time, used to be
/// silently ignored.
@Suite("A metadata.opf already beside a book file, on a fresh import")
struct SidecarOPFTests {
    @Test("a real OPF beside the file is preferred, description included")
    func prefersTheOPF() throws {
        let folder = try TemporaryFolder()
        let book = Book(
            title: "Ein erfundener Titel", authors: ["Erfundene Autorin"],
            description: "Eine erfundene, ausführliche Beschreibung, wie Calibre sie oft trägt.")
        try OPFDocument.write(book, to: folder.url)
        let fileURL = folder.url.appendingPathComponent("book.epub")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let found = try #require(SidecarOPF.book(besideFile: fileURL, fallbackTitle: "Ein anderer Titel"))
        #expect(found.title == "Ein erfundener Titel")
        #expect(found.description == "Eine erfundene, ausführliche Beschreibung, wie Calibre sie oft trägt.")
    }

    @Test("no metadata.opf beside the file — nothing to prefer") func noOPF() throws {
        let folder = try TemporaryFolder()
        let fileURL = folder.url.appendingPathComponent("book.epub")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        #expect(SidecarOPF.book(besideFile: fileURL, fallbackTitle: "Ein Titel") == nil)
    }

    @Test("a metadata.opf in a different folder is never read") func wrongFolderIsNeverRead() throws {
        let bookFolder = try TemporaryFolder()
        let opfFolder = try TemporaryFolder()
        try OPFDocument.write(Book(title: "Falscher Titel", authors: []), to: opfFolder.url)
        let fileURL = bookFolder.url.appendingPathComponent("book.epub")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        #expect(SidecarOPF.book(besideFile: fileURL, fallbackTitle: "Ein Titel") == nil)
    }
}
