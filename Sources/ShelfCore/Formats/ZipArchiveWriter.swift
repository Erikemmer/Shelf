import Foundation

/// Writes a ZIP archive from an ordered list of entries.
///
/// `ZipReader` trusts the central directory because some other tool already
/// wrote it correctly; writing has no such directory to trust yet – this type
/// is what has to make the local headers, the central directory and the end
/// record agree with each other and with the bytes in between, in one pass,
/// for every entry it is given.
///
/// **Two ways to hand it an entry, and they mean different things.**
/// `.raw` is bytes Shelf itself produced – an edited OPF, a new cover –
/// always written stored, because there is no reason to compress a handful
/// of small text entries and the format's own hard requirement, `mimetype`,
/// only works stored anyway. `.passthrough` is an entry carried forward from
/// a source archive, compressed bytes and all, never decompressed and never
/// recompressed: a book's own text and images stay exactly the bytes they
/// already were. The first version of this type stored everything, which
/// meant decompressing a DEFLATEd EPUB and storing it back turned every text
/// entry into roughly 2.7 times its own size — "unchanged" in name only.
/// `.passthrough` is what actually keeps that promise (`docs/adr/0021-…`).
///
/// **Refuses rather than mis-writes.** ZIP64 is not implemented: an archive
/// that would need it – more than 65 535 entries, or a size or offset past
/// what a 32-bit field holds – is refused by name before a single byte is
/// written, never truncated into something that merely opens in the tools
/// that are lenient about it. A path that is absolute or climbs out with
/// `..` is refused the same way, before it can name somewhere outside the
/// archive.
public struct ZipArchiveWriter: Sendable {
    /// One file to write, one of two ways.
    public enum Entry: Sendable {
        /// Bytes Shelf itself produced. Always written stored.
        case raw(path: String, data: Data)
        /// An entry carried forward from a source archive: its *compressed*
        /// bytes (`ZipReader.compressedData(for:)`), and the method, sizes,
        /// CRC and modification stamp that describe them — read from the
        /// source archive's own central directory, never recomputed, so a
        /// deflated entry stays deflated rather than being decompressed and
        /// stored again.
        case passthrough(
            path: String, compressedData: Data, method: ZipReader.Method,
            uncompressedSize: Int, crc32: UInt32, modTime: UInt16, modDate: UInt16)

        public static func raw(path: String, text: String) -> Entry {
            .raw(path: path, data: Data(text.utf8))
        }

        public var path: String {
            switch self {
            case .raw(let path, _): return path
            case .passthrough(let path, _, _, _, _, _, _): return path
            }
        }

        /// Whether this entry, as it stands, satisfies EPUB's one hard rule
        /// for `mimetype` – stored, not deflated. Unconditionally true for
        /// `.raw`, since this writer only ever stores one of those; a real
        /// question for `.passthrough`, since carrying a method forward
        /// means storage is no longer automatic the way it used to be.
        var isStored: Bool {
            switch self {
            case .raw: return true
            case .passthrough(_, _, let method, _, _, _, _): return method == .stored
            }
        }

        fileprivate var estimatedPayloadCount: Int {
            switch self {
            case .raw(_, let data): return data.count
            case .passthrough(_, let compressedData, _, _, _, _, _): return compressedData.count
            }
        }
    }

    public enum Failure: Error, Equatable {
        /// More entries than a 32-bit ZIP directory can count without ZIP64.
        case tooManyEntries(Int)
        /// A size or an offset that no longer fits the 32-bit fields this
        /// writer uses – the point at which a real archive would need ZIP64,
        /// which this writer does not speak.
        case archiveTooLarge(String)
        /// A path that is absolute, or that climbs out of the archive with
        /// `..` – neither names somewhere inside it.
        case invalidPath(String)
    }

    /// The largest count or 32-bit field value this writer will produce.
    /// `0xFFFFFFFF` is reserved by the format to mean "see the ZIP64 extra
    /// field", so it is refused here rather than written as a real value.
    static let maximumFieldValue: UInt64 = 0xFFFF_FFFE
    static let maximumEntries = 65_535

    /// A fixed, valid DOS date/time for a `.raw` entry, which has no source
    /// modification stamp to carry forward. `0` for the *time* field is a
    /// real time — midnight — but `0` for the *date* field is month 0, day
    /// 0, which is not a real date and which some tools refuse outright.
    /// `0x0021` is 1 January 1980, the DOS epoch itself: a fixed value that
    /// makes no claim about when this OPF or this cover was actually
    /// written, the same reason several other ZIP tools default to it for
    /// reproducible output.
    static let placeholderModTime: UInt16 = 0x0000
    static let placeholderModDate: UInt16 = 0x0021

    public init() {}

