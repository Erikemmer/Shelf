import Foundation
import Testing

@testable import ShelfCore

/// The five traps a naive "replace the metadata" implementation falls
/// into, named before any of this was built, each with its own test here.
/// The sharper proof — that a metadata change touches exactly one entry of
/// the archive, and every other entry is bit-identical — is at the bottom.
///
/// Synthetic only: the same claims, proven against six real Gutenberg
/// books rather than fixtures this project wrote, are
/// `shelf-tool epub-metadata-patch`, run from `Scripts/real-epub-proof.sh`
/// and its own Python cross-check — real books cannot live in this test
/// bundle (`CLAUDE.md`: no borrowed book goes into this repository, and a
/// public-domain download is no exception).
@Suite("Patching an EPUB's own content.opf")
struct EPUBOPFPatchTests {

    // MARK: Trap 1 — the unique-identifier anchor

    /// `<package unique-identifier="uuid_id">` names, by `id`, exactly which
    /// `<dc:identifier>` is the package's own identity. Losing that
    /// reference makes the package invalid.
    @Test("the identifier unique-identifier points to survives untouched, even when other identifiers change")
    func anchorIdentifierSurvives() throws {
        // The fixture's own base identifier, `id="id"`, is what
        // `unique-identifier="id"` already names as the anchor — the one
        // this test must find unchanged.
        let opf = Self.opf(extraMetadata: #"<dc:identifier opf:scheme="isbn">9780000000000</dc:identifier>"#)
        let patched = try EPUBOPFPatch.apply(.init(identifiers: ["isbn": "9781111111111"]), to: opf)

        let root = try XMLTree.parse(patched)
        #expect(root.attribute("unique-identifier") == "id")
        let identifiers = root.descendants(named: "identifier")
        let anchor = identifiers.first { $0.attribute("id") == "id" }
        #expect(anchor?.text == "urn:uuid:11111111-1111-1111-1111-111111111111")
        let isbn = identifiers.first { $0.attribute("scheme")?.lowercased() == "isbn" }
        #expect(isbn?.text == "9781111111111")
    }

    @Test("an identifier scheme Shelf has no value for is left exactly as it was")
    func unmentionedIdentifierUntouched() throws {
        let opf = Self.opf(extraMetadata: #"<dc:identifier opf:scheme="isbn">9780000000000</dc:identifier>"#)
        let patched = try EPUBOPFPatch.apply(.init(identifiers: ["asin": "B000000000"]), to: opf)
        #expect(patched == opf)
    }

    // MARK: Trap 2 — an author's id, EPUB 2 and EPUB 3

    @Test("EPUB 2: opf:file-as and opf:role survive a replaced author name, exactly as they were")
    func epub2AuthorAttributesSurvive() throws {
        let opf = Self.opf(
            extraMetadata: """
                <dc:creator opf:file-as="Doe, Jane" opf:role="aut">Jane Doe</dc:creator>
                """)
        let patched = try EPUBOPFPatch.apply(.init(authors: ["Jane Smith"]), to: opf)

        let root = try XMLTree.parse(patched)
        let creator = try #require(root.descendants(named: "creator").first)
        #expect(creator.text == "Jane Smith")
        #expect(creator.attribute("file-as") == "Doe, Jane")
        #expect(creator.attribute("role") == "aut")
    }

    /// EPUB 3 keeps the role and the sort form beside the creator, each
    /// pointing back at it by `id`. Losing that `id` when the name changes
    /// leaves both `refines` pointing at nothing.
    @Test("EPUB 3: a creator's id survives a replaced name, so refines still resolves")
    func epub3AuthorIDSurvives() throws {
        let opf = Self.opf(
            extraMetadata: """
                <dc:creator id="creator1">Jane Doe</dc:creator>
                <meta refines="#creator1" property="file-as">Doe, Jane</meta>
                <meta refines="#creator1" property="role" scheme="marc:relators">aut</meta>
                """)
        let patched = try EPUBOPFPatch.apply(.init(authors: ["Jane Smith"]), to: opf)

        let root = try XMLTree.parse(patched)
        let creator = try #require(root.descendants(named: "creator").first)
        #expect(creator.text == "Jane Smith")
        #expect(creator.attribute("id") == "creator1")
        let refinesTargets = root.descendants(named: "meta").compactMap { $0.attribute("refines") }
        #expect(refinesTargets == ["#creator1", "#creator1"])
    }

    @Test("two EPUB 2 authors are replaced positionally, in document order")
    func twoAuthorsReplaced() throws {
        let opf = Self.opf(
            extraMetadata: """
                <dc:creator opf:file-as="Grimm, Jacob">Jacob Grimm</dc:creator>
                <dc:creator opf:file-as="Grimm, Wilhelm">Wilhelm Grimm</dc:creator>
                """)
        let patched = try EPUBOPFPatch.apply(.init(authors: ["Author One", "Author Two"]), to: opf)
        let root = try XMLTree.parse(patched)
        #expect(root.descendants(named: "creator").map(\.text) == ["Author One", "Author Two"])
    }

    // MARK: Trap 3 — dcterms:modified

    @Test("EPUB 3: dcterms:modified is set to now when something else changes")
    func dctermsModifiedUpdated() throws {
        let opf = Self.opf(
            extraMetadata: """
                <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
                """)
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 21
        components.hour = 12
        components.minute = 30
        components.second = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: components)!

        let patched = try EPUBOPFPatch.apply(.init(title: "New Title"), to: opf, now: now)
        let root = try XMLTree.parse(patched)
        let modified = root.descendants(named: "meta").first {
            $0.attribute("property")?.lowercased() == "dcterms:modified"
        }
        #expect(modified?.text == "2026-09-21T12:30:15Z")
    }

    @Test("dcterms:modified is not touched when nothing else changed")
    func dctermsModifiedUntouchedWhenNoOtherChange() throws {
        let opf = Self.opf(
            extraMetadata: """
                <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
                """)
        let patched = try EPUBOPFPatch.apply(.init(), to: opf, now: Date())
        #expect(patched == opf)
    }

    @Test("EPUB 2 with no dcterms:modified never gets one invented")
    func dctermsModifiedNeverInvented() throws {
        let opf = Self.opf()
        let patched = try EPUBOPFPatch.apply(.init(title: "New Title"), to: opf, now: Date())
        #expect(!patched.lowercased().contains("dcterms:modified"))
    }

    // MARK: Trap 4 — the cover

    @Test("EPUB 2's meta name=cover survives a metadata change untouched")
    func epub2CoverMetaSurvives() throws {
        let opf = Self.opf(
            extraMetadata: """
                <meta name="cover" content="cover-image"/>
                """)
        let patched = try EPUBOPFPatch.apply(.init(title: "New Title", publisher: "New Publisher"), to: opf)
        #expect(patched.contains(#"<meta name="cover" content="cover-image"/>"#))
    }

    @Test("EPUB 3's manifest cover-image property survives a metadata change untouched")
    func epub3CoverManifestItemSurvives() throws {
        let coverItem = #"<item id="cover-image" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#
        let opf = Self.opf(manifestExtra: coverItem)
        let patched = try EPUBOPFPatch.apply(.init(title: "New Title"), to: opf)
        #expect(patched.contains(coverItem))
    }

    // MARK: Trap 5 — xml:lang and namespace prefixes

    @Test("the package's own xml:lang survives a metadata change untouched")
    func packageXMLLangSurvives() throws {
        let opf = Self.opf(packageAttributes: #" xml:lang="en""#)
        let patched = try EPUBOPFPatch.apply(.init(title: "New Title"), to: opf)
        #expect(patched.contains(#"xml:lang="en""#))
        #expect(try XMLTree.parse(patched).attribute("lang") == "en")
    }

    /// One file writing `<title>` under a default namespace and `<dc:creator>`
    /// with a prefix, in the same document – both spellings the reader
    /// already tolerates (`XMLTree` matches by local name), and both must
    /// come back exactly as written except for the one word that changed.
    @Test("a default-namespace title and a prefixed creator both keep their own tag exactly as written")
    func mixedPrefixesSurvive() throws {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" \
            xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
              <metadata>
                <dc:identifier id="id">urn:uuid:11111111-1111-1111-1111-111111111111</dc:identifier>
                <title>Old Title</title>
                <dc:creator opf:file-as="Doe, Jane">Jane Doe</dc:creator>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        let patched = try EPUBOPFPatch.apply(.init(title: "New Title"), to: opf)
        #expect(patched.contains("<title>New Title</title>"))
        #expect(patched.contains(#"<dc:creator opf:file-as="Doe, Jane">Jane Doe</dc:creator>"#))
    }

    // MARK: Never invents

    @Test("a description this book never had is never invented")
    func descriptionNeverInvented() throws {
        let opf = Self.opf()
        let patched = try EPUBOPFPatch.apply(.init(description: "A new description"), to: opf)
        #expect(try XMLTree.parse(patched).descendants(named: "description").isEmpty)
    }

    // MARK: Refusals

    @Test("a different number of authors than the file has creators for is refused, named")
    func authorCountMismatchRefused() throws {
        let opf = Self.opf(extraMetadata: #"<dc:creator opf:file-as="Doe, Jane">Jane Doe</dc:creator>"#)
        #expect(throws: EPUBOPFPatch.Failure.authorCountMismatch(existing: 1, new: 2)) {
            try EPUBOPFPatch.apply(.init(authors: ["A", "B"]), to: opf)
        }
    }

    @Test("a creator whose role is not author is refused, named, rather than overwritten")
    func nonAuthorCreatorRefused() throws {
        let opf = Self.opf(extraMetadata: #"<dc:creator opf:role="edt">Jane Editor</dc:creator>"#)
        #expect(throws: EPUBOPFPatch.Failure.creatorRoleNotSupported("edt")) {
            try EPUBOPFPatch.apply(.init(authors: ["Someone Else"]), to: opf)
        }
    }

    @Test("mixed spelling of the same local name is refused rather than guessed at")
    func mixedSpellingRefused() throws {
        let opf = Self.opf(
            extraMetadata: """
                <dc:creator opf:file-as="Doe, Jane">Jane Doe</dc:creator>
                <Creator opf:file-as="Roe, Jan">Jan Roe</Creator>
                """)
        #expect(throws: EPUBOPFPatch.Failure.ambiguousElementSpelling("creator")) {
            try EPUBOPFPatch.apply(.init(authors: ["A", "B"]), to: opf)
        }
    }

    // MARK: DRM, refused in the core

    @Test("a DRM-protected archive is refused before the OPF is even read")
    func drmProtectedArchiveRefused() throws {
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(path: "META-INF/container.xml", text: Self.container),
            .raw(path: "META-INF/encryption.xml", text: "<encryption/>"),
            .raw(path: "OEBPS/content.opf", text: Self.opf()),
        ]
        let archive = try ZipReader(data: try EPUBArchiveWriter.archive(entries))
        #expect(throws: EPUBOPFPatch.Failure.drmProtected) {
            try EPUBOPFPatch.entries(patching: .init(title: "New Title"), in: archive)
        }
    }

    // MARK: The sharper proof — exactly one entry differs

    /// Because entries pass through as `.passthrough`, this can now claim
    /// something the old always-stored writer could not: after a metadata
    /// change, exactly *one* entry of the archive differs – the OPF – and
    /// every other entry is bit-identical, in the same order, with the same
    /// headers.
    @Test("a metadata change touches exactly one entry: the OPF")
    func exactlyOneEntryDiffers() throws {
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(path: "META-INF/container.xml", text: Self.container),
            .raw(path: "OEBPS/content.opf", text: Self.opf()),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>Some text.</p></body></html>"),
            .raw(path: "OEBPS/cover.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])),
        ]
        let before = try EPUBArchiveWriter.archive(entries)
        let original = try ZipReader(data: before)

        let patched = try EPUBOPFPatch.entries(patching: .init(title: "A New Title"), in: original, now: Date())
        let after = try EPUBArchiveWriter.archive(patched)
        let result = try ZipReader(data: after)

        #expect(result.entries.map(\.path) == original.entries.map(\.path))

        var differing: [String] = []
        for entry in original.files {
            guard let resultEntry = result.entry(at: entry.path) else { continue }
            let originalPayload = try original.compressedData(for: entry)
            let resultPayload = try result.compressedData(for: resultEntry)
            let same =
                entry.method == resultEntry.method && entry.crc32 == resultEntry.crc32
                && entry.uncompressedSize == resultEntry.uncompressedSize && originalPayload == resultPayload
            if !same { differing.append(entry.path) }
        }
        #expect(differing == ["OEBPS/content.opf"])

        let read = EPUBMetadata.read(result, fallbackTitle: "ignored")
        #expect(read.book.title == "A New Title")
    }

    // MARK: Fixtures

    static let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    /// A minimal, valid OPF, close to the shape the six real Gutenberg
    /// books share: `dc:identifier id="id"` as the anchor, a title, a
    /// language, a publisher, a date, a manifest and a spine — plus
    /// whatever a test needs to add for its own trap.
    static func opf(
        packageAttributes: String = "", extraMetadata: String = "", manifestExtra: String = ""
    ) -> String {
        """
        <?xml version='1.0' encoding='utf-8'?>
        <package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"\(packageAttributes)>
          <metadata>
            <dc:identifier id="id">urn:uuid:11111111-1111-1111-1111-111111111111</dc:identifier>
            <dc:title>Old Title</dc:title>
            <dc:language>en</dc:language>
            <dc:publisher>Old Publisher</dc:publisher>
            <dc:date>2000-01-01</dc:date>
        \(extraMetadata.isEmpty ? "" : "    " + extraMetadata + "\n")\
          </metadata>
          <manifest>
            <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
        \(manifestExtra.isEmpty ? "" : "    " + manifestExtra + "\n")\
          </manifest>
          <spine><itemref idref="text"/></spine>
        </package>
        """
    }
}
