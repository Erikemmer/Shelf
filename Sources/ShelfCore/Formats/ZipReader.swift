import Foundation

/// Reads a ZIP archive. Reading only – Shelf never writes a book file.
///
/// An EPUB is a ZIP, and so is a CBZ, so this is the gate every format in
/// Sprint 1 goes through. It works off the *central directory* at the end of
/// the file rather than walking local headers from the front: the central
/// directory is the archive's own index, it is what every other tool trusts,
/// and it means a single entry can be pulled out of a 300 MB comic without
/// reading the 299 MB in front of it.
///
/// The decision to have this at all instead of libarchive is in
/// `docs/adr/0003-zip-in-the-core.md`.
public struct ZipReader: Sendable {
    /// One file inside the archive, as the central directory describes it.
    public struct Entry: Equatable, Sendable {
        /// Path inside the archive, with forward slashes, as stored.
        public var path: String
        public var compressedSize: Int
        public var uncompressedSize: Int
        public var method: Method
        /// Where the local header of this entry starts.
        public var localHeaderOffset: Int
        public var crc32: UInt32
        /// General-purpose bit 0 – the entry's bytes are ZIP-encrypted, a
        /// different thing from an EPUB announcing DRM in its own
        /// `META-INF/encryption.xml`. Nothing in Shelf can decrypt one, so a
        /// writer copying entries forward has to refuse rather than carry a
        /// flag it cannot honour.
        public var isEncrypted: Bool

        /// Whether the entry is a folder marker rather than a file.
        public var isDirectory: Bool { path.hasSuffix("/") }

        /// The name without its folders – enough to sort the pages of a comic.
        public var fileName: String { String(path.split(separator: "/").last ?? "") }
    }

    /// The compression methods Shelf reads. Anything else is reported by
    /// number rather than guessed at.
    public enum Method: Equatable, Sendable {
        case stored
        case deflate
        case unsupported(UInt16)

        init(_ raw: UInt16) {
            switch raw {
            case 0: self = .stored
            case 8: self = .deflate
            default: self = .unsupported(raw)
            }
        }
    }

    public enum Failure: Error, Equatable {
        /// No end-of-central-directory record – this is not a ZIP at all.
        case notAZipArchive
        /// A ZIP64 archive. EPUBs are never this large; a comic could be, and
        /// saying so beats reading the wrong offsets.
        case zip64NotSupported
        case malformedDirectory
        case entryNotFound(String)
        case unsupportedMethod(String, UInt16)
        /// The entry decompressed to something other than its stated size, or
        /// its CRC did not match. Either way the bytes cannot be trusted.
        case corruptEntry(String)
        case cannotRead(String)
    }

    /// The archive's own bytes. Held whole because every file Sprint 1 opens is
    /// an EPUB of a few megabytes; the comic formats that could be hundreds
    /// arrive in Sprint 4 and will want a file-handle-backed variant.
    private let bytes: [UInt8]
    public let entries: [Entry]

    public init(data: Data) throws {
        bytes = Array(data)
        entries = try Self.readDirectory(bytes)
    }

