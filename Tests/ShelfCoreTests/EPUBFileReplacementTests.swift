import Foundation
import Testing

@testable import ShelfCore

/// The rule that a book file is never written falls here, for the first
/// time — in a controlled way, one refusable step at a time. Every test
/// below either proves the whole path works, or proves that a refusal
/// leaves the original exactly as it was: no `.part`, no half-result.
///
/// Synthetic only. The same path, against copies of six real books, is
/// `shelf-tool epub-file-replace-proof`, run from
/// `Scripts/real-epub-proof.sh` — a real volume, a real Trash and six real
/// EPUBs cannot live in this test bundle (`CLAUDE.md`).
@Suite("Writing a book's own EPUB file")
struct EPUBFileReplacementTests {

    // MARK: The whole path

    @Test("the whole path: written, read back, hashed, the original in the Trash")
    func wholePathSucceeds() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.epub", data: Self.book(title: "Old Title", author: "Old Author"))
        let originalData = try Data(contentsOf: url)
        let newContent = Self.book(title: "New Title", author: "New Author")

        let bin = try Bin(in: folder.url)
        let bookID = UUID()

        let result = try EPUBFileReplacement.replace(
            with: newContent, at: url, bookID: bookID, disposal: bin.disposal)

        #expect(result.written == url)
        #expect(result.displacedOriginal == "book.epub")
        #expect(result.format.bookID == bookID)
        #expect(result.format.format == .epub)
        #expect(result.format.fileName == "book.epub")
        #expect(result.format.byteSize == Int64(newContent.count))
        #expect(result.format.drm == nil)

        // The original reached the Trash — under a renamed-aside name, not
        // its own, since the swap renames it aside before offering it to
        // disposal at all (Korrektur 1).
        #expect(result.originalDisposal == .trashed)
        #expect(bin.taken.count == 1)
        // Got back, byte for byte — the point of the Trash rather than
        // `removeItem`.
        #expect(try Data(contentsOf: bin.folder.appendingPathComponent(bin.taken[0])) == originalData)

