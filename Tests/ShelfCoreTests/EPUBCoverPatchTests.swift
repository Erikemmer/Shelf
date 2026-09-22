import Foundation
import Testing

@testable import ShelfCore

/// Writing a cover into an EPUB's own archive — the second half of
/// `docs/adr/0021-…`'s promise, `EPUBOPFPatch`'s own metadata half already
/// built in Sprint 10.
///
/// Synthetic only: the same claim proven against the six real Gutenberg
/// books is `shelf-tool epub-cover-patch`, run from
/// `Scripts/real-epub-proof.sh`.
@Suite("Patching a cover into an EPUB's own archive")
struct EPUBCoverPatchTests {

    // MARK: Case a — a manifest that already names a cover

    @Test("EPUB 3: an existing cover-image item's bytes are replaced, path and media-type untouched")
    func epub3ExistingCoverBytesReplaced() throws {
        let archive = try Self.archive(
            packageAttributes: #" version="3.0""#,
            manifestExtra: #"<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#,
            coverPath: "OEBPS/cover.jpg", coverBytes: Self.jpegBytes)

        let result = try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes2, in: archive)
        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)

        #expect(reread.entries.map(\.path) == archive.entries.map(\.path))
        let cover = try #require(reread.entry(at: "OEBPS/cover.jpg"))
        #expect(try reread.data(for: cover) == Self.jpegBytes2)

        let opf = try reread.text(at: "OEBPS/content.opf")
        #expect(opf.contains(#"href="cover.jpg" media-type="image/jpeg" properties="cover-image""#))
    }

    @Test("EPUB 2: an existing cover named by meta content, not by properties, has its bytes replaced the same way")
    func epub2ExistingCoverBytesReplaced() throws {
        let archive = try Self.archive(
            extraMetadata: #"<meta name="cover" content="cover"/>"#,
            manifestExtra: #"<item id="cover" href="images/cover.png" media-type="image/png"/>"#,
            coverPath: "OEBPS/images/cover.png", coverBytes: Self.pngBytes)

        let result = try EPUBCoverPatch.entries(patchingCover: Self.pngBytes2, in: archive)
        #expect(result.replacedExisting)
        #expect(result.mediaTypeCorrected == nil)
        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)

        let cover = try #require(reread.entry(at: "OEBPS/images/cover.png"))
        #expect(try reread.data(for: cover) == Self.pngBytes2)
        // Only the image changed — the OPF was never touched.
        #expect(try reread.text(at: "OEBPS/content.opf") == archive.text(at: "OEBPS/content.opf"))
    }

    // MARK: Case a, the same bytes — nothing to change

    @Test("a cover bit-identical to what the book already has changes nothing")
    func identicalCoverIsNoChange() throws {
        let archive = try Self.archive(
            packageAttributes: #" version="3.0""#,
            manifestExtra: #"<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#,
            coverPath: "OEBPS/cover.jpg", coverBytes: Self.jpegBytes)

        let result = try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes, in: archive)
        #expect(!result.changed)
        #expect(result.replacedExisting)
        #expect(result.mediaTypeCorrected == nil)

        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)
        #expect(Self.differingPaths(archive, reread).isEmpty)
    }

    // MARK: Case a, a format mismatch — the path stays, the media-type is corrected

    @Test("a new image in a different format is still written at the old path, with media-type corrected")
    func formatMismatchCorrectsMediaTypeOnly() throws {
        let archive = try Self.archive(
            packageAttributes: #" version="3.0""#,
            manifestExtra: #"<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#,
            coverPath: "OEBPS/cover.jpg", coverBytes: Self.jpegBytes)

        let result = try EPUBCoverPatch.entries(patchingCover: Self.pngBytes, in: archive)
        #expect(result.replacedExisting)
        #expect(result.mediaTypeCorrected?.from == "image/jpeg")
        #expect(result.mediaTypeCorrected?.to == "image/png")

        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)

        // The path is untouched — an EPUB 2 cover page could embed this
        // exact href, and renaming it would point that page at nothing.
        let cover = try #require(reread.entry(at: "OEBPS/cover.jpg"))
        #expect(try reread.data(for: cover) == Self.pngBytes)

        let root = try XMLTree.parse(try reread.text(at: "OEBPS/content.opf"))
        let item = try #require(root.descendants(named: "item").first { $0.attribute("id") == "cover" })
        #expect(item.attribute("href") == "cover.jpg")
        #expect(item.attribute("media-type") == "image/png")
        #expect(item.attribute("properties") == "cover-image")
    }

    // MARK: Case b — no cover entry at all, added the file's own way

    @Test("EPUB 2: a new cover gets a meta name=cover, never a properties attribute")
    func epub2NewCoverGetsMetaOnly() throws {
        let archive = try Self.archive(packageAttributes: #" version="2.0""#)
        let result = try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes, in: archive)
        #expect(!result.replacedExisting)

        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)
        #expect(reread.entries.count == archive.entries.count + 1)

        let root = try XMLTree.parse(try reread.text(at: "OEBPS/content.opf"))
        let item = try #require(
            root.descendants(named: "item").first {
                $0.attribute("properties") == nil && $0.attribute("media-type")?.hasPrefix("image/") == true
            })
        #expect(item.attribute("properties") == nil)
        let meta = try #require(root.descendants(named: "meta").first { $0.attribute("name") == "cover" })
        #expect(meta.attribute("content") == item.attribute("id"))

        let cover = try #require(reread.entry(at: "OEBPS/" + item.attribute("href")!))
        #expect(try reread.data(for: cover) == Self.jpegBytes)

        let read = EPUBMetadata.read(reread, fallbackTitle: "ignored")
        #expect(read.cover == Self.jpegBytes)
    }

    @Test("EPUB 3, no NCX compatibility: a new cover gets properties=cover-image, no meta")
    func epub3NewCoverGetsPropertiesOnly() throws {
        let archive = try Self.archive(packageAttributes: #" version="3.0""#)
        let result = try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes, in: archive)
        #expect(!result.replacedExisting)

        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)
        let root = try XMLTree.parse(try reread.text(at: "OEBPS/content.opf"))
        let item = try #require(
            root.descendants(named: "item").first { $0.attribute("properties")?.contains("cover-image") == true })
        #expect(item.attribute("properties") == "cover-image")
        #expect(root.descendants(named: "meta").first { $0.attribute("name") == "cover" } == nil)

        let read = EPUBMetadata.read(reread, fallbackTitle: "ignored")
        #expect(read.cover == Self.jpegBytes)
    }

    @Test("EPUB 3 with an NCX for backward compatibility: a new cover gets both forms")
    func epub3WithNCXGetsBothForms() throws {
        // A real Gutenberg EPUB3 shape: <spine toc="ncx"> pointing at an
        // NCX item, kept for readers that only understand EPUB 2 — the
        // signal this project reads as "serve both forms", grounded in
        // `pride-and-prejudice-epub3-images.epub`'s own content.opf.
        let archive = try Self.archive(
            packageAttributes: #" version="3.0""#,
            manifestExtra: #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
            spineToc: "ncx")
        let result = try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes, in: archive)

        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)
        let root = try XMLTree.parse(try reread.text(at: "OEBPS/content.opf"))
        let item = try #require(
            root.descendants(named: "item").first { $0.attribute("properties")?.contains("cover-image") == true })
        #expect(item.attribute("properties") == "cover-image")
        let meta = try #require(root.descendants(named: "meta").first { $0.attribute("name") == "cover" })
        #expect(meta.attribute("content") == item.attribute("id"))
    }

    // MARK: Refusals and collisions

    @Test("a DRM-protected archive is refused before anything is touched")
    func drmRefused() throws {
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(path: "META-INF/container.xml", text: Self.container),
            .raw(path: EPUBMetadata.encryptionPath, text: "<encryption/>"),
            .raw(path: "OEBPS/content.opf", text: Self.opf(packageAttributes: #" version="2.0""#)),
        ]
        let archive = try ZipReader(data: try EPUBArchiveWriter.archive(entries))
        #expect(throws: EPUBCoverPatch.Failure.drmProtected) {
            try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes, in: archive)
        }
    }

    @Test("a new cover's id and path avoid colliding with an id or a path the archive already has")
    func newCoverAvoidsCollisions() throws {
        let archive = try Self.archive(
            packageAttributes: #" version="3.0""#,
            manifestExtra: #"<item id="shelf-cover" href="text2.xhtml" media-type="application/xhtml+xml"/>"#,
            extraCoverPath: "OEBPS/shelf-cover.jpg")
        let result = try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes, in: archive)

        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)
        // Neither the colliding id nor the colliding path was reused.
        let root = try XMLTree.parse(try reread.text(at: "OEBPS/content.opf"))
        let coverItems = root.descendants(named: "item").filter {
            $0.attribute("properties")?.contains("cover-image") == true
        }
        #expect(coverItems.count == 1)
        let newItem = coverItems[0]
        #expect(newItem.attribute("id") != "shelf-cover")
        #expect(newItem.attribute("href") != "shelf-cover.jpg")
        // Both the placeholder file that was already there and the new
        // cover exist afterward.
        #expect(reread.entry(at: "OEBPS/shelf-cover.jpg") != nil)
        #expect(reread.entry(at: "OEBPS/" + newItem.attribute("href")!) != nil)
    }

    // MARK: The sharper proof — how many entries differ

    @Test("case a: replacing a cover with no format change touches exactly one entry, the image")
    func caseAExactlyOneEntryDiffers() throws {
        let archive = try Self.archive(
            packageAttributes: #" version="3.0""#,
            manifestExtra: #"<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#,
            coverPath: "OEBPS/cover.jpg", coverBytes: Self.jpegBytes)
        let result = try EPUBCoverPatch.entries(patchingCover: Self.jpegBytes2, in: archive)
        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)
        #expect(Self.differingPaths(archive, reread) == ["OEBPS/cover.jpg"])
    }

    @Test("case a with a format change: exactly two entries differ, the image and the OPF")
    func caseAFormatChangeExactlyTwoEntriesDiffer() throws {
        let archive = try Self.archive(
            packageAttributes: #" version="3.0""#,
            manifestExtra: #"<item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>"#,
            coverPath: "OEBPS/cover.jpg", coverBytes: Self.jpegBytes)
        let result = try EPUBCoverPatch.entries(patchingCover: Self.pngBytes, in: archive)
        let after = try EPUBArchiveWriter.archive(result.entries)
        let reread = try ZipReader(data: after)
        #expect(Self.differingPaths(archive, reread) == ["OEBPS/content.opf", "OEBPS/cover.jpg"])
    }

    static func differingPaths(_ original: ZipReader, _ patched: ZipReader) -> [String] {
        var differing: [String] = []
        for entry in original.files {
            guard let patchedEntry = patched.entry(at: entry.path) else { continue }
            let same =
                (try? original.compressedData(for: entry)) == (try? patched.compressedData(for: patchedEntry))
            if !same { differing.append(entry.path) }
        }
        return differing.sorted()
    }

    // MARK: Fixtures

    static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(0), count: 12))
    static let jpegBytes2 = Data([0xFF, 0xD8, 0xFF, 0xE1] + Array(repeating: UInt8(1), count: 20))
    static let pngBytes = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: UInt8(2), count: 12))
    static let pngBytes2 = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: UInt8(3), count: 20))

    static let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

    /// A minimal, valid OPF close to the shape `EPUBOPFPatchTests.opf` uses.
    /// `spineToc`, given, is the real Gutenberg EPUB3 signal this project
    /// reads as "also serve the EPUB 2 form" — `<spine toc="…">` naming an
    /// NCX kept for backward compatibility.
    static func opf(
        packageAttributes: String = "", extraMetadata: String = "", manifestExtra: String = "",
        spineToc: String? = nil
    ) -> String {
        """
        <?xml version='1.0' encoding='utf-8'?>
        <package xmlns:opf="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns="http://www.idpf.org/2007/opf" unique-identifier="id"\(packageAttributes)>
          <metadata>
            <dc:identifier id="id">urn:uuid:11111111-1111-1111-1111-111111111111</dc:identifier>
            <dc:title>A Book</dc:title>
        \(extraMetadata.isEmpty ? "" : "    " + extraMetadata + "\n")\
          </metadata>
          <manifest>
            <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
        \(manifestExtra.isEmpty ? "" : "    " + manifestExtra + "\n")\
          </manifest>
          <spine\(spineToc.map { #" toc="\#($0)""# } ?? "")><itemref idref="text"/></spine>
        </package>
        """
    }

    /// The archive for `opf(…)`, with an optional pre-existing cover's bytes
    /// added at `coverPath`, and an optional unrelated file at
    /// `extraCoverPath` — used only to prove a name collision is avoided.
    static func archive(
        packageAttributes: String = "", extraMetadata: String = "", manifestExtra: String = "",
        spineToc: String? = nil, coverPath: String? = nil, coverBytes: Data = Data(),
        extraCoverPath: String? = nil
    ) throws -> ZipReader {
        var entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(path: "META-INF/container.xml", text: Self.container),
            .raw(
                path: "OEBPS/content.opf",
                text: Self.opf(
                    packageAttributes: packageAttributes, extraMetadata: extraMetadata,
                    manifestExtra: manifestExtra, spineToc: spineToc)),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>Some text.</p></body></html>"),
        ]
        if let coverPath {
            entries.append(.raw(path: coverPath, data: coverBytes))
        }
        if let extraCoverPath {
            entries.append(.raw(path: extraCoverPath, data: Self.pngBytes2))
        }
        return try ZipReader(data: try EPUBArchiveWriter.archive(entries))
    }
}
