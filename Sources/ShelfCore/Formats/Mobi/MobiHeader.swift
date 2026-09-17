import Foundation

/// Record 0 of a MOBI/AZW3 file: the PalmDOC header, the MOBI header and the
/// EXTH records.
///
/// The offsets below are the public ones (MobileRead's `MOBI` page). They are
/// written as named constants rather than as numbers in the code because every
/// one of them is a place a typo produces a plausible-looking wrong answer
/// rather than a failure — a title read four bytes early is still a string.
struct MobiHeader {
    /// PalmDOC header, the first 16 bytes of record 0.
    enum PalmDoc {
        static let compression = 0
        static let textLength = 4
        static let recordCount = 8
        static let recordSize = 10
        /// 0 = none, 1 = the old Mobipocket scheme, 2 = Mobipocket. Anything
        /// but 0 means the text is encrypted.
        static let encryptionType = 12
        static let length = 16
    }

    /// The MOBI header proper, which starts where the PalmDOC header ends.
    /// Offsets are from the start of *record 0*, the 16 already added.
    enum Mobi {
        static let identifier = 16
        static let headerLength = 20
        static let mobiType = 24
        static let textEncoding = 28
        static let uniqueID = 32
        static let fileVersion = 36
        static let fullNameOffset = 84
        static let fullNameLength = 88
        static let locale = 92
        static let firstImageIndex = 108
        static let exthFlags = 128
    }

    /// Set in `exthFlags` when EXTH records follow the MOBI header.
    static let exthPresentFlag: UInt32 = 0x40

    let record0: [UInt8]
    /// 65001 = UTF-8, 1252 = Windows-1252. Everything else is treated as 1252,
    /// which is what the format's own default is.
    let textEncoding: UInt32
    /// Where the images start, as a record number. `nil` when the header is too
    /// short to say — old MOBI 4 files.
    let firstImageIndex: Int?
    /// Not zero means the text is encrypted. Shelf reads the metadata it can
    /// and never the text, so this is a badge and not a barrier.
    let encryptionType: UInt16
    /// The title from the MOBI header, which is not the same field as EXTH 503
    /// and is often the one that is right.
    let fullName: String?
    let exth: [UInt32: [[UInt8]]]

    enum Failure: Error, Equatable {
        case notMobi
    }

    init(record0: [UInt8]) throws {
        self.record0 = record0
        guard record0.count >= Mobi.identifier + 4,
            PalmDatabase.text(record0, Mobi.identifier, 4) == "MOBI"
        else { throw Failure.notMobi }

        encryptionType = PalmDatabase.uint16(record0, PalmDoc.encryptionType)
        let headerLength = Int(PalmDatabase.uint32(record0, Mobi.headerLength))
        let encoding = PalmDatabase.uint32(record0, Mobi.textEncoding)
        textEncoding = encoding == 0 ? 1252 : encoding

        // The header says how long it is, and short headers simply do not have
        // the later fields. Reading past the end of a short header is how a
        // parser starts inventing cover offsets.
        let headerEnd = Mobi.identifier + headerLength
        func hasField(_ absoluteOffset: Int) -> Bool { absoluteOffset + 4 <= headerEnd }

        if hasField(Mobi.firstImageIndex) {
            let raw = Int(PalmDatabase.uint32(record0, Mobi.firstImageIndex))
            // 0xFFFFFFFF is the format's "not set", and so in practice is 0.
            firstImageIndex = (raw > 0 && raw < 0xFFFF_FFF0) ? raw : nil
        } else {
            firstImageIndex = nil
        }

        if hasField(Mobi.fullNameOffset), hasField(Mobi.fullNameLength) {
            let offset = Int(PalmDatabase.uint32(record0, Mobi.fullNameOffset))
            let length = Int(PalmDatabase.uint32(record0, Mobi.fullNameLength))
            fullName = Self.string(record0, offset: offset, length: length, encoding: textEncoding)
        } else {
            fullName = nil
        }

        let flags = hasField(Mobi.exthFlags) ? PalmDatabase.uint32(record0, Mobi.exthFlags) : 0
        exth =
            (flags & Self.exthPresentFlag) != 0
            ? Self.readEXTH(record0, startingAt: headerEnd) : [:]
    }

    // MARK: EXTH

