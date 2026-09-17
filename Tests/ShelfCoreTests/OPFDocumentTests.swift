import Foundation
import Testing

@testable import ShelfCore

/// `metadata.opf` – the file that makes a library readable without Shelf, and
/// the reason a return to Calibre stays possible. A round trip that loses a
/// field is a library that loses it.
@Suite("metadata.opf")
struct OPFDocumentTests {

    @Test("everything written comes back")
    func roundTrip() throws {
        let book = Book(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
            title: "The Dispossessed",
            authors: ["Ursula K. Le Guin", "A Second Author"],
            series: SeriesRef(name: "Hainish Cycle", index: 6),
            rating: 5,
            isRead: true,
            publisher: "Gollancz",
            published: Date(timeIntervalSince1970: 1_000_000_000),
            language: "en",
            description: "Two worlds, one wall.",
            tags: ["science fiction", "utopia"],
            identifiers: ["isbn": "9780061054884", "goodreads": "13651"])

        let parsed = try OPFDocument.read(Data(OPFDocument.render(book).utf8), fallbackTitle: "x")

        #expect(parsed.book.id == book.id)
        #expect(parsed.book.title == book.title)
        #expect(parsed.book.authors == book.authors)
        #expect(parsed.book.series == book.series)
        #expect(parsed.book.rating == 5)
        #expect(parsed.book.isRead)
        #expect(parsed.book.publisher == "Gollancz")
        #expect(parsed.book.language == "en")
        #expect(parsed.book.description == "Two worlds, one wall.")
        #expect(parsed.book.tags.sorted() == ["science fiction", "utopia"])
        #expect(parsed.book.identifiers["isbn"] == "9780061054884")
        #expect(parsed.book.identifiers["goodreads"] == "13651")
        #expect(parsed.book.titleSort == "Dispossessed, The")
    }

    /// The same book has to render to the same bytes, or a library folder shows
    /// a change in every diff and a real change cannot be spotted.
    @Test("rendering is stable: the same book gives the same bytes")
    func stableOutput() {
        let book = Book(
            title: "A Book", authors: ["B", "A"], tags: ["z", "a", "m"],
            identifiers: ["isbn": "1", "asin": "2"],
            addedAt: Date(timeIntervalSince1970: 1))
        #expect(OPFDocument.render(book) == OPFDocument.render(book))
    }

    @Test("the shelves a book is on survive, so a lost index costs nothing")
    func shelfPaths() throws {
        let text = OPFDocument.render(
            Book(title: "A Book"), shelfPaths: ["Fiction ▸ Science Fiction", "To Read"])
        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")
        #expect(parsed.shelfPaths == ["Fiction ▸ Science Fiction", "To Read"])
    }

    /// A shelf name may contain a comma or a slash, which is why the separator
    /// is the unit separator and not a comma.
    @Test("a shelf name with a comma in it still survives")
    func shelfNameWithComma() throws {
        let text = OPFDocument.render(Book(title: "x"), shelfPaths: ["Crime, Mystery & Thriller"])
        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")
        #expect(parsed.shelfPaths == ["Crime, Mystery & Thriller"])
    }

    @Test("the five XML entities are escaped, in titles and in descriptions")
    func escaping() throws {
        let book = Book(
            title: "Tom & Jerry <the> \"Original\" 'Show'",
            authors: ["A & B"],
            description: "5 < 6 & 7 > 3")
        let text = OPFDocument.render(book)
        #expect(text.contains("&amp;"))
        #expect(!text.contains("<the>"))

        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")
        #expect(parsed.book.title == book.title)
        #expect(parsed.book.authors == ["A & B"])
        #expect(parsed.book.description == "5 < 6 & 7 > 3")
    }

    // MARK: What a person can type into a field
    //
    // Sprint 2b made every field editable, so every field now holds whatever
    // somebody pasted into it. These are the characters that break an XML
    // writer, and the two that break it *silently* – a newline in an attribute
    // and a carriage return anywhere – are the reason there are two escaping
    // functions rather than one.

