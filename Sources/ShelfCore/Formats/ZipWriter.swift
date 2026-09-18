import Foundation

/// Writes a ZIP archive with uncompressed entries.
///
/// **What this is for.** Shelf never writes a book file (CONCEPT §1), so no
/// part of the app calls this. It exists because the EPUB reader has to be
/// tested against EPUBs, and the only EPUBs this project will ever have are the
/// ones it makes itself – no borrowed books in the repo. The tests build their
/// fixtures with it, and `shelf-tool synthesise` builds the 5 000-book library
/// the performance run measures against.
///
/// Stored, not deflated: a compressor would be a second algorithm to get right
/// for no gain, and `mimetype` has to be stored anyway. The reader's DEFLATE
/// path is covered instead by reference streams from zlib, checked in as test
/// vectors – see `Tests/ShelfCoreTests/InflateTests.swift`.
public struct ZipWriter: Sendable {
    public struct Item: Sendable {
        public var path: String
        public var data: Data

        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }

        public init(path: String, text: String) {
            self.init(path: path, data: Data(text.utf8))
        }
    }

    public init() {}

    /// The archive's bytes.
    ///
    /// The items keep the order they are given, which for an EPUB matters:
    /// `mimetype` must be the first entry.
    public func archive(_ items: [Item]) -> Data {
        var output = Data()
        var directory = Data()
        var count = 0

        for item in items {
            let name = Data(item.path.utf8)
            let crc = CRC32.of(item.data)
            let offset = output.count

            output.append(Self.localHeaderSignature)
            output.append(uint16(20))  // version needed: 2.0
            output.append(uint16(0))  // flags: none; the name is ASCII here
            output.append(uint16(0))  // method: stored
            output.append(uint16(0))  // modification time
            output.append(uint16(0))  // modification date
            output.append(uint32(crc))
            output.append(uint32(UInt32(item.data.count)))
            output.append(uint32(UInt32(item.data.count)))
            output.append(uint16(UInt16(name.count)))
            output.append(uint16(0))  // extra field length
            output.append(name)
            output.append(item.data)

            directory.append(Self.directorySignature)
            directory.append(uint16(20))  // version made by
            directory.append(uint16(20))  // version needed
            directory.append(uint16(0))  // flags
            directory.append(uint16(0))  // method: stored
            directory.append(uint16(0))
            directory.append(uint16(0))
            directory.append(uint32(crc))
            directory.append(uint32(UInt32(item.data.count)))
            directory.append(uint32(UInt32(item.data.count)))
            directory.append(uint16(UInt16(name.count)))
            directory.append(uint16(0))  // extra
            directory.append(uint16(0))  // comment
            directory.append(uint16(0))  // disk number
            directory.append(uint16(0))  // internal attributes
            directory.append(uint32(0))  // external attributes
            directory.append(uint32(UInt32(offset)))
            directory.append(name)
            count += 1
        }

        let directoryOffset = output.count
        output.append(directory)
        output.append(Self.endSignature)
        output.append(uint16(0))  // this disk
        output.append(uint16(0))  // disk with the directory
        output.append(uint16(UInt16(count)))
        output.append(uint16(UInt16(count)))
        output.append(uint32(UInt32(directory.count)))
        output.append(uint32(UInt32(directoryOffset)))
        output.append(uint16(0))  // comment length
        return output
    }

    private static let localHeaderSignature = Data([0x50, 0x4B, 0x03, 0x04])
    private static let directorySignature = Data([0x50, 0x4B, 0x01, 0x02])
    private static let endSignature = Data([0x50, 0x4B, 0x05, 0x06])

    private func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}

