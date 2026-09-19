import Foundation
import ShelfCore

/// Writes a MOBI or AZW3 file that nobody wrote, for the tests and the proof
/// run to read.
///
/// No borrowed book is in this repository and none needs to be (CLAUDE.md). The
/// fixtures are built from the same public format description the reader was
/// written from — which is worth being honest about: a fixture built by the
/// author of the parser can agree with the parser and with nothing else. That
/// is why the *byte layout* here is written out longhand from the format
/// description, with its offsets spelled as numbers rather than borrowed from
/// `MobiHeader`'s constants: the two halves are meant to be able to disagree.
///
/// Nothing here writes DRM. `withKindleDRM` writes the EXTH record that
/// *announces* Kindle DRM (209) and sets the encryption byte — the file is not
/// actually encrypted, because Shelf's whole claim about DRM is that it looks at
/// those two flags and then stops. A fixture that were really encrypted would
/// test nothing extra and would be a thing this repository should not hold.
public struct SyntheticMobi: Sendable {
    public var book: Book
    public var cover: Data?
    /// AZW3 rather than MOBI. Same container, and the difference Shelf cares
    /// about is only the file's extension — which is the honest state of
    /// affairs and is said so in ADR 0011.
    public var isAZW3: Bool
    /// Writes EXTH 209 and a non-zero encryption type: what a protected file
    /// announces. The bytes stay readable.
    public var withKindleDRM: Bool
    /// Leaves out the MOBI header, so record 0 is a bare PalmDOC. A real file
    /// like this exists (old PalmDOC books) and the reader has to fall back to
    /// the file name rather than fail.
    public var withoutMobiHeader: Bool
    /// Writes a *different* title into EXTH 503 from the one in the MOBI
    /// header's own name field. Real files do this — the header's name is what
    /// the file was called when it was built, and 503 is what the publisher
    /// last said — and it is the only way to check which of the two Shelf
    /// prefers.
    public var updatedTitle: String?

    public init(
        book: Book, cover: Data? = nil, isAZW3: Bool = false, withKindleDRM: Bool = false,
        withoutMobiHeader: Bool = false, updatedTitle: String? = nil
    ) {
        self.book = book
        self.cover = cover
        self.isAZW3 = isAZW3
        self.withKindleDRM = withKindleDRM
        self.withoutMobiHeader = withoutMobiHeader
        self.updatedTitle = updatedTitle
    }

    public var fileExtension: String { isAZW3 ? "azw3" : "mobi" }

    /// The finished file.
    public func data() -> Data {
        var records: [[UInt8]] = [record0()]
        // One text record, so the file is shaped like a book rather than like a
        // header with nothing after it.
        records.append(Array("This is synthetic test material.".utf8))
        if let cover { records.append([UInt8](cover)) }

        var out = palmHeader(recordCount: records.count)
        // The record table's offsets are absolute, so they can only be filled
        // in once the header's own length is known.
        var offset = 78 + records.count * 8
        // Palm pads the record table to an even boundary with two bytes.
        offset += 2
        var table: [UInt8] = []
        for record in records {
            table += beUInt32(UInt32(offset))
            table += [0, 0, 0, 0]  // attributes and a 3-byte unique id
            offset += record.count
        }
        out += table
        out += [0, 0]
        for record in records { out += record }
        return Data(out)
    }

    // MARK: The container

