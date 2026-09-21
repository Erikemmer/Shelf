import Foundation

/// Writes a ZIP archive from an ordered list of entries.
///
/// `ZipReader` trusts the central directory because some other tool already
/// wrote it correctly; writing has no such directory to trust yet – this type
/// is what has to make the local headers, the central directory and the end
/// record agree with each other and with the bytes in between, in one pass,
/// for every entry it is given.
///
/// **Stored only, never DEFLATE.** A compressor is a second, harder-to-get-
/// exactly-right algorithm, and Shelf's reason to write a ZIP at all is to
/// change a handful of small text entries inside an archive whose large
/// entries – a book's own text and images – pass through unchanged
/// (`docs/adr/0021-…`). Storing everything costs disk space this project has
/// never economised on; a wrong DEFLATE stream costs a corrupted book.
///
/// **Refuses rather than mis-writes.** ZIP64 is not implemented: an archive
/// that would need it – more than 65 535 entries, or a size or offset past
/// what a 32-bit field holds – is refused by name before a single byte is
/// written, never truncated into something that merely opens in the tools
/// that are lenient about it.
public struct ZipArchiveWriter: Sendable {
    /// One file to write. Always stored; there is no compressed variant to
    /// choose, so there is nothing here to get wrong.
    public struct Entry: Sendable {
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

    public enum Failure: Error, Equatable {
        /// More entries than a 32-bit ZIP directory can count without ZIP64.
        case tooManyEntries(Int)
        /// A size or an offset that no longer fits the 32-bit fields this
        /// writer uses – the point at which a real archive would need ZIP64,
        /// which this writer does not speak.
        case archiveTooLarge(String)
    }

    /// The largest count or 32-bit field value this writer will produce.
    /// `0xFFFFFFFF` is reserved by the format to mean "see the ZIP64 extra
    /// field", so it is refused here rather than written as a real value.
    static let maximumFieldValue: UInt64 = 0xFFFF_FFFE
    static let maximumEntries = 65_535

    public init() {}

    /// The archive's bytes, or a named refusal instead of a broken file.
    public func archive(_ entries: [Entry]) throws -> Data {
        guard entries.count <= Self.maximumEntries else {
            throw Failure.tooManyEntries(entries.count)
        }

        var output = Data()
        var directory = Data()
        output.reserveCapacity(entries.reduce(0) { $0 + $1.data.count + 64 })

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = ZipCRC32.of(entry.data)
            let offset = UInt64(output.count)
            try Self.checkFits(offset, label: "the archive")
            try Self.checkFits(UInt64(entry.data.count), label: entry.path)

            output.append(Self.localHeader(name: name, dataCount: entry.data.count, crc: crc))
            output.append(entry.data)

            directory.append(
                Self.directoryRecord(name: name, dataCount: entry.data.count, crc: crc, offset: offset))
        }

        let directoryOffset = UInt64(output.count)
        try Self.checkFits(directoryOffset, label: "the archive")
        output.append(directory)
        output.append(
            Self.endRecord(count: entries.count, directorySize: directory.count, directoryOffset: directoryOffset))
        return output
    }

    /// Whether a 32-bit ZIP field can hold this value. Exposed for a direct
    /// test of the boundary itself, rather than one that would need to
    /// allocate a multi-gigabyte `Data` to exercise it for real.
    static func fits32Bits(_ value: UInt64) -> Bool {
        value <= maximumFieldValue
    }

    private static func checkFits(_ value: UInt64, label: String) throws {
        guard fits32Bits(value) else { throw Failure.archiveTooLarge(label) }
    }

    // MARK: Records

    /// General-purpose flags this writer always writes: bit 11, "the name and
    /// comment are UTF-8" (the *language encoding flag*, EFS). Every path
    /// this writer is given is a Swift `String`, encoded as UTF-8 below, so
    /// this is always true and never a per-entry decision — and declaring it
    /// is what stops another tool from guessing CP437 and mangling a name
    /// with an umlaut or a Cyrillic letter in it, the same way `ZipReader`'s
    /// own name-decoding tries UTF-8 unconditionally rather than trusting
    /// this bit either.
    private static let generalPurposeFlags: UInt16 = 0x0800

    private static func localHeader(name: Data, dataCount: Int, crc: UInt32) -> Data {
        var header = Data()
        header.append(localHeaderSignature)
        header.append(uint16(20))  // version needed: 2.0
        header.append(uint16(generalPurposeFlags))
        header.append(uint16(0))  // method: stored
        header.append(uint16(0))  // modification time
        header.append(uint16(0))  // modification date
        header.append(uint32(crc))
        header.append(uint32(UInt32(dataCount)))  // compressed size: stored, so identical
        header.append(uint32(UInt32(dataCount)))  // uncompressed size
        header.append(uint16(UInt16(name.count)))
        header.append(uint16(0))  // extra field length
        header.append(name)
        return header
    }

    private static func directoryRecord(name: Data, dataCount: Int, crc: UInt32, offset: UInt64) -> Data {
        var record = Data()
        record.append(directorySignature)
        record.append(uint16(20))  // version made by
        record.append(uint16(20))  // version needed
        record.append(uint16(generalPurposeFlags))
        record.append(uint16(0))  // method: stored
        record.append(uint16(0))  // modification time
        record.append(uint16(0))  // modification date
        record.append(uint32(crc))
        record.append(uint32(UInt32(dataCount)))
        record.append(uint32(UInt32(dataCount)))
        record.append(uint16(UInt16(name.count)))
        record.append(uint16(0))  // extra field length
        record.append(uint16(0))  // comment length
        record.append(uint16(0))  // disk number start
        record.append(uint16(0))  // internal file attributes
        record.append(uint32(0))  // external file attributes
        record.append(uint32(UInt32(offset)))
        record.append(name)
        return record
    }

    private static func endRecord(count: Int, directorySize: Int, directoryOffset: UInt64) -> Data {
        var record = Data()
        record.append(endSignature)
        record.append(uint16(0))  // this disk
        record.append(uint16(0))  // disk with the directory's start
        record.append(uint16(UInt16(count)))  // entries on this disk
        record.append(uint16(UInt16(count)))  // entries in total
        record.append(uint32(UInt32(directorySize)))
        record.append(uint32(UInt32(directoryOffset)))
        record.append(uint16(0))  // comment length
        return record
    }

    private static let localHeaderSignature = Data([0x50, 0x4B, 0x03, 0x04])
    private static let directorySignature = Data([0x50, 0x4B, 0x01, 0x02])
    private static let endSignature = Data([0x50, 0x4B, 0x05, 0x06])

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }
}

/// CRC-32 as the ZIP format uses it.
///
/// `ZipReader` reads the field every entry carries but never computes one –
/// nothing there needed to. Writing does: every reader that checks it (which
/// is most of them) would reject an archive with the wrong value, so this is
/// not optional the way it would be for a reader that only reads its own
/// output back.
enum ZipCRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func of(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
