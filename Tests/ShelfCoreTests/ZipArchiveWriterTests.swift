import Foundation
import Testing

@testable import ShelfCore

@Suite("Writing ZIP archives")
struct ZipArchiveWriterTests {

    @Test("what is written is what ZipReader reads back")
    func roundTrip() throws {
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "a.txt", text: "hello"),
            .raw(path: "folder/b.bin", data: Data([1, 2, 3, 4, 5])),
        ]
        let archive = try ZipReader(data: try ZipArchiveWriter().archive(entries))
        #expect(archive.entries.map(\.path) == ["a.txt", "folder/b.bin"])
        #expect(try archive.text(at: "a.txt") == "hello")
        #expect(try archive.data(at: "folder/b.bin") == Data([1, 2, 3, 4, 5]))
    }

    @Test("a raw entry is written stored, never deflated")
    func rawIsStored() throws {
        let archive = try ZipReader(
            data: try ZipArchiveWriter().archive([.raw(path: "a.txt", text: "hello")]))
        #expect(archive.entries.first?.method == .stored)
    }

    @Test("a raw entry gets a fixed, valid placeholder date rather than the invalid all-zero one")
    func rawEntryDate() throws {
        let archive = try ZipReader(
            data: try ZipArchiveWriter().archive([.raw(path: "a.txt", text: "hello")]))
        #expect(archive.entries.first?.modDate == 0x0021)  // 1 January 1980
        #expect(archive.entries.first?.modTime == 0x0000)  // midnight, a real time
    }

    /// The whole reason `.passthrough` exists: a book's own text, compressed
    /// by whatever wrote the source archive, must stay compressed rather
    /// than being decompressed and stored back at several times its size.
    @Test("a passthrough entry keeps its own method, size, CRC and date, not stored")
    func passthroughKeepsItsOwnMethod() throws {
        let source = try ZipReader(
            data: try ZipArchiveWriter().archive([.raw(path: "mimetype", data: Data([1, 2, 3]))]))
        let sourceEntry = try #require(source.entry(at: "mimetype"))
        let passthrough = ZipArchiveWriter.Entry.passthrough(
            path: "mimetype", compressedData: try source.compressedData(for: sourceEntry), method: .deflate,
            uncompressedSize: 999, crc32: 0xDEAD_BEEF, modTime: 0x1234, modDate: 0x5678)

        let archive = try ZipReader(data: try ZipArchiveWriter().archive([passthrough]))
        let written = try #require(archive.entry(at: "mimetype"))
        #expect(written.method == .deflate)
        #expect(written.uncompressedSize == 999)
        #expect(written.crc32 == 0xDEAD_BEEF)
        #expect(written.modTime == 0x1234)
        #expect(written.modDate == 0x5678)
    }

    @Test("a name with an umlaut and a Cyrillic name both survive")
    func nonASCIINames() throws {
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "Bilder/Über uns.txt", text: "x"),
            .raw(path: "Обложка/глава.txt", text: "y"),
        ]
        let archive = try ZipReader(data: try ZipArchiveWriter().archive(entries))
        #expect(Set(archive.entries.map(\.path)) == Set(entries.map(\.path)))
    }

    @Test("an empty list of entries is a valid, empty archive")
    func empty() throws {
        let archive = try ZipReader(data: try ZipArchiveWriter().archive([]))
        #expect(archive.entries.isEmpty)
    }

    @Test("an absolute path is refused, named")
    func absolutePathRefused() {
        #expect(throws: ZipArchiveWriter.Failure.invalidPath("/etc/passwd")) {
            try ZipArchiveWriter().archive([.raw(path: "/etc/passwd", text: "x")])
        }
    }

    @Test("a path that climbs out with .. is refused, named")
    func dotDotRefused() {
        #expect(throws: ZipArchiveWriter.Failure.invalidPath("../../etc/passwd")) {
            try ZipArchiveWriter().archive([.raw(path: "../../etc/passwd", text: "x")])
        }
    }

    @Test("a .. in the middle of a path is refused too")
    func dotDotInTheMiddleRefused() {
        #expect(throws: ZipArchiveWriter.Failure.invalidPath("OEBPS/../../../etc/passwd")) {
            try ZipArchiveWriter().archive([.raw(path: "OEBPS/../../../etc/passwd", text: "x")])
        }
    }

    @Test("more entries than a 32-bit directory can count is refused, named")
    func tooManyEntries() {
        let entries = (0..<(ZipArchiveWriter.maximumEntries + 1)).map {
            ZipArchiveWriter.Entry.raw(path: "\($0)", data: Data())
        }
        #expect(throws: ZipArchiveWriter.Failure.tooManyEntries(entries.count)) {
            try ZipArchiveWriter().archive(entries)
        }
    }

    /// The boundary itself, not a multi-gigabyte `Data` to trigger it for
    /// real: `0xFFFFFFFF` is reserved by the format to mean "see the ZIP64
    /// extra field", so it is refused as a real value one below the maximum
    /// count a 32-bit field can otherwise hold.
    @Test("the 32-bit field boundary is exactly where the format reserves it")
    func fieldBoundary() {
        #expect(ZipArchiveWriter.fits32Bits(0xFFFF_FFFE))
        #expect(!ZipArchiveWriter.fits32Bits(0xFFFF_FFFF))
        #expect(!ZipArchiveWriter.fits32Bits(0x1_0000_0000))
    }

    @Test("the maximum entry count is exactly 65 535, one below what needs ZIP64")
    func entryCountBoundary() throws {
        let atLimit = (0..<ZipArchiveWriter.maximumEntries).map {
            ZipArchiveWriter.Entry.raw(path: "\($0)", data: Data())
        }
        // Proves the boundary is inclusive rather than merely not crashing –
        // one more throws (`tooManyEntries` above), this many does not.
        _ = try ZipArchiveWriter().archive(atLimit)
    }
}