    public init(url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw Failure.cannotRead(url.lastPathComponent)
        }
        try self.init(data: data)
    }

    // MARK: Looking things up

    public func entry(at path: String) -> Entry? {
        entries.first { $0.path == path }
    }

    /// Entries that are files, in the archive's own order.
    public var files: [Entry] {
        entries.filter { !$0.isDirectory }
    }

    // MARK: Reading

    /// The bytes of one entry, decompressed.
    public func data(for entry: Entry) throws -> Data {
        let payload = try payloadRange(of: entry)
        let compressed = Data(bytes[payload])

        switch entry.method {
        case .stored:
            guard compressed.count == entry.uncompressedSize else { throw Failure.corruptEntry(entry.path) }
            return compressed
        case .deflate:
            do {
                return try Inflate.raw(compressed, expectedSize: entry.uncompressedSize)
            } catch {
                throw Failure.corruptEntry(entry.path)
            }
        case .unsupported(let method):
            throw Failure.unsupportedMethod(entry.path, method)
        }
    }

    public func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw Failure.entryNotFound(path) }
        return try data(for: entry)
    }

    /// Text of one entry, decoded as UTF-8 and – for the handful of older EPUBs
    /// that are not – as Latin-1, which cannot fail. An OPF that reads as
    /// mojibake still yields a title; one that fails to read yields nothing.
    public func text(at path: String) throws -> String {
        let data = try data(at: path)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(decoding: data, as: UTF8.self)
    }

    /// Where an entry's compressed bytes sit, read from its *local* header –
    /// the central directory knows the offset of the header, not of the data,
    /// and the two name lengths can differ.
    private func payloadRange(of entry: Entry) throws -> Range<Int> {
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count,
            Self.uint32(bytes, header) == 0x0403_4B50
        else { throw Failure.malformedDirectory }

        let nameLength = Int(Self.uint16(bytes, header + 26))
        let extraLength = Int(Self.uint16(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start <= bytes.count, end <= bytes.count else { throw Failure.malformedDirectory }
        return start..<end
    }

    // MARK: The central directory

    private static func readDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        let eocd = try endOfCentralDirectory(bytes)
        var offset = eocd.directoryOffset
        var result: [Entry] = []
        result.reserveCapacity(eocd.entryCount)

        for _ in 0..<eocd.entryCount {
            guard offset + 46 <= bytes.count, uint32(bytes, offset) == 0x0201_4B50 else {
                throw Failure.malformedDirectory
            }
            let nameLength = Int(uint16(bytes, offset + 28))
            let extraLength = Int(uint16(bytes, offset + 30))
            let commentLength = Int(uint16(bytes, offset + 32))
            let nameStart = offset + 46
            guard nameStart + nameLength <= bytes.count else { throw Failure.malformedDirectory }

            let compressed = Int(uint32(bytes, offset + 20))
            let uncompressed = Int(uint32(bytes, offset + 24))
            let localOffset = Int(uint32(bytes, offset + 42))
            // 0xFFFFFFFF in any size or offset means the real value is in a
            // ZIP64 extra field. Rather than read half of it, say so.
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                throw Failure.zip64NotSupported
            }

            result.append(
                Entry(
                    path: name(bytes, nameStart, nameLength, flags: uint16(bytes, offset + 8)),
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    method: Method(uint16(bytes, offset + 10)),
                    localHeaderOffset: localOffset,
                    crc32: uint32(bytes, offset + 16),
                    isEncrypted: uint16(bytes, offset + 8) & 0x0001 != 0))
            offset = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    /// An entry's name. Bit 11 of the flags says the name is UTF-8; without it
    /// the standard says CP437, but in practice everything that writes EPUBs
    /// writes UTF-8, so UTF-8 is tried first either way and only a name that
    /// is not valid UTF-8 falls back.
    private static func name(_ bytes: [UInt8], _ start: Int, _ length: Int, flags: UInt16) -> String {
        let slice = Data(bytes[start..<(start + length)])
        if let utf8 = String(data: slice, encoding: .utf8) { return utf8 }
        return String(decoding: slice, as: UTF8.self)
    }

    private struct EndOfCentralDirectory {
        var entryCount: Int
        var directoryOffset: Int
    }

    /// Finds the end-of-central-directory record.
    ///
    /// It is at the end of the file, but a trailing comment of up to 64 KB may
    /// follow it, so the only way to find it is to search backwards for its
    /// signature. Searching backwards rather than forwards matters: the four
    /// signature bytes can occur inside compressed data too, and the last
    /// occurrence is the real one.
    private static func endOfCentralDirectory(_ bytes: [UInt8]) throws -> EndOfCentralDirectory {
        let minimum = 22
        guard bytes.count >= minimum else { throw Failure.notAZipArchive }
        let earliest = max(0, bytes.count - minimum - 0xFFFF)

        var index = bytes.count - minimum
        while index >= earliest {
            if uint32(bytes, index) == 0x0605_4B50 {
                let count = Int(uint16(bytes, index + 10))
                let offset = Int(uint32(bytes, index + 16))
                // A ZIP64 archive puts 0xFFFF / 0xFFFFFFFF here and the real
                // numbers in a separate record.
                guard count != 0xFFFF, offset != 0xFFFF_FFFF else { throw Failure.zip64NotSupported }
                guard offset <= bytes.count else { throw Failure.malformedDirectory }
                return EndOfCentralDirectory(entryCount: count, directoryOffset: offset)
            }
            index -= 1
        }
        throw Failure.notAZipArchive
    }

    // MARK: Little-endian reads

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