/// CRC-32 as ZIP uses it.
///
/// Every reader checks this, so a fixture with a wrong one would be rejected by
/// everything except the code under test – which is the worst kind of test
/// fixture. The table is generated once rather than written out: it is derived
/// data, and 256 magic numbers in a source file are 256 chances to typo.
public enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    public static func of(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Builds a minimal but valid EPUB.
///
/// Same purpose as `ZipWriter`: test fixtures and the synthetic library. What
/// it writes is deliberately what a real EPUB has and no more – `mimetype`,
/// `META-INF/container.xml`, an OPF with Dublin Core and Calibre's series
/// metas, one XHTML page, and a cover image – so that a reader which copes
/// with this copes with the shape of the format, and the parts it does *not*
/// write (nested folders, percent-encoded hrefs, an EPUB 3 collection) are
/// added by individual tests that care about them.
public struct SyntheticEPUB: Sendable {
    public var book: Book
    /// The cover's bytes. A real image when the caller has one; any bytes will
    /// do for a test that only checks the cover was found.
    public var cover: Data?
    /// Its name inside the archive. Named after what the bytes actually are, so
    /// the fixture does not quietly declare a JPEG and store a PNG – a real
    /// EPUB failing exactly that way is a case for its own test, not a property
    /// of every fixture.
    public var coverName: String

    public init(book: Book, cover: Data? = nil, coverName: String? = nil) {
        self.book = book
        self.cover = cover
        self.coverName = coverName ?? cover.map(CoverFile.name(for:)) ?? "cover.jpg"
    }

    /// The media type the manifest declares for the cover, from the same bytes.
    var coverMediaType: String {
        let ext = (coverName as NSString).pathExtension.lowercased()
        return ext == "jpg" ? "image/jpeg" : "image/\(ext)"
    }

    /// Writes `META-INF/encryption.xml`, which is how an EPUB **announces**
    /// Adobe DRM.
    ///
    /// Announced and not encrypted: the text stays readable. Shelf's whole
    /// claim about DRM is that it sees this file, badges the book and stops, so
    /// a fixture that were really encrypted would test nothing further — and a
    /// repository holding real encrypted material is a thing this project does
    /// not want (CONCEPT §12, ADR 0012).
    public var announcesAdobeDRM = false

    /// An EPUB that says it is protected. The bytes inside are ordinary.
    public static func withAdobeDRM(book: Book, cover: Data? = nil) -> SyntheticEPUB {
        var epub = SyntheticEPUB(book: book, cover: cover)
        epub.announcesAdobeDRM = true
        return epub
    }

    /// What a real ADEPT-protected EPUB carries at `META-INF/encryption.xml`:
    /// one `EncryptedData` element per protected file. Only its *presence* is
    /// read (`EPUBMetadata.encryptionPath`).
    static let encryption = """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
            <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <CipherData><CipherReference URI="OEBPS/text.xhtml"/></CipherData>
          </EncryptedData>
        </encryption>
        """

    public func data() -> Data {
        var items: [ZipWriter.Item] = [
            // First entry, stored, no extra field – what the standard demands.
            ZipWriter.Item(path: "mimetype", text: "application/epub+zip"),
            ZipWriter.Item(path: "META-INF/container.xml", text: Self.container),
            ZipWriter.Item(path: "OEBPS/content.opf", text: opf()),
            ZipWriter.Item(path: "OEBPS/text.xhtml", text: page()),
        ]
        if announcesAdobeDRM {
            items.append(ZipWriter.Item(path: EPUBMetadata.encryptionPath, text: Self.encryption))
        }
        if let cover {
            items.append(ZipWriter.Item(path: "OEBPS/\(coverName)", data: cover))
        }
        return ZipWriter().archive(items)
    }

    static let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    /// The OPF, written the way Calibre writes one, plus the manifest that a
    /// cover has to be declared in.
    func opf() -> String {
        var lines: [String] = []
        lines.append("<?xml version='1.0' encoding='utf-8'?>")
        lines.append(
            "<package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"uuid_id\" version=\"2.0\">")
        lines.append(
            "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
                + "xmlns:opf=\"http://www.idpf.org/2007/opf\">")
        lines.append("    <dc:title>\(OPFDocument.escaped(book.title))</dc:title>")
        for author in book.authors {
            lines.append(
                "    <dc:creator opf:role=\"aut\" opf:file-as=\"\(OPFDocument.escaped(AuthorSort.of(author)))\">"
                    + "\(OPFDocument.escaped(author))</dc:creator>")
        }
        lines.append("    <dc:language>\(book.language ?? "en")</dc:language>")
        if let publisher = book.publisher {
            lines.append("    <dc:publisher>\(OPFDocument.escaped(publisher))</dc:publisher>")
        }
        if let description = book.description {
            lines.append("    <dc:description>\(OPFDocument.escaped(description))</dc:description>")
        }
        lines.append("    <dc:identifier id=\"uuid_id\" opf:scheme=\"uuid\">\(book.id.uuidString)</dc:identifier>")
        for (scheme, value) in book.identifiers.sorted(by: { $0.key < $1.key }) {
            lines.append(
                "    <dc:identifier opf:scheme=\"\(scheme.uppercased())\">"
                    + "\(OPFDocument.escaped(value))</dc:identifier>")
        }
        for tag in book.tags {
            lines.append("    <dc:subject>\(OPFDocument.escaped(tag))</dc:subject>")
        }
        if let series = book.series {
            lines.append("    <meta name=\"calibre:series\" content=\"\(OPFDocument.escaped(series.name))\"/>")
            if let index = series.index {
                lines.append("    <meta name=\"calibre:series_index\" content=\"\(index)\"/>")
            }
        }
        if cover != nil {
            lines.append("    <meta name=\"cover\" content=\"cover-image\"/>")
        }
        lines.append("  </metadata>")
        lines.append("  <manifest>")
        lines.append("    <item id=\"text\" href=\"text.xhtml\" media-type=\"application/xhtml+xml\"/>")
        if cover != nil {
            lines.append(
                "    <item id=\"cover-image\" href=\"\(coverName)\" media-type=\"\(coverMediaType)\" "
                    + "properties=\"cover-image\"/>")
        }
        lines.append("  </manifest>")
        lines.append("  <spine><itemref idref=\"text\"/></spine>")
        lines.append("</package>")
        return lines.joined(separator: "\n") + "\n"
    }

    func page() -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>\(OPFDocument.escaped(book.title))</title></head>
          <body><h1>\(OPFDocument.escaped(book.title))</h1><p>Synthetic test content.</p></body>
        </html>
        """
    }
}
