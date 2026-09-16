import Foundation
import Testing

@testable import ShelfCore

@Suite("Reading ZIP archives")
struct ZipReaderTests {

    @Test("entries come back with their paths, sizes and contents")
    func roundTrip() throws {
        let items = [
            ZipWriter.Item(path: "mimetype", text: "application/epub+zip"),
            ZipWriter.Item(path: "META-INF/container.xml", text: "<container/>"),
            ZipWriter.Item(path: "OEBPS/content.opf", text: "<package/>"),
        ]
        let archive = try ZipReader(data: ZipWriter().archive(items))

        #expect(archive.entries.count == 3)
        #expect(archive.entries.map(\.path) == ["mimetype", "META-INF/container.xml", "OEBPS/content.opf"])
        #expect(try archive.text(at: "mimetype") == "application/epub+zip")
        #expect(try archive.text(at: "OEBPS/content.opf") == "<package/>")
    }

    /// The reader has to work for a comic too, and a page is not a few bytes.
    @Test("a large entry round-trips byte for byte")
    func largeEntry() throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 256) })
        let archive = try ZipReader(data: ZipWriter().archive([.init(path: "big.bin", data: payload)]))
        #expect(try archive.data(at: "big.bin") == payload)
    }

    @Test("a folder marker is not a file")
    func directoryEntries() throws {
        let archive = try ZipReader(
            data: ZipWriter().archive([
                .init(path: "OEBPS/", data: Data()),
                .init(path: "OEBPS/text.xhtml", text: "<html/>"),
            ]))
        #expect(archive.entries.count == 2)
        #expect(archive.files.map(\.path) == ["OEBPS/text.xhtml"])
        #expect(archive.entry(at: "OEBPS/")?.isDirectory == true)
    }

    @Test("the name without its folders is available, for sorting a comic's pages")
    func fileNames() throws {
        let archive = try ZipReader(
            data: ZipWriter().archive([.init(path: "a/b/page-003.jpg", data: Data([1]))]))
        #expect(archive.files.first?.fileName == "page-003.jpg")
    }

    /// The end-of-central-directory record is found by searching backwards,
    /// because a trailing comment may follow it. A forward search would also
    /// stop at the signature's bytes appearing inside the data.
    @Test("an archive with a trailing comment is still read")
    func trailingComment() throws {
        var data = ZipWriter().archive([.init(path: "a.txt", text: "hello")])
        // Rewrite the comment length and append a comment.
        let comment = Data("a comment that follows the record".utf8)
        data[data.count - 2] = UInt8(comment.count & 0xFF)
        data[data.count - 1] = UInt8((comment.count >> 8) & 0xFF)
        data.append(comment)

        let archive = try ZipReader(data: data)
        #expect(try archive.text(at: "a.txt") == "hello")
    }

    @Test("a file that is not a ZIP says so")
    func notAZip() {
        #expect(throws: ZipReader.Failure.notAZipArchive) {
            try ZipReader(data: Data("this is a plain text file, not an archive".utf8))
        }
        #expect(throws: ZipReader.Failure.notAZipArchive) { try ZipReader(data: Data()) }
    }

    @Test("asking for an entry that is not there names it")
    func missingEntry() throws {
        let archive = try ZipReader(data: ZipWriter().archive([.init(path: "a.txt", text: "x")]))
        #expect(throws: ZipReader.Failure.entryNotFound("b.txt")) { try archive.data(at: "b.txt") }
    }

    @Test("an unknown compression method is reported by number, not guessed at")
    func unsupportedMethod() throws {
        var data = ZipWriter().archive([.init(path: "a.txt", text: "hello")])
        // Method lives at offset 8 of the local header and 10 of the central
        // directory entry; only the directory is read for the method.
        guard let start = Self.findSignature([0x50, 0x4B, 0x01, 0x02], in: data) else {
            Issue.record("no central directory in the written archive")
            return
        }
        data[start + 10] = 14  // LZMA
        data[start + 11] = 0

        let archive = try ZipReader(data: data)
        #expect(archive.entries.first?.method == .unsupported(14))
        #expect(throws: ZipReader.Failure.unsupportedMethod("a.txt", 14)) { try archive.data(at: "a.txt") }
    }

    /// A stored entry whose stated size does not match its bytes is corrupt,
    /// and a book must not be built out of it.
    @Test("a stored entry of the wrong length is refused")
    func corruptStoredEntry() throws {
        var data = ZipWriter().archive([.init(path: "a.txt", text: "hello")])
        guard let start = Self.findSignature([0x50, 0x4B, 0x01, 0x02], in: data) else {
            Issue.record("no central directory in the written archive")
            return
        }
        // Uncompressed size at offset 24 of the directory entry.
        data[start + 24] = 99
        let archive = try ZipReader(data: data)
        #expect(throws: ZipReader.Failure.corruptEntry("a.txt")) { try archive.data(at: "a.txt") }
    }

    @Test("a ZIP64 archive is named as such rather than read wrongly")
    func zip64() throws {
        var data = ZipWriter().archive([.init(path: "a.txt", text: "hello")])
        // The end record's entry count set to 0xFFFF is how ZIP64 announces
        // itself; the real numbers live in a record this reader does not read.
        guard let end = Self.findSignature([0x50, 0x4B, 0x05, 0x06], in: data) else {
            Issue.record("no end record in the written archive")
            return
        }
        data[end + 10] = 0xFF
        data[end + 11] = 0xFF
        #expect(throws: ZipReader.Failure.zip64NotSupported) { try ZipReader(data: data) }
    }

    @Test("a UTF-8 path with spaces and accents survives")
    func unicodePaths() throws {
        let path = "OEBPS/Ólafsdóttir – cover 1.png"
        let archive = try ZipReader(data: ZipWriter().archive([.init(path: path, data: Data([1, 2, 3]))]))
        #expect(archive.entries.first?.path == path)
        #expect(try archive.data(at: path) == Data([1, 2, 3]))
    }

    @Test("reading a file from disk gives the same result as reading its bytes")
    func fromURL() throws {
        let folder = try TemporaryFolder()
        let data = ZipWriter().archive([.init(path: "a.txt", text: "from disk")])
        let url = try folder.write("test.zip", data: data)
        #expect(try ZipReader(url: url).text(at: "a.txt") == "from disk")
    }

    @Test("a file that cannot be read names itself")
    func unreadableFile() {
        let url = URL(fileURLWithPath: "/nonexistent/nothing.epub")
        #expect(throws: ZipReader.Failure.cannotRead("nothing.epub")) { try ZipReader(url: url) }
    }

    /// Finds the *last* occurrence, which is what the reader does.
    private static func findSignature(_ signature: [UInt8], in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count else { return nil }
        for start in stride(from: bytes.count - signature.count, through: 0, by: -1) {
            if Array(bytes[start..<(start + signature.count)]) == signature { return start }
        }
        return nil
    }
}