    /// The archive's bytes, or a named refusal instead of a broken file.
    public func archive(_ entries: [Entry]) throws -> Data {
        guard entries.count <= Self.maximumEntries else {
            throw Failure.tooManyEntries(entries.count)
        }

        var output = Data()
        var directory = Data()
        output.reserveCapacity(entries.reduce(0) { $0 + $1.estimatedPayloadCount + 64 })
        directory.reserveCapacity(entries.reduce(0) { $0 + 46 + $1.path.utf8.count })

        for entry in entries {
            guard Self.isValidPath(entry.path) else { throw Failure.invalidPath(entry.path) }
            let name = Data(entry.path.utf8)
            let offset = UInt64(output.count)
            try Self.checkFits(offset, label: "the archive")

            let record = try Self.pack(entry)
            output.append(Self.localHeader(name: name, record: record))
            output.append(record.payload)
            directory.append(Self.directoryRecord(name: name, record: record, offset: offset))
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

    /// A path climbs out of the archive if any component is literally `..`;
    /// a single leading `/` makes it absolute. Both are refused rather than
    /// written, because neither names somewhere inside the archive.
    private static func isValidPath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    // MARK: Packing an entry into what a header needs

    /// What both the local header and the central directory record need,
    /// worked out once per entry rather than twice.
    private struct PackedEntry {
        var payload: Data
        var method: UInt16
        var crc: UInt32
        var uncompressedSize: Int
        var modTime: UInt16
        var modDate: UInt16
    }

    private static func pack(_ entry: Entry) throws -> PackedEntry {
        switch entry {
        case .raw(_, let data):
            try checkFits(UInt64(data.count), label: entry.path)
            return PackedEntry(
                payload: data, method: 0, crc: ZipCRC32.of(data), uncompressedSize: data.count,
                modTime: placeholderModTime, modDate: placeholderModDate)
        case .passthrough(_, let compressedData, let method, let uncompressedSize, let crc32, let modTime, let modDate):
            try checkFits(UInt64(compressedData.count), label: entry.path)
            try checkFits(UInt64(uncompressedSize), label: entry.path)
            return PackedEntry(
                payload: compressedData, method: method.rawValue, crc: crc32, uncompressedSize: uncompressedSize,
                modTime: modTime, modDate: modDate)
        }
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
    ///
    /// **Bit 3, the data-descriptor flag, is deliberately never set — and
    /// never copied from a source entry either.** A `.passthrough` entry's
    /// sizes and CRC come from the source archive's central directory, which
    /// this writer already has in hand, so there is never a reason to defer
    /// them to a trailing descriptor the way a streaming writer would.
    /// Building the flags fresh for every entry, rather than carrying a
    /// source entry's own flags forward, is what makes that automatic rather
    /// than a fact that has to stay true by not being touched.
    private static let generalPurposeFlags: UInt16 = 0x0800

    private static func localHeader(name: Data, record: PackedEntry) -> Data {
        var header = Data()
        header.append(localHeaderSignature)
        header.append(uint16(20))  // version needed: 2.0
        header.append(uint16(generalPurposeFlags))
        header.append(uint16(record.method))
        header.append(uint16(record.modTime))
        header.append(uint16(record.modDate))
        header.append(uint32(record.crc))
        header.append(uint32(UInt32(record.payload.count)))  // compressed size
        header.append(uint32(UInt32(record.uncompressedSize)))
        header.append(uint16(UInt16(name.count)))
        header.append(uint16(0))  // extra field length
        header.append(name)
        return header
    }

    private static func directoryRecord(name: Data, record: PackedEntry, offset: UInt64) -> Data {
        var directoryRecord = Data()
        directoryRecord.append(directorySignature)
        directoryRecord.append(uint16(20))  // version made by
        directoryRecord.append(uint16(20))  // version needed
        directoryRecord.append(uint16(generalPurposeFlags))
        directoryRecord.append(uint16(record.method))
        directoryRecord.append(uint16(record.modTime))
        directoryRecord.append(uint16(record.modDate))
        directoryRecord.append(uint32(record.crc))
        directoryRecord.append(uint32(UInt32(record.payload.count)))
        directoryRecord.append(uint32(UInt32(record.uncompressedSize)))
        directoryRecord.append(uint16(UInt16(name.count)))
        directoryRecord.append(uint16(0))  // extra field length
        directoryRecord.append(uint16(0))  // comment length
        directoryRecord.append(uint16(0))  // disk number start
        directoryRecord.append(uint16(0))  // internal file attributes
        directoryRecord.append(uint32(0))  // external file attributes
        directoryRecord.append(uint32(UInt32(offset)))
        directoryRecord.append(name)
        return directoryRecord
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
///
/// **A second CRC-32, on purpose.** The test target's own ZIP writer
/// already has one, and it already depends on this module — the two could
/// share this. They do not, because the test fixtures this writer is
/// proven against are built by *that* implementation and read back by
/// *this* one: two independent copies of the same sixteen-line algorithm
/// agreeing is part of what the proof is worth. Sharing one would make a
/// bug in it invisible to its own tests. (Naming that writer here would
/// itself be the coupling `ShelfFixturesTests` exists to catch — see its
/// "the core names no test-material builder".)
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
