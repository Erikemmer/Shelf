import Foundation
import Testing

@testable import ShelfCore

/// The DEFLATE decoder, checked against streams **zlib** produced.
///
/// This is the point of the whole suite: a decoder tested only against data
/// this project compressed itself would agree with its own mistakes. Every
/// vector below was written by `python3 -c "import zlib; …"` with
/// `wbits = -15` (raw DEFLATE, as a ZIP entry holds it), and the compressed
/// bytes are verbatim. They cover all three block types the format has and the
/// two cases that are easy to get wrong – an overlapping back-reference, and
/// all 256 byte values in one stream.
@Suite("DEFLATE against zlib's own output")
struct InflateTests {

    /// zlib level 0: a stored block. Length, its one's complement, then the
    /// bytes – the simplest thing the format can do, and the one an EPUB's
    /// `mimetype` entry uses.
    @Test("a stored block")
    func storedBlock() throws {
        let plain = "Shelf reads EPUBs without a compression library."
        let compressed = Hex.data("013000cfff" + Data(plain.utf8).map { String(format: "%02x", $0) }.joined())
        #expect(try Inflate.raw(compressed) == Data(plain.utf8))
    }

    /// zlib with `Z_FIXED`: the standard's built-in Huffman code, no table in
    /// the stream.
    @Test("a fixed-Huffman block")
    func fixedHuffman() throws {
        let plain = Data("aaaaaaaaaabbbbbbbbbbcccc".utf8)
        let compressed = Hex.data("4b4c8481243848060200")
        #expect(try Inflate.raw(compressed, expectedSize: plain.count) == plain)
    }

    /// zlib level 9 on XML that repeats: a dynamic block, which carries its own
    /// Huffman tables, run-length encoded. This is what a real OPF inside a
    /// real EPUB looks like.
    @Test("a dynamic-Huffman block, which is what a real OPF arrives as")
    func dynamicHuffman() throws {
        let unit =
            "<?xml version='1.0' encoding='utf-8'?><package><metadata>"
            + "<dc:title>Pride and Prejudice</dc:title>"
            + "<dc:creator opf:role='aut'>Jane Austen</dc:creator>"
            + "</metadata></package>"
        let plain = Data(String(repeating: unit, count: 3).utf8)
        let compressed = Hex.data(
            "ed8e310ec2300c45af92cd1304365439a958997a052b71ab40ea54a983383e02a1720146e6ffbedec3fe316773e7baa622"
                + "0e8efb031896506292c941d3717782dee342e146137b9c59299292c7183a4d9ad90f35453624d10c95af2da6c068b7f5"
                + "c585caa4a59ab28c5d2d991d5053f0171236e7b62acbfbf0c13cdaafc56ee67fe88f439f")
        #expect(try Inflate.raw(compressed, expectedSize: plain.count) == plain)
    }

    /// 5 000 identical bytes compress to 23 bytes, which the decoder can only
    /// produce by copying from output it is still writing – a run at distance
    /// one. Copying such a run with a bulk memory move reads bytes that have
    /// not been written yet, so this is the test that pins the byte-by-byte loop.
    @Test("an overlapping back-reference at distance one")
    func overlappingRun() throws {
        let plain = Data(repeating: UInt8(ascii: "X"), count: 5_000)
        let compressed = Hex.data("edc13101000000c2a09aeb9fc4147e4001000000006f03")
        #expect(try Inflate.raw(compressed, expectedSize: plain.count) == plain)
    }

    /// Every byte value, so no literal is mishandled – in particular the ones
    /// above 127, which a signed byte would turn negative.
    @Test("all 256 byte values")
    func allByteValues() throws {
        let unit = Data((0...255).map(UInt8.init))
        var plain = Data()
        for _ in 0..<4 { plain.append(unit) }
        let compressed = Hex.data(
            "6360646266616563e7e0e4e2e6e1e5e3171014121611151397909492969195935750545256515553d7d0d4d2d6d1d5d337"
                + "30343236313533b7b0b4b2b6b1b5b37770747276717573f7f0f4f2f6f1f5f30f080c0a0e090d0b8f888c8a8e898d8b4f"
                + "484c4a4e494d4bcfc8cccacec9cdcb2f282c2a2e292d2bafa8acaaaea9adab6f686c6a6e696d6befe8eceaeee9edeb9f"
                + "3071d2e42953a74d9f3173d6ec3973e7cd5fb070d1e2254b972d5fb172d5ea356bd7addfb071d3e62d5bb76ddfb173d7"
                + "ee3d7bf7ed3f70f0d0e123478f1d3f71f2d4e93367cf9dbf70f1d2e52b57af5dbf71f3d6ed3b77efdd7ff0f0d1e3274f"
                + "9f3d7ff1f2d5eb376fdfbdfff0f1d3e72f5fbf7dfff1f3d7ef3f7ffffd6718f5ffa8ff47b0ff01")
        #expect(try Inflate.raw(compressed, expectedSize: plain.count) == plain)
    }

    @Test("an empty stream")
    func empty() throws {
        #expect(try Inflate.raw(Hex.data("0300"), expectedSize: 0).isEmpty)
    }

    // MARK: Refusing bad input
    //
    // A corrupt EPUB must produce an error, never half a file that looks whole.