    /// One book carrying everything at once: the five entities, umlauts, an
    /// emoji, line breaks, a tab, and a description the size of a real one.
    private func awkwardBook() -> Book {
        var book = Book(
            title: "Tom & Jerry <the> \"Original\" 'Show' – Größenwahn 📚",
            titleSort: "Größenwahn\t& <Sort>\nsecond line",
            authors: ["Ursula & Karl <Le Guin>", "Émile Ölafsdóttir 🖋"],
            series: SeriesRef(name: "Hainish & <Cycle> \"Two\"\nwrapped", index: 2.5),
            publisher: "Gollancz & Söhne <Verlag>",
            language: "de",
            description: """
                Zwei Welten, eine Mauer – und ein "Zitat" mit & und <Klammern>.

                Ein zweiter Absatz, mit Umlauten (Grüße, Äpfel, Öl) und einem Emoji 📖.
                \tEine eingerückte Zeile.
                Und ein Windows-Umbruch:\r
                danach geht es weiter.
                """,
            tags: ["science & fiction", "<utopia>", "Grüße"],
            identifiers: ["isbn": "9780061054884", "custom": "a & b <c> \"d\""])
        // 20 KB, which is what a real blurb plus a publisher's HTML comes to.
        // No trailing space: the XML reader trims an element's text at both
        // ends, so a value stored with one would not come back with one. That
        // is why `BookField.apply` trims what a person types — "what was
        // stored" and "what comes back" are then the same string.
        book.description =
            (book.description ?? "") + "\n"
            + String(repeating: "Lange Beschreibung mit & und <Zeichen>. ", count: 500)
            .trimmingCharacters(in: .whitespaces)
        return book
    }

    @Test("every awkward character survives book → OPF → book")
    func awkwardRoundTrip() throws {
        let book = awkwardBook()
        let text = OPFDocument.render(book)
        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")

        for field in MetadataChange.Field.allCases {
            #expect(!field.differs(book, parsed.book), "\(field.label) did not survive the round trip")
        }
        #expect((parsed.book.description?.count ?? 0) > 20_000)
    }

    /// The defect this catches without the two-function fix: XML
    /// attribute-value normalisation turns a tab, a newline or a carriage
    /// return inside an attribute into a *space* before the parser reports it.
    /// `calibre:title_sort` and `calibre:series` are attributes, so a sort
    /// title with a line break in it came back changed – and a round trip
    /// through the folder would then alter a book nobody had edited.
    @Test("a line break inside an attribute is not turned into a space")
    func lineBreakInAttribute() throws {
        var book = Book(title: "Anything")
        book.titleSort = "First\nSecond\tTabbed"
        book.series = SeriesRef(name: "Wrapped\nSeries", index: 1)

        let text = OPFDocument.render(book)
        #expect(text.contains("&#10;"))
        #expect(text.contains("&#9;"))

        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")
        #expect(parsed.book.titleSort == "First\nSecond\tTabbed")
        #expect(parsed.book.series?.name == "Wrapped\nSeries")
    }

    /// And in element text: XML line-ending normalisation turns a literal CR
    /// into LF before the parser sees it, so a description pasted from a
    /// Windows tool came back with different bytes than it went in with.
    @Test("a carriage return in a description survives as a carriage return")
    func carriageReturnInText() throws {
        let book = Book(title: "Anything", description: "One\r\nTwo\rThree")
        let text = OPFDocument.render(book)
        #expect(text.contains("&#13;"))
        // Newlines stay newlines, so the file is still readable by eye.
        #expect(text.contains("\n"))

        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")
        #expect(parsed.book.description == "One\r\nTwo\rThree")
    }

    @Test("the OPF stays well-formed with everything awkward in it")
    func awkwardStaysWellFormed() throws {
        let text = OPFDocument.render(awkwardBook())
        // A parse that throws is a file no other tool can read either – the
        // return path to Calibre would be closed (CONCEPT §4).
        let root = try XMLTree.parse(Data(text.utf8))
        #expect(root.name == "package")
        #expect(root.descendants(named: "title").count == 1)
        #expect(root.descendants(named: "creator").count == 2)
        #expect(root.descendants(named: "subject").count == 3)
    }

    @Test("a second round trip of an awkward book is still a fixed point")
    func awkwardOutputIsStable() throws {
        let once = OPFDocument.render(awkwardBook())
        let parsed = try OPFDocument.read(Data(once.utf8), fallbackTitle: "x")
        #expect(OPFDocument.render(parsed.book) == once)
    }

    /// The injection case. A title that looks like markup has to arrive as
    /// *text*: if it landed as an element, a book could rename its own series
    /// or set a rating by being called the right thing.
    @Test("a value that looks like XML lands as text, not as an element")
    func valueThatLooksLikeMarkup() throws {
        let book = Book(
            title: "<meta name=\"calibre:rating\" content=\"10\"/>",
            description: "</dc:description><meta name=\"shelf:read\" content=\"true\"/>",
            tags: ["</dc:subject><dc:subject>injected"])

        let text = OPFDocument.render(book)
        let root = try XMLTree.parse(Data(text.utf8))

        // Not one meta has arrived that Shelf did not write itself.
        let metaNames = root.descendants(named: "meta").compactMap { $0.attribute("name") }
        #expect(!metaNames.contains("calibre:rating"))
        #expect(metaNames.filter { $0 == "shelf:read" }.count == 1)
        #expect(root.descendants(named: "subject").count == 1)

        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")
        #expect(parsed.book.title == book.title)
        #expect(parsed.book.description == book.description)
        #expect(parsed.book.tags == book.tags)
        // The rating and the read status are what the book says, not what the
        // title tried to say.
        #expect(parsed.book.rating == 0)
        #expect(!parsed.book.isRead)
    }