    /// The EXTH block: `EXTH`, its length, a count, then that many
    /// type/length/payload records.
    ///
    /// A dictionary of *lists*, because a book with three subjects has three
    /// EXTH 105 records and keeping only the last would lose two tags.
    static func readEXTH(_ bytes: [UInt8], startingAt start: Int) -> [UInt32: [[UInt8]]] {
        guard start >= 0, start + 12 <= bytes.count,
            PalmDatabase.text(bytes, start, 4) == "EXTH"
        else { return [:] }

        let count = Int(PalmDatabase.uint32(bytes, start + 8))
        let blockEnd = min(start + Int(PalmDatabase.uint32(bytes, start + 4)), bytes.count)

        var result: [UInt32: [[UInt8]]] = [:]
        var cursor = start + 12
        var read = 0
        while read < count, cursor + 8 <= blockEnd {
            let type = PalmDatabase.uint32(bytes, cursor)
            let length = Int(PalmDatabase.uint32(bytes, cursor + 4))
            // A record shorter than its own header, or longer than the block,
            // means the file is damaged: stop rather than walk off the end.
            guard length >= 8, cursor + length <= blockEnd else { break }
            result[type, default: []].append(Array(bytes[(cursor + 8)..<(cursor + length)]))
            cursor += length
            read += 1
        }
        return result
    }

    /// The first value of an EXTH record, as text.
    func string(_ type: UInt32) -> String? {
        guard let payload = exth[type]?.first else { return nil }
        return Self.decode(payload, encoding: textEncoding)
    }

    /// Every value of an EXTH record, as text — subjects, contributors.
    func strings(_ type: UInt32) -> [String] {
        (exth[type] ?? []).compactMap { Self.decode($0, encoding: textEncoding) }
    }

    /// A 4-byte EXTH value read as a number: the cover offset is one.
    func number(_ type: UInt32) -> UInt32? {
        guard let payload = exth[type]?.first, payload.count >= 4 else { return nil }
        return PalmDatabase.uint32(payload, 0)
    }

    // MARK: Text

    static func string(_ bytes: [UInt8], offset: Int, length: Int, encoding: UInt32) -> String? {
        guard length > 0, offset >= 0, offset + length <= bytes.count else { return nil }
        return decode(Array(bytes[offset..<(offset + length)]), encoding: encoding)
    }

    /// EXTH payloads are text in the file's own encoding.
    ///
    /// UTF-8 is tried first whatever the header claims, because plenty of files
    /// say 1252 and hold UTF-8; Windows-1252 is the fallback and cannot fail,
    /// which is what keeps a book with one odd byte in its title from losing
    /// its title altogether. `String(decoding:as:)` would not do — it replaces
    /// bad bytes with U+FFFD rather than telling us, so the check is explicit.
    static func decode(_ payload: [UInt8], encoding: UInt32) -> String? {
        guard !payload.isEmpty else { return nil }
        let trimmed = Array(payload.reversed().drop { $0 == 0 }.reversed())
        guard !trimmed.isEmpty else { return nil }

        if let utf8 = String(bytes: trimmed, encoding: .utf8) {
            return utf8.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : utf8.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Windows-1252 by hand rather than through `String.Encoding`, because
        // swift-corelibs-foundation on Linux does not carry the single-byte
        // code pages and the core has to build there.
        let text = String(trimmed.map { Windows1252.character($0) })
        let tidied = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return tidied.isEmpty ? nil : tidied
    }
}

/// Windows-1252, as a table.
///
/// Reference data, not an `if` chain, and here rather than borrowed from
/// Foundation because `String.Encoding.windowsCP1252` does not exist in
/// swift-corelibs-foundation and `ShelfCore` builds on Linux. Only the 0x80–0x9F
/// range differs from Latin-1; everything else maps to the same code point.
enum Windows1252 {
    /// 0x80…0x9F. The one stretch where Windows-1252 and Latin-1 disagree, and
    /// the stretch that holds the curly quotes and dashes half of all book
    /// titles are punctuated with.
    static let high: [Character] = [
        "\u{20AC}", "\u{FFFD}", "\u{201A}", "\u{0192}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
        "\u{02C6}", "\u{2030}", "\u{0160}", "\u{2039}", "\u{0152}", "\u{FFFD}", "\u{017D}", "\u{FFFD}",
        "\u{FFFD}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
        "\u{02DC}", "\u{2122}", "\u{0161}", "\u{203A}", "\u{0153}", "\u{FFFD}", "\u{017E}", "\u{0178}",
    ]

    static func character(_ byte: UInt8) -> Character {
        guard byte >= 0x80, byte <= 0x9F else {
            return Character(UnicodeScalar(byte))
        }
        return high[Int(byte) - 0x80]
    }
}