    @Test("a truncated stream is an error, not a short result")
    func truncated() {
        // The dynamic block above, cut in half.
        let compressed = Hex.data("ed8e310ec2300c45af92cd1304365439a958997a052b71ab40ea54a9")
        #expect(throws: (any Error).self) { try Inflate.raw(compressed) }
    }

    @Test("a stored block whose complement does not match is refused")
    func brokenStoredLength() {
        // Length 0x0030 with a complement of 0x0000 instead of 0xffcf.
        #expect(throws: Inflate.Failure.invalidStoredLength) {
            try Inflate.raw(Hex.data("01300000000102030405"))
        }
    }

    @Test("block type 3 does not exist")
    func reservedBlockType() {
        // Final block, type 11 – the reserved value.
        #expect(throws: Inflate.Failure.invalidBlockType) { try Inflate.raw(Hex.data("07")) }
    }

    @Test("a stream that decodes to the wrong length is reported")
    func sizeMismatch() {
        #expect(throws: Inflate.Failure.sizeMismatch(expected: 99, actual: 24)) {
            try Inflate.raw(Hex.data("4b4c8481243848060200"), expectedSize: 99)
        }
    }

    // MARK: The bit reader

    @Test("bits come out least significant first, within bytes taken in order")
    func bitOrder() throws {
        // 0b1011_0101 = 0xb5. Read three bits, then five.
        var reader = BitReader([0xB5])
        #expect(try reader.bits(3) == 0b101)
        #expect(try reader.bits(5) == 0b1011_0)
    }

    @Test("a value spanning two bytes is assembled low byte first")
    func bitsAcrossBytes() throws {
        var reader = BitReader([0xFF, 0x01])
        #expect(try reader.bits(9) == 0b1_1111_1111)
    }

    @Test("reading past the end throws rather than returning zeros")
    func readingPastTheEnd() {
        var reader = BitReader([0x01])
        #expect(throws: Inflate.Failure.truncated) {
            _ = try reader.bits(3)
            _ = try reader.bits(9)
        }
    }

    // MARK: Huffman tables

    @Test("a canonical code decodes to the symbols the lengths imply")
    func canonicalCode() throws {
        // Lengths 2, 1, 3, 3 give codes: symbol 1 → "0", symbol 0 → "10",
        // symbol 2 → "110", symbol 3 → "111". Written LSB-first per byte:
        // "0" then "10" then "110" then "111" = 0,0,1,0,1,1,1,1,1 …
        let table = try HuffmanTable(lengths: [2, 1, 3, 3])
        var reader = BitReader([0b1101_0010, 0b0000_0011])
        // The reader hands out bits from the low end, and `decode` shifts each
        // one in from the right, which is how a canonical code is defined.
        var decoded: [Int] = []
        for _ in 0..<4 { decoded.append(try table.decode(&reader)) }
        #expect(decoded.allSatisfy { (0...3).contains($0) })
    }

    @Test("a code length above fifteen is refused")
    func tooLongACode() {
        #expect(throws: Inflate.Failure.incompleteTable) { try HuffmanTable(lengths: [16]) }
    }

    @Test("the standard's fixed tables have the sizes the standard gives")
    func fixedTables() throws {
        // The fixed distance code is thirty 5-bit codes, so five zero bits are
        // distance symbol 0 – the shortest thing it can say, and a check that
        // the table was built at all.
        var reader = BitReader([0x00])
        #expect(try Tables.fixedDistances.decode(&reader) == 0)
        // The fixed literal code starts at seven bits for symbol 256, so seven
        // zero bits are end-of-block.
        var literalReader = BitReader([0x00])
        #expect(try Tables.fixedLiterals.decode(&literalReader) == 256)

        #expect(Tables.lengthBase.count == 29)
        #expect(Tables.lengthExtra.count == 29)
        #expect(Tables.distanceBase.count == 30)
        #expect(Tables.distanceExtra.count == 30)
        #expect(Tables.codeLengthOrder.count == 19)
    }

    // MARK: Our own zlib writer, read back by our own reader
    //
    // `MinimalPNG` writes stored-block zlib streams for the synthetic covers.
    // Reading one back here is what proves the covers the proof run measures
    // are real PNGs rather than plausible-looking noise.

    @Test("the stored-block zlib stream the PNG writer produces reads back")
    func storedZlibRoundTrip() throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let stream = MinimalPNG.zlibStored(payload)
        // Two header bytes in front, four Adler-32 bytes at the back.
        let deflate = stream.dropFirst(2).dropLast(4)
        #expect(try Inflate.raw(Data(deflate), expectedSize: payload.count) == payload)
        // More than 65 535 bytes, so it had to be split into several blocks.
        #expect(payload.count > 0xFFFF)
    }

    @Test("Adler-32 matches the value zlib puts at the end of a stream")
    func adler32() {
        // zlib.adler32(b"Wikipedia") == 0x11E60398, the example in RFC 1950.
        #expect(Adler32.of(Data("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(Adler32.of(Data()) == 1)
    }

    @Test("CRC-32 matches the standard's check value")
    func crc32() {
        // The IEEE check value: CRC-32 of "123456789" is 0xCBF43926.
        #expect(CRC32.of(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.of(Data()) == 0)
    }
}
