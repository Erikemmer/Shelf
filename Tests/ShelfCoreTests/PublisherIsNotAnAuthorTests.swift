import Foundation
import Testing

@testable import ShelfCore

/// A publisher is not an author, in any of the four format paths.
///
/// Found by looking at the Sprint 4 screenshot, where the sidebar's *Authors*
/// list held "A Publisher" with three books under it. Those three turned out to
/// be the fixture's own doing — `synthesise-mixed` gave its DRM books the
/// author "A Publisher" — but the question the screenshot raised is a real one,
/// and until this file existed nothing in the repository answered it: no test
/// said that a file naming only its publisher comes out with *no* author.
///
/// The rule is one sentence, and it is the same in all four readers: **a
/// missing author stays missing.** An empty author field files a book under
/// "Unknown", which is a thing the user can see and fix; a publisher in that
/// field files a thousand books under Penguin, which looks like metadata and
/// is not.
@Suite("A publisher is not an author")
struct PublisherIsNotAnAuthorTests {

    // MARK: EPUB / OPF

    @Test("an OPF with a publisher and no creator comes out with no author")
    func opfPublisherOnly() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>A Book Nobody Signed</dc:title>
                <dc:publisher>Head of Zeus</dc:publisher>
              </metadata>
            </package>
            """
        let parsed = try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x")
        #expect(parsed.book.authors.isEmpty)
        #expect(parsed.book.publisher == "Head of Zeus")
    }

    /// EPUB 2 says the role in an attribute. Already handled, and locked here
    /// so it stays that way.
    @Test("a creator whose opf:role is the publisher's is not an author")
    func opfRoleAttribute() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                        xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>A Book</dc:title>
                <dc:creator opf:role="pbl">Head of Zeus</dc:creator>
                <dc:creator opf:role="aut">Becky Lefèvre</dc:creator>
              </metadata>
            </package>
            """
        let parsed = try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x")
        #expect(parsed.book.authors == ["Becky Lefèvre"])
    }

    /// EPUB 3 says the same thing in a different place, and this is the one
    /// the reader did not know. `<meta refines="#id" property="role">pbl</meta>`
    /// is the spelling every EPUB 3 produced since 2011 uses, and a
    /// `<dc:creator>` carrying it went straight into the author list.
    @Test("a creator whose EPUB 3 refines role is the publisher's is not an author")
    func opfRefinesRole() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>A Book</dc:title>
                <dc:creator id="pub">Head of Zeus</dc:creator>
                <meta refines="#pub" property="role" scheme="marc:relators">pbl</meta>
                <dc:creator id="auth">Becky Lefèvre</dc:creator>
                <meta refines="#auth" property="role" scheme="marc:relators">aut</meta>
              </metadata>
            </package>
            """
        let parsed = try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x")
        #expect(parsed.book.authors == ["Becky Lefèvre"])
    }

    /// And the limit of it: a creator with no role at all is an author. Most
    /// EPUBs name one that way, and dropping them would empty the sidebar.
    @Test("a creator with no role at all is still an author")
    func opfNoRoleIsAnAuthor() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>A Book</dc:title>
                <dc:creator>Becky Lefèvre</dc:creator>
              </metadata>
            </package>
            """
        let parsed = try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x")
        #expect(parsed.book.authors == ["Becky Lefèvre"])
    }

    // MARK: MOBI / AZW3

    /// EXTH 100 is the author and EXTH 101 is the publisher. A file that has
    /// only 101 has no author, and the reader says so in a warning rather than
    /// filling the field in.
    @Test("a MOBI with EXTH 101 and no EXTH 100 comes out with no author")
    func mobiPublisherOnly() throws {
        var book = Book(title: "A Book Nobody Signed")
        book.publisher = "Head of Zeus"
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent("nameless.mobi")
        try SyntheticMobi(book: book).data().write(to: url)

        let read = try MobiMetadata.read(url: url, readCover: false)
        #expect(read.book.authors.isEmpty)
        #expect(read.book.publisher == "Head of Zeus")
        #expect(read.warnings.contains { $0.contains("no author") })
    }

    // MARK: CBZ / ComicInfo.xml

    /// `ComicInfo.xml` has a `<Publisher>` next to its `<Writer>`, and a great
    /// many scraped comics have only the former.
    @Test("a ComicInfo.xml with a publisher and no writer comes out with no author")
    func comicInfoPublisherOnly() throws {
        let xml = """
            <?xml version="1.0"?>
            <ComicInfo>
              <Series>Saga</Series>
              <Number>12</Number>
              <Publisher>Image Comics</Publisher>
            </ComicInfo>
            """
        let root = try XMLTree.parse(Data(xml.utf8))
        let book = try #require(ComicInfo.book(from: root, fallback: "Saga 012"))
        #expect(book.authors.isEmpty)
        #expect(book.publisher == "Image Comics")
    }
}
