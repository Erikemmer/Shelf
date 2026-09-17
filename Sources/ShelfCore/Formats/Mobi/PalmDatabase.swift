import Foundation

/// The container MOBI, AZW and AZW3 all sit in: Palm's old database format.
///
/// A 78-byte header, then one 8-byte entry per record saying where that record
/// starts, then the records themselves. Nothing in it is specific to books —
/// it was a PalmPilot file format — and that is the point of reading it
/// separately: the container is simple and well documented, and everything that
/// varies between MOBI versions is *inside* record 0.
///
/// Big-endian throughout, which is the one thing most likely to be got wrong by
/// somebody arriving from the ZIP reader next door (that one is little-endian).
///
/// Written from the public format descriptions (the MobileRead wiki's
/// `MOBI` and `PDB` pages). No Amazon code and no DRM handling of any kind is
/// involved: an encrypted file is recognised as encrypted and left alone
/// (CONCEPT §12).
struct PalmDatabase {
    /// The 32-byte name at the front, trimmed of its padding. Often the book's
    /// title with spaces replaced, which is why it is a last-resort fallback
    /// and not a source of metadata.
    let name: String
    /// `BOOK` for a book. Kept because a `TEXt`/`REAd` file is a PalmDOC and
    /// not a Mobipocket, and saying which it is beats saying "unreadable".
    let type: String
    /// `MOBI` for Mobipocket and Kindle files.
    let creator: String
    /// Each record's bytes, in order. Record 0 is the header record.
    private let records: [Range<Int>]
    private let bytes: [UInt8]

    var recordCount: Int { records.count }

    enum Failure: Error, Equatable {
        case tooShort
        case notAPalmDatabase
        /// The record table points outside the file. A truncated download,
        /// usually.
        case damaged(String)
    }

    static let headerLength = 78

    init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.headerLength else { throw Failure.tooShort }
        self.bytes = bytes

        name = Self.text(bytes, 0, 32)
        type = Self.text(bytes, 60, 4)
        creator = Self.text(bytes, 64, 4)

        let count = Int(Self.uint16(bytes, 76))
        // A file claiming more records than could possibly fit is damaged, and
        // saying so beats reading 60 000 garbage offsets.
        guard count > 0, Self.headerLength + count * 8 <= bytes.count else {
            throw Failure.damaged("record table of \(count) entries does not fit in \(bytes.count) bytes")
        }

        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for index in 0..<count {
            offsets.append(Int(Self.uint32(bytes, Self.headerLength + index * 8)))
        }

        // A record runs to the start of the next one, and the last to the end
        // of the file. Offsets that run backwards or past the end are clamped
        // rather than thrown: a file with one bad record still has the others,
        // and record 0 is the only one metadata needs.
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(count)
        for index in 0..<count {
            let start = min(max(offsets[index], 0), bytes.count)
            let end = index + 1 < count ? min(max(offsets[index + 1], start), bytes.count) : bytes.count
            ranges.append(start..<end)
        }
        records = ranges
    }

    /// The bytes of one record, or nil when there is no such record.
    func record(_ index: Int) -> [UInt8]? {
        guard records.indices.contains(index) else { return nil }
        return Array(bytes[records[index]])
    }

    /// Whether this looks like a Mobipocket/Kindle book rather than some other
    /// Palm database that happens to be on the disk.
    var looksLikeABook: Bool { creator == "MOBI" || creator == "BOOK" || type == "BOOK" }

    // MARK: Reading bytes

    /// Big-endian, unlike the ZIP reader next door.
    static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    /// A fixed-width, null-padded ASCII field.
    static func text(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= bytes.count else { return "" }
        let slice = bytes[offset..<(offset + length)].prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