    @Test("a series index of 3.5 stays 3.5, and 3 does not become 3.0")
    func seriesIndexFormatting() throws {
        let half = OPFDocument.render(Book(title: "x", series: SeriesRef(name: "S", index: 3.5)))
        #expect(half.contains("content=\"3.5\""))
        let whole = OPFDocument.render(Book(title: "x", series: SeriesRef(name: "S", index: 3)))
        #expect(whole.contains("content=\"3\""))

        let parsed = try OPFDocument.read(Data(half.utf8), fallbackTitle: "x")
        #expect(parsed.book.series?.index == 3.5)
    }

    @Test("an unrated book writes no rating, and reads back as unrated")
    func noRating() throws {
        let text = OPFDocument.render(Book(title: "x", rating: 0))
        #expect(!text.contains("calibre:rating"))
        #expect(try OPFDocument.read(Data(text.utf8), fallbackTitle: "x").book.rating == 0)
    }

    /// Calibre's custom columns arrive as metas this version does not model.
    /// Writing them back is what keeps Sprint 3 from being a migration.
    @Test("metas Shelf does not understand are kept, not dropped")
    func unmappedMetas() throws {
        let original = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Kept</dc:title>
                <meta name="something:else" content="a value"/>
              </metadata>
            </package>
            """
        let parsed = try OPFDocument.read(Data(original.utf8), fallbackTitle: "x")
        #expect(parsed.unmappedMetas["something:else"] == "a value")

        let rewritten = OPFDocument.render(parsed.book, unmappedMetas: parsed.unmappedMetas)
        #expect(rewritten.contains("something:else"))
        let again = try OPFDocument.read(Data(rewritten.utf8), fallbackTitle: "x")
        #expect(again.unmappedMetas["something:else"] == "a value")
    }

    // MARK: EPUB 3

    @Test("EPUB 3's belongs-to-collection is read when Calibre's metas are absent")
    func epub3Series() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Ancillary Sword</dc:title>
                <meta property="belongs-to-collection" id="c1">Imperial Radch</meta>
                <meta refines="#c1" property="group-position">2</meta>
              </metadata>
            </package>
            """
        let parsed = try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x")
        #expect(parsed.book.series == SeriesRef(name: "Imperial Radch", index: 2))
    }

