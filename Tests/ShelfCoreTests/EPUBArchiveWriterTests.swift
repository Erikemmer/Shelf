import Foundation
import Testing

@testable import ShelfCore

// `mach_task_basic_info`, for the one test here that measures resident
// memory. macOS only, the same reason `shelf-tool`'s `fileSystemName(of:)`
// is: an unconditional `import Darwin` breaks the Linux build this target
// also runs on.
#if canImport(Darwin)
    import Darwin
#endif

/// Proves `EPUBArchiveWriter` against the strictest form it is meant to
/// survive: read an archive, hand every entry straight back to the writer
/// unchanged, read the result a second time, and compare names and
/// decompressed bytes — not "opens again", but identical.
///
/// Every valid archive below is built with `EPUBArchiveWriter` itself, never
/// `ShelfFixtures.ZipWriter` — these tests exist to prove the production
/// writer, and a fixture built by a second implementation of the same format
/// would not prove anything about this one (`docs/adr/0021-…`).
///
/// This is Sprint 10's own proof, and only that: nothing here reads or
/// changes an OPF's fields, nothing here is called by the app, and nothing
/// here writes a real book file. It exists so the next step — changing a
/// book's own metadata in place — has an archive writer it can already trust
/// with the parts that are not the change itself.
@Suite("Writing EPUBs: the strict round trip")
struct EPUBArchiveWriterTests {

    // MARK: The round trip itself