    private func palmHeader(recordCount: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 78)
        // 0..31: the name, null-padded. Palm truncates at 31 characters plus
        // the terminator, which is why it is never used as a title.
        let name = Array(book.title.replacingOccurrences(of: " ", with: "_").utf8.prefix(31))
        for (index, byte) in name.enumerated() { out[index] = byte }
        // 60..63 type, 64..67 creator.
        for (index, byte) in Array("BOOK".utf8).enumerated() { out[60 + index] = byte }
        for (index, byte) in Array("MOBI".utf8).enumerated() { out[64 + index] = byte }
        // 76..77: the number of records, big-endian.
        out[76] = UInt8((recordCount >> 8) & 0xFF)
        out[77] = UInt8(recordCount & 0xFF)
        return out
    }

    // MARK: Record 0

    private func record0() -> [UInt8] {
        var out = [UInt8]()

        // ── PalmDOC header, 16 bytes ───────────────────────────────────────
        out += beUInt16(1)  // compression: none
        out += beUInt16(0)  // unused
        out += beUInt32(32)  // text length
        out += beUInt16(1)  // text record count
        out += beUInt16(4096)  // record size
        out += beUInt16(withKindleDRM ? 2 : 0)  // encryption type
        out += beUInt16(0)  // unused

        guard !withoutMobiHeader else { return out }

        // ── MOBI header ────────────────────────────────────────────────────
        // Its length is fixed at 232, the common modern value, so that every
        // field the reader looks for is inside it.
        let mobiHeaderLength = 232
        var mobi = [UInt8]()
        mobi += Array("MOBI".utf8)  // +0
        mobi += beUInt32(UInt32(mobiHeaderLength))  // +4
        mobi += beUInt32(isAZW3 ? 8 : 2)  // +8  mobi type
        mobi += beUInt32(65001)  // +12 text encoding: UTF-8
        mobi += beUInt32(0x1234_5678)  // +16 unique id
        mobi += beUInt32(isAZW3 ? 8 : 6)  // +20 file version
        mobi += [UInt8](repeating: 0xFF, count: 40)  // +24..+63 the index fields, all unset
        // +64 first non-book index
        mobi += beUInt32(0xFFFF_FFFF)
        // +68 full name offset, +72 full name length. The name is written after
        // the EXTH block, so the offset is filled in below.
        let fullNameOffsetField = mobi.count
        mobi += beUInt32(0)
        mobi += beUInt32(0)
        mobi += beUInt32(9)  // +76 locale: en
        mobi += beUInt32(0)  // +80 input language
        mobi += beUInt32(0)  // +84 output language
        mobi += beUInt32(6)  // +88 min version
        // +92 first image index: record 2 when there is a cover (0 = header,
        // 1 = text), and unset when there is none.
        mobi += beUInt32(cover == nil ? 0xFFFF_FFFF : 2)
        mobi += beUInt32(0)  // +96  huffman record offset
        mobi += beUInt32(0)  // +100 huffman record count
        mobi += beUInt32(0)  // +104 huffman table offset
        mobi += beUInt32(0)  // +108 huffman table length
        mobi += beUInt32(0x40)  // +112 EXTH flags: EXTH present
        // Pad out to the declared length.
        while mobi.count < mobiHeaderLength { mobi.append(0) }

        let exth = exthBlock()
        // The full name sits after the EXTH block, and its offset is counted
        // from the start of record 0 — which is the PalmDOC header's 16 bytes
        // plus the MOBI header plus EXTH.
        let fullName = Array(book.title.utf8)
        let fullNameOffset = 16 + mobi.count + exth.count
        let offsetBytes = beUInt32(UInt32(fullNameOffset))
        let lengthBytes = beUInt32(UInt32(fullName.count))
        for index in 0..<4 { mobi[fullNameOffsetField + index] = offsetBytes[index] }
        for index in 0..<4 { mobi[fullNameOffsetField + 4 + index] = lengthBytes[index] }

        out += mobi
        out += exth
        out += fullName
        out += [0, 0]  // the two null bytes a real file ends the name with
        return out
    }

    private func exthBlock() -> [UInt8] {
        var records: [(UInt32, [UInt8])] = []
        for author in book.authors { records.append((100, Array(author.utf8))) }
        if let publisher = book.publisher { records.append((101, Array(publisher.utf8))) }
        if let description = book.description { records.append((103, Array(description.utf8))) }
        if let isbn = book.identifiers["isbn"] { records.append((104, Array(isbn.utf8))) }
        for tag in book.tags { records.append((105, Array(tag.utf8))) }
        if let published = book.published {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            records.append((106, Array(formatter.string(from: published).utf8)))
        }
        if let language = book.language { records.append((524, Array(language.utf8))) }
        // 201: the cover's offset from the first image record — 0, because the
        // cover is the first image this fixture writes.
        if cover != nil { records.append((201, beUInt32(0))) }
        // The announcement of Kindle DRM, and nothing more: the file stays
        // readable. Shelf looks at this flag and stops, which is the claim.
        if withKindleDRM { records.append((209, [0x00, 0x01, 0x02, 0x03])) }
        // 503: the title, which is what Shelf prefers over the header's name.
        records.append((503, Array((updatedTitle ?? book.title).utf8)))

        var body = [UInt8]()
        for (type, payload) in records {
            body += beUInt32(type)
            body += beUInt32(UInt32(payload.count + 8))
            body += payload
        }

        var out = Array("EXTH".utf8)
        // The length counts the 12 bytes of the EXTH header itself, and the
        // whole block is padded to a multiple of four.
        var length = 12 + body.count
        let padding = (4 - (length % 4)) % 4
        length += padding
        out += beUInt32(UInt32(length))
        out += beUInt32(UInt32(records.count))
        out += body
        out += [UInt8](repeating: 0, count: padding)
        return out
    }

    // MARK: Bytes

    private func beUInt16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func beUInt32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
    }
}
