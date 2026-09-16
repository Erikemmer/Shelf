import Foundation

/// DEFLATE decompression (RFC 1951), in plain Swift.
///
/// Why not a library: an EPUB is a ZIP, and reading one has to work in
/// `ShelfCore`, which builds on Linux so the EPUB reader can be tested in CI
/// without a Mac. `Compression` is Apple-only and libarchive would put the
/// whole format layer behind a system dependency; the decision and what it
/// costs are in `docs/adr/0003-zip-in-the-core.md`. Only *decompression* is
/// here – Shelf never writes a book file.
///
/// The structure follows zlib's reference decoder `puff.c`: a bit reader,
/// canonical Huffman tables as counts-plus-symbols, and a symbol loop. That
/// decoder exists to be read and checked against the standard, which is worth
/// more here than the last few percent of speed.
public enum Inflate {
    public enum Failure: Error, Equatable {
        case truncated
        case invalidBlockType
        case invalidStoredLength
        /// A Huffman code that no symbol in the table has.
        case invalidCode
        /// A back-reference pointing further back than the output is long – the
        /// classic sign of a corrupt or truncated stream.
        case distanceTooFar
        case incompleteTable
        /// The stream decompressed to a different size than the archive
        /// promised, which means one of the two is wrong.
        case sizeMismatch(expected: Int, actual: Int)
    }

    /// Decompresses a raw DEFLATE stream – no zlib or gzip header, which is
    /// what a ZIP entry contains.
    ///
    /// `expectedSize` comes from the ZIP's own central directory. Passing it is
    /// worth two things: the output buffer is allocated once, and a stream that
    /// decodes to the wrong length is reported instead of silently returning
    /// half a file.
    public static func raw(_ input: Data, expectedSize: Int? = nil) throws -> Data {
        var reader = BitReader(Array(input))
        var output: [UInt8] = []
        if let expectedSize { output.reserveCapacity(expectedSize) }

        var isLastBlock = false
        while !isLastBlock {
            isLastBlock = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0: try stored(&reader, into: &output)
            case 1:
                try compressed(&reader, into: &output, literals: Tables.fixedLiterals, distances: Tables.fixedDistances)
            case 2:
                let (literals, distances) = try dynamicTables(&reader)
                try compressed(&reader, into: &output, literals: literals, distances: distances)
            default: throw Failure.invalidBlockType
            }
        }

        if let expectedSize, output.count != expectedSize {
            throw Failure.sizeMismatch(expected: expectedSize, actual: output.count)
        }
        return Data(output)
    }

    // MARK: Block kinds

    /// An uncompressed block: length, its complement, then the bytes.
    private static func stored(_ reader: inout BitReader, into output: inout [UInt8]) throws {
        reader.alignToByte()
        let length = try reader.byte16()
        let complement = try reader.byte16()
        // The complement is the only check the format offers that we are
        // reading a real block boundary and not the middle of something.
        guard length == (~complement & 0xFFFF) else { throw Failure.invalidStoredLength }
        try reader.copyBytes(Int(length), into: &output)
    }

    /// A Huffman-coded block: literals, and back-references into what has
    /// already been written.
    private static func compressed(
        _ reader: inout BitReader, into output: inout [UInt8],
        literals: HuffmanTable, distances: HuffmanTable
    ) throws {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }

            let lengthIndex = symbol - 257
            guard lengthIndex < Tables.lengthBase.count else { throw Failure.invalidCode }
            let length = Int(Tables.lengthBase[lengthIndex]) + Int(try reader.bits(Tables.lengthExtra[lengthIndex]))

            let distanceSymbol = try distances.decode(&reader)
            guard distanceSymbol < Tables.distanceBase.count else { throw Failure.invalidCode }
            let distance =
                Int(Tables.distanceBase[distanceSymbol]) + Int(try reader.bits(Tables.distanceExtra[distanceSymbol]))
            guard distance <= output.count else { throw Failure.distanceTooFar }

            // Byte by byte on purpose: a run may overlap itself (distance 1 is
            // how DEFLATE writes "the same byte 200 times"), so a bulk copy
            // would read bytes this very loop is about to write.
            var from = output.count - distance
            for _ in 0..<length {
                output.append(output[from])
                from += 1
            }
        }
    }

    /// The two tables a dynamic block carries in front of its data.
    private static func dynamicTables(_ reader: inout BitReader) throws -> (HuffmanTable, HuffmanTable) {
        let literalCount = Int(try reader.bits(5)) + 257
        let distanceCount = Int(try reader.bits(5)) + 1
        let codeLengthCount = Int(try reader.bits(4)) + 4

        // The lengths of the code-length code, in the odd order the standard
        // prescribes – short codes first, so a typical file spends fewer bits.
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengths[Tables.codeLengthOrder[index]] = Int(try reader.bits(3))
        }
        let codeLengthTable = try HuffmanTable(lengths: codeLengths)

        // The literal and distance lengths come as one run-length-encoded list.
        var lengths = [Int]()
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            let symbol = try codeLengthTable.decode(&reader)
            switch symbol {
            case 0..<16:
                lengths.append(symbol)
            case 16:
                guard let last = lengths.last else { throw Failure.invalidCode }
                let repeats = Int(try reader.bits(2)) + 3
                lengths.append(contentsOf: repeatElement(last, count: repeats))
            case 17:
                lengths.append(contentsOf: repeatElement(0, count: Int(try reader.bits(3)) + 3))
            case 18:
                lengths.append(contentsOf: repeatElement(0, count: Int(try reader.bits(7)) + 11))
            default:
                throw Failure.invalidCode
            }
        }
        guard lengths.count == literalCount + distanceCount else { throw Failure.invalidCode }

        let literals = try HuffmanTable(lengths: Array(lengths[0..<literalCount]))
        let distances = try HuffmanTable(lengths: Array(lengths[literalCount...]))
        return (literals, distances)
    }
}

