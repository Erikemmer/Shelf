import Foundation
import Testing

@testable import ShelfCore

@Suite("Writing ZIP archives")
struct ZipArchiveWriterTests {

    @Test("what is written is what ZipReader reads back")
    func roundTrip() throws {
        let entries = [
            ZipArchiveWriter.Entry(path: "a.txt", text: "hello"),
            ZipArchiveWriter.Entry(path: "folder/b.bin", data: Data([1, 2, 3, 4, 5])),
        ]
        let archive = try ZipReader(data: try ZipArchiveWriter().archive(entries))
        #expect(archive.entries.map(\.path) == ["a.txt", "folder/b.bin"])
        #expect(try archive.text(at: "a.txt") == "hello")
        #expect(try archive.data(at: "folder/b.bin") == Data([1, 2, 3, 4, 5]))
    }

    @Test("every entry is written stored, never deflated")
    func alwaysStored() throws {
        let archive = try ZipReader(
            data: try ZipArchiveWriter().archive([.init(path: "a.txt", text: "hello")]))
        #expect(archive.entries.first?.method == .stored)
    }

    @Test("a name with an umlaut and a Cyrillic name both survive")
    func nonASCIINames() throws {
        let entries = [
            ZipArchiveWriter.Entry(path: "Bilder/Über uns.txt", text: "x"),
            ZipArchiveWriter.Entry(path: "Обложка/глава.txt", text: "y"),
        ]
        let archive = try ZipReader(data: try ZipArchiveWriter().archive(entries))
        #expect(Set(archive.entries.map(\.path)) == Set(entries.map(\.path)))
    }

    @Test("an empty list of entries is a valid, empty archive")
    func empty() throws {
        let archive = try ZipReader(data: try ZipArchiveWriter().archive([]))
        #expect(archive.entries.isEmpty)
    }

    @Test("more entries than a 32-bit directory can count is refused, named")
    func tooManyEntries() {
        let entries = (0..<(ZipArchiveWriter.maximumEntries + 1)).map {
            ZipArchiveWriter.Entry(path: "\($0)", data: Data())
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
            ZipArchiveWriter.Entry(path: "\($0)", data: Data())
        }
        // Proves the boundary is inclusive rather than merely not crashing –
        // one more throws (`tooManyEntries` above), this many does not.
        _ = try ZipArchiveWriter().archive(atLimit)
    }
}