    /// Reads `entries` as written, writes every entry straight back through
    /// `EPUBArchiveWriter`, reads the result a second time, and checks the
    /// two readings agree.
    private func assertStrictRoundTrip(_ entries: [ZipArchiveWriter.Entry]) throws {
        let first = try ZipReader(data: try EPUBArchiveWriter.archive(entries))
        let rewritten = try EPUBArchiveWriter.entries(rewriting: first)
        let second = try ZipReader(data: try EPUBArchiveWriter.archive(rewritten))

        #expect(second.entries.map(\.path) == first.entries.map(\.path))
        for entry in first.files {
            #expect(
                try second.data(at: entry.path) == (try first.data(at: entry.path)),
                "payload differs at \(entry.path)")
        }
    }

    // MARK: The nine (ten) shapes

    @Test("EPUB 2 – opf:role authorship, round-trips exactly")
    func epub2RoundTrip() throws {
        try assertStrictRoundTrip(Self.epub2())
    }

    @Test("EPUB 3 – refined roles and dcterms:modified, round-trips exactly")
    func epub3RoundTrip() throws {
        try assertStrictRoundTrip(Self.epub3())
    }

    @Test("a book with no cover at all round-trips exactly")
    func noCoverRoundTrip() throws {
        try assertStrictRoundTrip(Self.noCover())
    }

    /// The manifest naming a file that is not in the archive is a metadata
    /// problem for whoever reads the OPF (`EPUBMetadata` already copes with
    /// it); it is not a reason for the *archive* to be unreadable, and the
    /// writer must not need every reference to resolve to round-trip it.
    @Test("an OPF naming a cover the archive does not have round-trips exactly")
    func missingCoverFileRoundTrip() throws {
        try assertStrictRoundTrip(Self.coverReferencedButMissing())
    }

    @Test("an OPF that does not live in OEBPS round-trips exactly")
    func opfInSubfolderRoundTrip() throws {
        try assertStrictRoundTrip(Self.opfInSubfolder())
    }

    @Test("deep paths and non-ASCII names – an umlaut and a Cyrillic name – round-trip exactly")
    func deepNonASCIIRoundTrip() throws {
        try assertStrictRoundTrip(Self.deepNonASCIIPaths())
    }

    /// `ZipArchiveWriter` has exactly one mode – stored – so this is not a
    /// special case to construct: it is what every fixture in this file
    /// already is. Named and asserted directly anyway, because the
    /// requirement was named directly.
    @Test("an entry that arrives already stored round-trips exactly, which is every entry here")
    func alreadyStoredRoundTrip() throws {
        let entries = Self.epub2()
        let archive = try ZipReader(data: try EPUBArchiveWriter.archive(entries))
        #expect(archive.entries.allSatisfy { $0.method == .stored })
        try assertStrictRoundTrip(entries)
    }

    @Test("a file the manifest never mentions still round-trips exactly")
    func unmanifestedFileRoundTrip() throws {
        try assertStrictRoundTrip(Self.withUnmanifestedFile())
    }

    /// Announced, not zip-encrypted – the same distinction `EPUBMetadata`
    /// and `DRMProbe` already read this file for (CONCEPT §12). The writer
    /// has no reason to treat it specially, and this proves it does not:
    /// the file passes through like any other entry.
    @Test("META-INF/encryption.xml – an EPUB announcing DRM – round-trips exactly")
    func drmAnnouncementRoundTrip() throws {
        try assertStrictRoundTrip(Self.withDRMAnnouncement())
    }

    // MARK: mimetype, first or refused

    @Test("mimetype missing entirely is refused")
    func missingMimetype() {
        #expect(throws: EPUBArchiveWriter.Failure.mimetypeMustBeFirst) {
            try EPUBArchiveWriter.archive([.init(path: "a.txt", text: "x")])
        }
    }

    @Test("mimetype present but not first is refused")
    func mimetypeNotFirst() {
        #expect(throws: EPUBArchiveWriter.Failure.mimetypeMustBeFirst) {
            try EPUBArchiveWriter.archive([.init(path: "a.txt", text: "x"), Self.mimetype])
        }
    }

    @Test("mimetype appearing twice is refused")
    func duplicateMimetype() {
        #expect(throws: EPUBArchiveWriter.Failure.duplicateMimetype) {
            try EPUBArchiveWriter.archive([Self.mimetype, Self.mimetype])
        }
    }

    @Test("an empty entry list has no mimetype, and is refused the same way as a missing one")
    func emptyIsRefused() {
        #expect(throws: EPUBArchiveWriter.Failure.mimetypeMustBeFirst) {
            try EPUBArchiveWriter.archive([])
        }
    }

    // MARK: Encrypted entries

    @Test("a ZIP-encrypted entry is refused when copying an archive forward, named")
    func encryptedEntryRefused() throws {
        var data = try EPUBArchiveWriter.archive(Self.epub2())
        guard let offset = Self.centralDirectoryRecordOffset(of: "OEBPS/cover.jpg", in: data) else {
            Issue.record("no central directory entry for OEBPS/cover.jpg in the written archive")
            return
        }
        data[offset + 8] |= 0x01  // general-purpose bit 0: encrypted

        let archive = try ZipReader(data: data)
        #expect(archive.entry(at: "OEBPS/cover.jpg")?.isEncrypted == true)
        #expect(throws: EPUBArchiveWriter.Failure.encryptedEntry("OEBPS/cover.jpg")) {
            try EPUBArchiveWriter.entries(rewriting: archive)
        }
    }

    /// Finds a central directory record's own offset, by name, the same way
    /// `ZipReaderTests` finds a signature to tamper with – except this walks
    /// every record rather than the last occurrence, because the name it is
    /// looking for is not necessarily unique across the whole byte stream.
    private static func centralDirectoryRecordOffset(of path: String, in data: Data) -> Int? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let nameBytes = Array(path.utf8)
        var index = 0
        while index + 46 <= bytes.count {
            guard Array(bytes[index..<(index + 4)]) == signature else {
                index += 1
                continue
            }
            let nameLength = Int(bytes[index + 28]) | (Int(bytes[index + 29]) << 8)
            let extraLength = Int(bytes[index + 30]) | (Int(bytes[index + 31]) << 8)
            let commentLength = Int(bytes[index + 32]) | (Int(bytes[index + 33]) << 8)
            let nameStart = index + 46
            if nameStart + nameLength <= bytes.count,
                Array(bytes[nameStart..<(nameStart + nameLength)]) == nameBytes
            {
                return index
            }
            index = nameStart + nameLength + extraLength + commentLength
        }
        return nil
    }

    // MARK: The 60 MB entry

    /// Not a claim about performance, a measurement of it: `ZipReader` holds
    /// the whole archive as `[UInt8]`, and this is where that assumption
    /// either costs nothing worth naming or costs something worth writing
    /// down (`docs/BACKLOG.md` if it is the latter).
    @Test("a ~60 MB entry round-trips exactly, and the cost of it is measured rather than assumed")
    func largeEntryMeasured() throws {
        let size = 60_000_000
        var payload = Data(count: size)
        payload.withUnsafeMutableBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self)
            for index in 0..<size { base[index] = UInt8(truncatingIfNeeded: index) }
        }
        let entries = Self.epub2() + [ZipArchiveWriter.Entry(path: "OEBPS/video.bin", data: payload)]

        let before = Self.residentMemoryBytes()
        let start = ContinuousClock.now
        try assertStrictRoundTrip(entries)
        let elapsed = ContinuousClock.now - start
        let after = Self.residentMemoryBytes()

        print("EPUBArchiveWriter strict round trip, ~60 MB entry: \(elapsed)")
        if let before, let after {
            let deltaMB = Double(after - before) / 1_000_000
            print(
                "resident memory: +\(String(format: "%.1f", deltaMB)) MB "
                    + "(from \(before / 1_000_000) MB to \(after / 1_000_000) MB)")
        } else {
            print("resident memory: not measured on this platform")
        }
        #expect(elapsed < .seconds(10), "a 60 MB round trip took \(elapsed) – worth a look before this ships")
    }

    /// Resident memory of this process, in bytes. macOS only, the same
    /// reason `shelf-tool`'s `fileSystemName(of:)` is Darwin-only: Linux CI
    /// still proves correctness and timing here, just not this one number.
    private static func residentMemoryBytes() -> Int? {
        #if canImport(Darwin)
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int(info.resident_size) : nil
        #else
            return nil
        #endif
    }

    // MARK: Fixtures, built through the writer under test

    private static let mimetype = ZipArchiveWriter.Entry(path: "mimetype", text: "application/epub+zip")

    private static func container(opfPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    static func epub2() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>An EPUB 2 Book</dc:title>
                <dc:creator opf:role="aut" opf:file-as="Author, Ann">Ann Author</dc:creator>
                <dc:identifier id="uuid_id" opf:scheme="uuid">11111111-1111-1111-1111-111111111111</dc:identifier>
                <meta name="cover" content="cover-image"/>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .init(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .init(path: "OEBPS/content.opf", text: opf),
            .init(path: "OEBPS/text.xhtml", text: "<html><body><p>An EPUB 2 book.</p></body></html>"),
            .init(path: "OEBPS/cover.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])),
        ]
    }

    static func epub3() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>An EPUB 3 Book</dc:title>
                <dc:creator id="creator">Bea Bookwright</dc:creator>
                <meta refines="#creator" property="role" scheme="marc:relators">aut</meta>
                <dc:identifier id="uuid_id">urn:uuid:22222222-2222-2222-2222-222222222222</dc:identifier>
                <meta property="dcterms:modified">2026-09-21T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .init(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .init(path: "OEBPS/content.opf", text: opf),
            .init(path: "OEBPS/text.xhtml", text: "<html><body><p>An EPUB 3 book.</p></body></html>"),
            .init(path: "OEBPS/cover.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2])),
        ]
    }

    static func noCover() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>No Cover At All</dc:title>
                <dc:identifier id="uuid_id" opf:scheme="uuid">33333333-3333-3333-3333-333333333333</dc:identifier>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .init(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .init(path: "OEBPS/content.opf", text: opf),
            .init(path: "OEBPS/text.xhtml", text: "<html><body><p>No cover.</p></body></html>"),
        ]
    }

    /// Same OPF as `epub2()`, but the manifest's cover item resolves to
    /// nothing – `OEBPS/cover.jpg` is simply never written.
    static func coverReferencedButMissing() -> [ZipArchiveWriter.Entry] {
        Self.epub2().filter { $0.path != "OEBPS/cover.jpg" }
    }

    static func opfInSubfolder() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>The OPF Lives Elsewhere</dc:title>
                <dc:identifier id="uuid_id" opf:scheme="uuid">44444444-4444-4444-4444-444444444444</dc:identifier>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .init(path: "META-INF/container.xml", text: container(opfPath: "content/package.opf")),
            .init(path: "content/package.opf", text: opf),
            .init(path: "content/text.xhtml", text: "<html><body><p>Not in OEBPS.</p></body></html>"),
        ]
    }

    /// A chapter title with an umlaut, a folder named after it, and a cover
    /// whose file name is Cyrillic – both nested several folders deep.
    static func deepNonASCIIPaths() -> [ZipArchiveWriter.Entry] {
        let chapterPath = "OEBPS/Text/Kapitel Eins/Über die Königin.xhtml"
        let coverPath = "OEBPS/Bilder/Обложка/глава.jpg"
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>Über die Königin</dc:title>
                <dc:identifier id="uuid_id" opf:scheme="uuid">55555555-5555-5555-5555-555555555555</dc:identifier>
                <meta name="cover" content="cover-image"/>
              </metadata>
              <manifest>
                <item id="text" href="Text/Kapitel Eins/Über die Königin.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="Bilder/Обложка/глава.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .init(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .init(path: "OEBPS/content.opf", text: opf),
            .init(path: chapterPath, text: "<html><body><p>Über die Königin.</p></body></html>"),
            .init(path: coverPath, data: Data([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7])),
        ]
    }

    static func withUnmanifestedFile() -> [ZipArchiveWriter.Entry] {
        Self.epub2() + [ZipArchiveWriter.Entry(path: "OEBPS/notes-nobody-declared.txt", text: "leftover notes")]
    }

    static func withDRMAnnouncement() -> [ZipArchiveWriter.Entry] {
        // What a real ADEPT-protected EPUB carries – only its *presence* is
        // ever read (`EPUBMetadata.encryptionPath`, `DRMProbe`), so an
        // announcement rather than a real encryption is enough here too, and
        // is the only kind of "protected" content this repository ever holds
        // (CONCEPT §12).
        let encryption = """
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
                <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
                <CipherData><CipherReference URI="OEBPS/text.xhtml"/></CipherData>
              </EncryptedData>
            </encryption>
            """
        return Self.epub2() + [ZipArchiveWriter.Entry(path: "META-INF/encryption.xml", text: encryption)]
    }
}