    @Test("Calibre's series wins over EPUB 3's, because an imported library is the case that must be right")
    func calibreSeriesWins() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>x</dc:title>
                <meta property="belongs-to-collection" id="c1">From EPUB 3</meta>
                <meta name="calibre:series" content="From Calibre"/>
              </metadata>
            </package>
            """
        #expect(try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x").book.series?.name == "From Calibre")
    }

    // MARK: Identifiers

    @Test("a bare 13-digit identifier with no scheme is recognised as an ISBN")
    func inferredISBN() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>x</dc:title>
                <dc:identifier>9780441478125</dc:identifier>
              </metadata>
            </package>
            """
        #expect(try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x").book.isbn == "9780441478125")
    }

    @Test("a urn:uuid identifier is the book's id")
    func urnUUID() throws {
        let id = UUID()
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>x</dc:title>
                <dc:identifier opf:scheme="uuid" xmlns:opf="http://www.idpf.org/2007/opf">
                  urn:uuid:\(id.uuidString)</dc:identifier>
              </metadata>
            </package>
            """
        #expect(try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x").book.id == id)
    }

    @Test("an ISBN with hyphens and a lower-case x is normalised for comparison")
    func isbnNormalisation() {
        #expect(Book(title: "x", identifiers: ["isbn": "0-306-40615-x"]).isbn == "030640615X")
        #expect(Book(title: "x", identifiers: ["isbn": "urn:isbn:9780441478125"]).isbn == "9780441478125")
        #expect(Book(title: "x").isbn == nil)
    }

    // MARK: Dates

    @Test("dc:date is read in every shape it turns up in")
    func dateParsing() {
        #expect(OPFDate.parse("2019-04-01") != nil)
        #expect(OPFDate.parse("2019-04") != nil)
        #expect(OPFDate.parse("2019") != nil)
        #expect(OPFDate.parse("2019-04-01T10:30:00+00:00") != nil)
        #expect(OPFDate.parse("") == nil)
        #expect(OPFDate.parse("not a date") == nil)
        // Calibre's placeholder for "unknown" must not become the year 101.
        #expect(OPFDate.parse("0101-01-01T00:00:00+00:00") == nil)
    }

    @Test("a date written and read again is the same day")
    func dateRoundTrip() {
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        guard let read = OPFDate.parse(OPFDate.render(date)) else {
            Issue.record("the rendered date did not parse")
            return
        }
        #expect(abs(read.timeIntervalSince(date)) < 1)
    }

    // MARK: Writing to disk

    /// Through a `.opf.part` that is renamed into place: a crash or a full disk
    /// then leaves either the old file or the new one, never half of either.
    @Test("the file is written atomically and leaves no .part behind")
    func atomicWrite() throws {
        let folder = try TemporaryFolder()
        let bookFolder = try folder.folder("Austen, Jane/Emma (3)")

        try OPFDocument.write(Book(title: "Emma", authors: ["Jane Austen"]), to: bookFolder)
        #expect(folder.names(in: "Austen, Jane/Emma (3)") == ["metadata.opf"])

        // Writing again replaces it, still with no leftovers.
        try OPFDocument.write(Book(title: "Emma, revised", authors: ["Jane Austen"]), to: bookFolder)
        #expect(folder.names(in: "Austen, Jane/Emma (3)") == ["metadata.opf"])

        let data = try Data(contentsOf: bookFolder.appendingPathComponent("metadata.opf"))
        #expect(try OPFDocument.read(data, fallbackTitle: "x").book.title == "Emma, revised")
    }

    @Test("an unreadable OPF is an error, not an empty book")
    func unreadable() {
        #expect(throws: (any Error).self) {
            try OPFDocument.read(Data("<package><unclosed>".utf8), fallbackTitle: "x")
        }
    }

    @Test("an OPF with no title falls back to the name given, never to nothing")
    func fallbackTitle() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"/>
            </package>
            """
        #expect(try OPFDocument.read(Data(opf.utf8), fallbackTitle: "From The File").book.title == "From The File")
    }

    @Test("a translator is not made into an author")
    func contributorsAreNotAuthors() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                        xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>Blindness</dc:title>
                <dc:creator opf:role="aut">José Saramago</dc:creator>
                <dc:creator opf:role="trl">Giovanni Pontiero</dc:creator>
              </metadata>
            </package>
            """
        #expect(try OPFDocument.read(Data(opf.utf8), fallbackTitle: "x").book.authors == ["José Saramago"])
    }
}

@Suite("Reading XML")
struct XMLTreeTests {

    @Test("namespace prefixes are matched by local name, however they are spelled")
    func namespaces() throws {
        let root = try XMLTree.parse("<p><dc:title>A</dc:title><DC:subject>B</DC:subject></p>")
        #expect(root.firstText(named: "title") == "A")
        #expect(root.firstText(named: "subject") == "B")
    }

    @Test("an undeclared prefix does not cost the document its content")
    func undeclaredPrefix() throws {
        // No xmlns:dc anywhere – strict namespace processing would refuse this,
        // and real EPUBs do it.
        let root = try XMLTree.parse("<package><metadata><dc:title>Still Read</dc:title></metadata></package>")
        #expect(root.firstText(named: "title") == "Still Read")
    }

    @Test("attributes are matched by local name too")
    func attributes() throws {
        let root = try XMLTree.parse("<p><i opf:scheme=\"uuid\" id=\"x\">v</i></p>")
        #expect(root.firstChild(named: "i")?.attribute("scheme") == "uuid")
        #expect(root.firstChild(named: "i")?.attribute("SCHEME") == "uuid")
    }

    @Test("a description in a CDATA block is text like any other")
    func cdata() throws {
        let root = try XMLTree.parse("<p><d><![CDATA[<b>bold</b> & free]]></d></p>")
        #expect(root.firstText(named: "d") == "<b>bold</b> & free")
    }

    @Test("entities are resolved")
    func entities() throws {
        let root = try XMLTree.parse("<p><t>Tom &amp; Jerry &lt;x&gt;</t></p>")
        #expect(root.firstText(named: "t") == "Tom & Jerry <x>")
    }

    @Test("descendants are found however deep, because OPFs disagree about their own shape")
    func descendants() throws {
        let root = try XMLTree.parse("<a><b><c><t>deep</t></c></b><t>shallow</t></a>")
        #expect(root.descendants(named: "t").count == 2)
    }

    @Test("text is trimmed, so an indented element is not full of whitespace")
    func trimming() throws {
        let root = try XMLTree.parse("<a>\n   <t>\n     value\n   </t>\n</a>")
        #expect(root.firstText(named: "t") == "value")
    }

    @Test("input that is not XML is an error")
    func notXML() {
        #expect(throws: (any Error).self) { try XMLTree.parse("<a><b></a>") }
        #expect(throws: (any Error).self) { try XMLTree.parse("") }
    }
}