        // The file at the original path now holds the new content, and its
        // hash is not the old file's.
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk == newContent)
        #expect(FileDigest.sha256(of: onDisk, makeHasher: PortableSHA256Hasher.factory) == result.format.sha256)
        #expect(result.format.sha256 != FileDigest.sha256(of: originalData, makeHasher: PortableSHA256Hasher.factory))

        // Read back with Shelf's own reader, the way the caller would check.
        let read = try EPUBMetadata.read(url: url)
        #expect(read.book.title == "New Title")
        #expect(read.book.authors == ["New Author"])

        // No debris left behind.
        #expect(folder.names(in: "").allSatisfy { !$0.hasPrefix(EPUBFileReplacement.partialPrefix) })
    }

    @Test("commit updates exactly the book's own .epub format row in the index")
    func commitUpdatesTheIndex() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        let bookFolder = try folder.folder("library/Author/Book (1)")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub", data: Self.book(title: "Old Title", author: "Old Author"))

        let library = Library(root: libraryRoot)
        let index = try LibraryIndex(inMemory: "epub-file-replacement-test")
        let bookID = UUID()
        let oldFormat = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let pdfFormat = BookFormat(
            bookID: bookID, format: .pdf, fileName: "book.pdf", byteSize: 2, sha256: "unrelated", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "Old Title", authors: ["Old Author"]), number: 1, folder: "Author/Book (1)",
            formats: [oldFormat, pdfFormat])
        try await index.save(entry)

        let bin = try Bin(in: folder.url)
        let newContent = Self.book(title: "New Title", author: "New Author")
        let outcome = try await EPUBFileReplacement.commit(
            newContent, to: entry, library: library, index: index, disposal: bin.disposal)

        guard case .wrote(let updated) = outcome else {
            Issue.record("expected .wrote, got \(outcome)")
            return
        }
        let newEPUB = try #require(updated.formats.first { $0.format == .epub })
        #expect(newEPUB.sha256 != "old")
        #expect(newEPUB.byteSize == Int64(newContent.count))
        // The PDF row is untouched — this never writes anything but the EPUB.
        #expect(updated.formats.first { $0.format == .pdf } == pdfFormat)

        let reloaded = try await index.entries(ids: [bookID])
        #expect(reloaded.first?.formats.first { $0.format == .epub }?.sha256 == newEPUB.sha256)

        _ = bookFolder  // silence "never read" – the folder exists for the write above
    }

    // MARK: Refusals, and that nothing changes when one happens

    @Test("a file that is not an EPUB is refused, and left exactly as it was")
    func notAnEPUBRefused() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.txt", text: "not a book")
        let before = try Data(contentsOf: url)

        #expect(throws: EPUBFileReplacement.Refusal.notAnEPUB) {
            try EPUBFileReplacement.replace(with: Data(), at: url, bookID: UUID())
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(folder.names(in: "") == ["book.txt"])
    }

    @Test("a corrupt file with an .epub name is refused as not an EPUB, not crashed on")
    func corruptEPUBRefused() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.epub", text: "this is not a zip file at all")
        let before = try Data(contentsOf: url)

        #expect(throws: EPUBFileReplacement.Refusal.notAnEPUB) {
            try EPUBFileReplacement.replace(with: Data(), at: url, bookID: UUID())
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("a DRM-protected EPUB is refused before anything is written, in the core")
    func drmProtectedRefused() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.epub", data: Self.book(title: "A Book", author: "Someone", drm: true))
        let before = try Data(contentsOf: url)

        #expect(throws: EPUBFileReplacement.Refusal.drmProtected) {
            try EPUBFileReplacement.preflight(url)
        }
        #expect(throws: EPUBFileReplacement.Refusal.drmProtected) {
            try EPUBFileReplacement.replace(with: Self.book(title: "New", author: "New"), at: url, bookID: UUID())
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(folder.names(in: "") == ["book.epub"])
    }

    @Test("a read-only folder is refused before anything is written, named")
    func readOnlyVolumeRefused() throws {
        let folder = try TemporaryFolder()
        let bookFolder = try folder.folder("book")
        let url = try folder.write("book/book.epub", data: Self.book(title: "A Book", author: "Someone"))
        let before = try Data(contentsOf: url)

        let originalPermissions =
            (try? FileManager.default.attributesOfItem(atPath: bookFolder.path)[.posixPermissions])
            as? Int
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: bookFolder.path)
        defer {
            if let originalPermissions {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: originalPermissions], ofItemAtPath: bookFolder.path)
            }
        }

        // Root (a container's default user) can write through the
        // permission bits this test sets, which would make the refusal this
        // test is proving never fire. Skip rather than report a false pass.
        guard !FileManager.default.isWritableFile(atPath: bookFolder.path) else {
            return
        }

        #expect(throws: EPUBFileReplacement.Refusal.self) {
            try EPUBFileReplacement.preflight(url)
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("a disposal that refuses the original is a fact, not a refusal — the book is already correct")
    func disposalFailureLeavesTheBookCorrect() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.epub", data: Self.book(title: "A Book", author: "Someone"))
        let newContent = Self.book(title: "New", author: "New")

        // No `#expect(throws:)` here on purpose: by the time disposal is
        // even attempted, the swap has already happened (Korrektur 1), so
        // `FolderDisposal.none` refusing does not stop this from returning
        // normally.
        let result = try EPUBFileReplacement.replace(
            with: newContent, at: url, bookID: UUID(), disposal: .none)

        #expect(try Data(contentsOf: url) == newContent)
        let read = try EPUBMetadata.read(url: url)
        #expect(read.book.title == "New")

        guard case .leftAsDebris(let name, let reason) = result.originalDisposal else {
            Issue.record("expected .leftAsDebris, got \(result.originalDisposal)")
            return
        }
        #expect(name.hasPrefix(EPUBFileReplacement.partialPrefix))
        #expect(reason == FolderDisposal.Failure.noTrashHere.localizedDescription)
        // The old bytes are still there under that name — not gone, just
        // not in the Trash — for the next call in this folder to sweep.
        #expect(folder.names(in: "").contains(name))
    }

    @Test("debris a failed disposal left behind is swept by the next call in that folder")
    func debrisFromAFailedDisposalIsSweptByTheNextCall() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.epub", data: Self.book(title: "A Book", author: "Someone"))
        _ = try EPUBFileReplacement.replace(
            with: Self.book(title: "New", author: "New"), at: url, bookID: UUID(), disposal: .none)
        #expect(folder.names(in: "").contains { $0.hasPrefix(EPUBFileReplacement.partialPrefix) })

        let bin = try Bin(in: folder.url)
        _ = try EPUBFileReplacement.replace(
            with: Self.book(title: "Newer", author: "Newer"), at: url, bookID: UUID(), disposal: bin.disposal)

        #expect(folder.names(in: "").allSatisfy { !$0.hasPrefix(EPUBFileReplacement.partialPrefix) })
    }

    @Test("a new file that loses the cover the original had is refused, and the original is untouched")
    func readBackFailedWhenCoverMissing() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.epub", data: Self.book(title: "A Book", author: "Someone", cover: true))
        let before = try Data(contentsOf: url)

        #expect(throws: EPUBFileReplacement.Refusal.self) {
            try EPUBFileReplacement.replace(
                with: Self.book(title: "A Book", author: "Someone", cover: false), at: url, bookID: UUID())
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(folder.names(in: "") == ["book.epub"])
    }

    @Test("a new file that is not readable at all is refused, and the original is untouched")
    func readBackFailedWhenUnreadable() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("book.epub", data: Self.book(title: "A Book", author: "Someone"))
        let before = try Data(contentsOf: url)

        #expect(throws: EPUBFileReplacement.Refusal.self) {
            try EPUBFileReplacement.replace(with: Data("not a zip".utf8), at: url, bookID: UUID())
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(folder.names(in: "") == ["book.epub"])
    }

    // MARK: Fixtures

    /// A disposal that moves what it is given into a folder of its own,
    /// rather than the real Trash — the same reason `CoverReplacementTests`
    /// does this rather than call `FolderDisposal.trash`: a test can ask
    /// both "is it gone from the book's folder" and "can it still be got
    /// back", which is what the Trash means and `removeItem` does not, and
    /// unlike the real Trash this does not depend on a Finder session the
    /// process running these tests may not have.
    private final class Bin: @unchecked Sendable {
        let folder: URL
        private(set) var taken: [String] = []

        init(in parent: URL) throws {
            folder = parent.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        var disposal: FolderDisposal {
            FolderDisposal { [self] url in
                let target = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: url, to: target)
                taken.append(url.lastPathComponent)
            }
        }
    }

    /// A minimal, valid EPUB, built through `EPUBArchiveWriter` itself —
    /// the same production writer this whole path is proven against, not a
    /// second implementation.
    static func book(title: String, author: String, cover: Bool = true, drm: Bool = false) -> Data {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" \
            version="2.0" unique-identifier="id">
              <metadata>
                <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:creator opf:role="aut">\(author)</dc:creator>
            \(cover ? "    <meta name=\"cover\" content=\"cover-image\"/>\n" : "")\
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
            \(cover ? "    <item id=\"cover-image\" href=\"cover.jpg\" media-type=\"image/jpeg\"/>\n" : "")\
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        var entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(
                path: "META-INF/container.xml",
                text: """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>\(title)</p></body></html>"),
        ]
        if cover {
            entries.append(.raw(path: "OEBPS/cover.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])))
        }
        if drm {
            entries.append(.raw(path: "META-INF/encryption.xml", text: "<encryption/>"))
        }
        return (try? EPUBArchiveWriter.archive(entries)) ?? Data()
    }
}