// MARK: - Bit reader

/// Reads DEFLATE's bit stream: least significant bit first, within bytes taken
/// in order. Getting that endianness wrong produces plausible-looking garbage,
/// which is why it lives in one small type with its own tests.
struct BitReader {
    private let bytes: [UInt8]
    private var index = 0
    /// Bits pulled from `bytes` but not yet handed out, right-aligned.
    private var buffer: UInt32 = 0
    private var bitCount = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func bits(_ count: Int) throws -> UInt32 {
        guard count > 0 else { return 0 }
        while bitCount < count {
            guard index < bytes.count else { throw Inflate.Failure.truncated }
            buffer |= UInt32(bytes[index]) << UInt32(bitCount)
            index += 1
            bitCount += 8
        }
        let value = buffer & ((1 << UInt32(count)) - 1)
        buffer >>= UInt32(count)
        bitCount -= count
        return value
    }

    /// Drops the rest of the current byte – what a stored block starts with.
    mutating func alignToByte() {
        let extra = bitCount % 8
        buffer >>= UInt32(extra)
        bitCount -= extra
    }

    /// A little-endian 16-bit value, byte-aligned.
    mutating func byte16() throws -> UInt16 {
        let low = try bits(8)
        let high = try bits(8)
        return UInt16(low | (high << 8))
    }

    /// Copies raw bytes straight through – a stored block's payload.
    mutating func copyBytes(_ count: Int, into output: inout [UInt8]) throws {
        for _ in 0..<count {
            output.append(UInt8(try bits(8)))
        }
    }
}

// MARK: - Huffman

/// A canonical Huffman code, stored as how many codes there are of each length
/// and the symbols in code order.
///
/// That shape is what makes decoding a short loop with no tree to walk and no
/// per-node allocation: the counts say where each length's block of codes
/// starts, so a code and its symbol are found by arithmetic.
struct HuffmanTable {
    /// Number of codes of length 1…15; index 0 is unused.
    private var counts: [Int]
    /// Symbols ordered by their code.
    private var symbols: [Int]

    static let maxBits = 15

    init(lengths: [Int]) throws {
        guard lengths.allSatisfy({ $0 >= 0 && $0 <= Self.maxBits }) else {
            throw Inflate.Failure.incompleteTable
        }
        self.init(validatedLengths: lengths)
    }

    /// For the standard's own fixed tables, whose lengths are known good.
    /// Saves the call sites a `try` they could never take.
    init(validatedLengths lengths: [Int]) {
        var counts = [Int](repeating: 0, count: Self.maxBits + 1)
        for length in lengths where length > 0 {
            counts[length] += 1
        }
        self.counts = counts
        // Symbols sorted by code length and then by symbol – the canonical
        // order the standard defines, which is what makes the decode loop's
        // arithmetic land on the right symbol. All-zero lengths is a legal,
        // unused table (a block with no distance codes) and gives no symbols.
        var ordered: [Int] = []
        ordered.reserveCapacity(lengths.count)
        for length in 1...Self.maxBits {
            for (symbol, symbolLength) in lengths.enumerated() where symbolLength == length {
                ordered.append(symbol)
            }
        }
        symbols = ordered
    }

    /// Reads one symbol. Walks the lengths, adding a bit each time, which is
    /// exactly how a canonical code is defined.
    func decode(_ reader: inout BitReader) throws -> Int {
        var code = 0
        var first = 0
        var index = 0
        for length in 1...Self.maxBits {
            code |= Int(try reader.bits(1))
            let count = counts[length]
            if code - first < count {
                return symbols[index + (code - first)]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }
        throw Inflate.Failure.invalidCode
    }
}

// MARK: - The standard's tables

/// The constant tables from RFC 1951. Reference data, copied from the standard
/// rather than computed, so they can be checked against it line by line.
enum Tables {
    static let lengthBase: [UInt16] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    static let distanceBase: [UInt16] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1_025, 1_537, 2_049, 3_073, 4_097, 6_145, 8_193, 12_289, 16_385, 24_577,
    ]
    static let distanceExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
    /// The order the code-length lengths arrive in.
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// The fixed literal/length code: 0…143 are 8 bits, 144…255 nine,
    /// 256…279 seven, 280…287 eight.
    static let fixedLiterals: HuffmanTable = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144...255 { lengths[symbol] = 9 }
        for symbol in 256...279 { lengths[symbol] = 7 }
        return HuffmanTable(validatedLengths: lengths)
    }()

    /// The fixed distance code: thirty 5-bit codes.
    static let fixedDistances = HuffmanTable(validatedLengths: [Int](repeating: 5, count: 30))
}
