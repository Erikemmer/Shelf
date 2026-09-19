import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// Reading MOBI and AZW3.
///
/// The fixtures are written by `SyntheticMobi` from the same public format
/// description the reader was written from, which is worth saying plainly: a
/// fixture built by the author of the parser can agree with the parser and with
/// nothing else. Two things are done about that. The byte layout in the fixture
/// is written out longhand, with its offsets as numbers rather than borrowed
/// from `MobiHeader`'s constants, so a typo in one does not cancel a typo in
/// the other. And several tests below assert against *fixed byte positions*
/// rather than against whatever the writer happened to produce.
///
/// What this does not prove is that a MOBI bought from Amazon in 2011 parses.
/// Only a real file proves that, and none is in this repository.
@Suite("Reading MOBI and AZW3")
struct MobiMetadataTests {

    private func read(_ mobi: SyntheticMobi, name: String = "Fixture") throws -> MobiMetadata.Result {
        try MobiMetadata.read(Array(mobi.data()), fallbackTitle: name)
    }

    // MARK: The container

    @Test("the PalmDB header is read: name, type, creator and the record table")
    func palmContainer() throws {
        let mobi = SyntheticMobi(book: Book(title: "Emma", authors: ["Jane Austen"]))
        let database = try PalmDatabase(bytes: Array(mobi.data()))

        #expect(database.type == "BOOK")
        #expect(database.creator == "MOBI")
        #expect(database.looksLikeABook)
        // Header record and one text record; no cover was given.
        #expect(database.recordCount == 2)
        #expect(database.record(0) != nil)
        #expect(database.record(99) == nil)
    }

    /// Big-endian, which is the one thing most likely to be got wrong by
    /// somebody arriving from the little-endian ZIP reader next door. Checked
    /// against bytes written by hand rather than against the fixture.
    @Test("the container's numbers are big-endian")
    func bigEndian() {
        #expect(PalmDatabase.uint16([0x12, 0x34], 0) == 0x1234)
        #expect(PalmDatabase.uint32([0x12, 0x34, 0x56, 0x78], 0) == 0x1234_5678)
        // Past the end answers zero rather than trapping: a truncated download
        // is a file this reader has to survive.
        #expect(PalmDatabase.uint32([0x12, 0x34], 0) == 0)
        #expect(PalmDatabase.uint16([], 0) == 0)
    }

    @Test("a file that is not a Palm database is refused, not guessed at")
    func refusesRubbish() {
        #expect(throws: MobiMetadata.Failure.self) {
            try MobiMetadata.read(Array("this is not a book".utf8), fallbackTitle: "x")
        }
        #expect(throws: MobiMetadata.Failure.self) {
            try MobiMetadata.read([], fallbackTitle: "x")
        }
    }

    @Test("a record table that does not fit in the file is called damaged")
    func damagedRecordTable() {
        var bytes = [UInt8](repeating: 0, count: 78)
        for (index, byte) in Array("BOOK".utf8).enumerated() { bytes[60 + index] = byte }
        for (index, byte) in Array("MOBI".utf8).enumerated() { bytes[64 + index] = byte }
        // 10 000 records claimed, and 78 bytes of file.
        bytes[76] = 0x27
        bytes[77] = 0x10
        #expect(throws: PalmDatabase.Failure.self) { try PalmDatabase(bytes: bytes) }
    }

    // MARK: EXTH

    @Test("title, author, publisher, description, ISBN, tags and date come out of EXTH")
    func everyField() throws {
        var book = Book(
            title: "The Fifth Season", authors: ["N. K. Jemisin"],
            publisher: "Orbit", language: "en",
            description: "The first of the Broken Earth.", tags: ["science fiction", "hugo"],
            identifiers: ["isbn": "9780316229296"])
        book.published = MobiMetadata.date(from: "2015-08-04")

        let result = try read(SyntheticMobi(book: book), name: "whatever the file is called")
        #expect(result.book.title == "The Fifth Season")
        #expect(result.book.authors == ["N. K. Jemisin"])
        #expect(result.book.publisher == "Orbit")
        #expect(result.book.description == "The first of the Broken Earth.")
        #expect(result.book.identifiers["isbn"] == "9780316229296")
        #expect(result.book.tags == ["hugo", "science fiction"])
        #expect(result.book.language == "en")
        #expect(result.book.published == MobiMetadata.date(from: "2015-08-04"))
        #expect(result.drm == nil)
    }

    /// The article moves to the end, the same as for every other format: a
    /// library that sorts "The Hobbit" under T is one nobody can search.
    @Test("the title sort is derived, not left as the title")
    func titleSort() throws {
        let result = try read(SyntheticMobi(book: Book(title: "The Hobbit", authors: ["Tolkien"])))
        #expect(result.book.titleSort == "Hobbit, The")
    }

    /// A comma is not an author separator in MOBI, and that is the whole
    /// difficulty: these files overwhelmingly write authors surname-first, so
    /// splitting on commas turns one author into two half-people.
    @Test("a surname-first author stays one author; an ampersand makes two")
    func authorSplitting() {
        #expect(MobiMetadata.splitAuthors("Le Guin, Ursula K.") == ["Le Guin, Ursula K."])
        #expect(MobiMetadata.splitAuthors("Gaiman, Neil & Pratchett, Terry") == ["Gaiman, Neil", "Pratchett, Terry"])
        #expect(MobiMetadata.splitAuthors("A; B; C") == ["A", "B", "C"])
        #expect(MobiMetadata.splitAuthors("  ") == [])
    }

    @Test("two authors arrive as two EXTH 100 records and stay in order")
    func twoAuthors() throws {
        let result = try read(
            SyntheticMobi(book: Book(title: "Good Omens", authors: ["Neil Gaiman", "Terry Pratchett"])))
        #expect(result.book.authors == ["Neil Gaiman", "Terry Pratchett"])
        // The order decides the author folder, so it is not a set.
        #expect(result.book.primaryAuthor == "Neil Gaiman")
    }

    /// The three sources of a title, made to disagree on purpose. EXTH 503 is
    /// what the publisher last said the book is called; the MOBI header's own
    /// name is what it was called when the file was built; the file name is
    /// what somebody's download folder called it.
    @Test("EXTH 503 wins over the header's own name, which wins over the file name")
    func updatedTitleWins() throws {
        let mobi = SyntheticMobi(
            book: Book(title: "Name In The Header", authors: ["A"]), updatedTitle: "What EXTH 503 Says")
        let database = try PalmDatabase(bytes: Array(mobi.data()))
        let header = try MobiHeader(record0: try #require(database.record(0)))

        // All three really do differ, or the test below proves nothing.
        #expect(header.string(503) == "What EXTH 503 Says")
        #expect(header.fullName == "Name In The Header")
        #expect(
            MobiMetadata.title(header, fallback: "From The File Name", database: database)
                == "What EXTH 503 Says")

        // And through the whole reader, not just the one function.
        #expect(try read(mobi, name: "From The File Name").book.title == "What EXTH 503 Says")
    }

    @Test("with no EXTH 503 the header's own name is the title")
    func headerNameIsTheFallback() throws {
        let mobi = SyntheticMobi(book: Book(title: "Name In The Header", authors: ["A"]))
        let database = try PalmDatabase(bytes: Array(mobi.data()))
        var record0 = try #require(database.record(0))
        // Turn the 503 record into a type Shelf does not read, leaving the
        // header's own name as the only title in the file.
        if let at = find(record0, pattern: [0, 0, 1, 0xF7]) {
            record0[at + 2] = 0x03
            record0[at + 3] = 0xE7
        }
        let header = try MobiHeader(record0: record0)
        #expect(header.string(503) == nil)
        #expect(
            MobiMetadata.title(header, fallback: "From The File Name", database: database)
                == "Name In The Header")
    }

    @Test("a broken EXTH record stops the walk instead of running off the end")
    func brokenEXTH() {
        // "EXTH", a length, a count of 3, then one record claiming to be 4
        // bytes long — shorter than its own 8-byte header.
        var bytes = Array("EXTH".utf8)
        bytes += [0, 0, 0, 24]
        bytes += [0, 0, 0, 3]
        bytes += [0, 0, 0, 100]
        bytes += [0, 0, 0, 4]
        bytes += [0, 0, 0, 0]
        let records = MobiHeader.readEXTH(bytes, startingAt: 0)
        #expect(records.isEmpty)
    }

    // MARK: Text

    @Test("Windows-1252's curly quotes and dashes survive")
    func windows1252() {
        // 0x93 and 0x94 are the curly double quotes, 0x97 an em dash — the
        // stretch where Windows-1252 and Latin-1 disagree, and the stretch half
        // of all book titles are punctuated with.
        let payload: [UInt8] = [0x93] + Array("Dune".utf8) + [0x94, 0x97, 0x41]
        #expect(MobiHeader.decode(payload, encoding: 1252) == "\u{201C}Dune\u{201D}\u{2014}A")
    }

    @Test("a UTF-8 payload is read as UTF-8 even when the header claims 1252")
    func utf8DespiteHeader() {
        let payload = Array("Jose\u{0301} Saramago".utf8)
        #expect(MobiHeader.decode(payload, encoding: 1252) == "Jose\u{0301} Saramago")
    }

    @Test("an empty or all-null payload is nothing, not an empty title")
    func emptyPayload() {
        #expect(MobiHeader.decode([], encoding: 65001) == nil)
        #expect(MobiHeader.decode([0, 0, 0], encoding: 65001) == nil)
        #expect(MobiHeader.decode(Array("   ".utf8), encoding: 65001) == nil)
    }

    // MARK: Covers

    @Test("the cover comes out of the record EXTH 201 points at")
    func coverFromEXTH201() throws {
        let cover = MinimalPNG.cover(width: 12, height: 18, seed: 7)
        let result = try read(SyntheticMobi(book: Book(title: "Emma", authors: ["Austen"]), cover: cover))
        #expect(result.cover == cover)
        // Named from the bytes, not from a field: a PNG written as `cover.jpg`
        // works with ImageIO and confuses everything else.
        #expect(result.coverName == "cover.png")
        #expect(!result.warnings.contains { $0.contains("no cover") })
    }

    @Test("a file with no cover says so and is still a book")
    func noCover() throws {
        let result = try read(SyntheticMobi(book: Book(title: "Emma", authors: ["Austen"])))
        #expect(result.cover == nil)
        #expect(result.warnings.contains { $0.contains("no cover") })
        #expect(result.book.title == "Emma")
    }

    @Test("a record that is not an image is not offered as a cover")
    func notAnImage() {
        #expect(MobiMetadata.imageName(Array(repeating: UInt8(0x41), count: 200)) == nil)
        #expect(MobiMetadata.imageName([0xFF, 0xD8, 0xFF]) == nil)
    }

    // MARK: DRM

    /// Recognised, badged, and otherwise left entirely alone. Nothing here
    /// unlocks anything and nothing in this repository explains how
    /// (CONCEPT §12, ADR 0012).
    @Test("a file announcing Kindle DRM is badged, and its clear metadata is still read")
    func kindleDRM() throws {
        let book = Book(title: "Protected", authors: ["Someone"], identifiers: ["isbn": "9780316229296"])
        let result = try read(SyntheticMobi(book: book, withKindleDRM: true))

        #expect(result.drm == .kindle)
        #expect(result.drm?.label == "Kindle DRM")
        // The metadata that is in the clear is still taken: that is the point
        // of detecting rather than refusing.
        #expect(result.book.title == "Protected")
        #expect(result.book.identifiers["isbn"] == "9780316229296")
        #expect(result.warnings.contains { $0.contains("left alone") })
    }

    @Test("the encryption byte alone is enough, without EXTH 209")
    func encryptionByteAlone() throws {
        let mobi = SyntheticMobi(book: Book(title: "X", authors: ["Y"]), withKindleDRM: true)
        var bytes = Array(mobi.data())
        // Find record 0 and blank its EXTH 209 type so only the PalmDOC
        // encryption byte is left saying anything.
        let database = try PalmDatabase(bytes: bytes)
        let record0 = try #require(database.record(0))
        let header = try MobiHeader(record0: record0)
        #expect(header.encryptionType == 2)
        #expect(header.exth[209] != nil)

        // Strip the 209 record by rewriting its type to an unused number.
        if let range = find(bytes, pattern: [0, 0, 0, 209]) {
            bytes[range] = 0
            bytes[range + 1] = 0
            bytes[range + 2] = 0x03
            bytes[range + 3] = 0xE7  // 999, a type Shelf does not read
        }
        let result = try MobiMetadata.read(bytes, fallbackTitle: "X")
        #expect(result.drm == .kindle)
    }

    // MARK: Files that are odd rather than broken

    @Test("a Palm database with no MOBI header still gives a book, named after its file")
    func noMobiHeader() throws {
        let mobi = SyntheticMobi(
            book: Book(title: "Ignored", authors: ["Ignored"]), withoutMobiHeader: true)
        let result = try MobiMetadata.read(
            Array(mobi.data()), fallbackTitle: "The Hobbit - J.R.R. Tolkien")

        #expect(result.book.title == "The Hobbit")
        #expect(result.book.authors == ["J.R.R. Tolkien"])
        #expect(result.warnings.contains { $0.contains("file name") })
    }

    @Test("AZW3 reads exactly as MOBI does – the container is the same")
    func azw3() throws {
        let book = Book(title: "Ancillary Justice", authors: ["Ann Leckie"], tags: ["space opera"])
        let asMobi = try read(SyntheticMobi(book: book))
        let asAZW3 = try read(SyntheticMobi(book: book, isAZW3: true))

        #expect(asMobi.book.title == asAZW3.book.title)
        #expect(asMobi.book.authors == asAZW3.book.authors)
        #expect(asMobi.book.tags == asAZW3.book.tags)
        #expect(SyntheticMobi(book: book, isAZW3: true).fileExtension == "azw3")
    }

    @Test("an unreadable date is reported rather than guessed at")
    func badDate() {
        #expect(MobiMetadata.date(from: "2015-08-04") != nil)
        #expect(MobiMetadata.date(from: "2015") != nil)
        #expect(MobiMetadata.date(from: "2015-08") != nil)
        #expect(MobiMetadata.date(from: "sometime in the eighties") == nil)
        #expect(MobiMetadata.date(from: "") == nil)
    }

    @Test("a truncated file is refused instead of read as far as it goes")
    func truncated() {
        let mobi = SyntheticMobi(book: Book(title: "Emma", authors: ["Austen"]))
        let bytes = Array(mobi.data().prefix(40))
        #expect(throws: MobiMetadata.Failure.self) {
            try MobiMetadata.read(bytes, fallbackTitle: "Emma")
        }
    }

    // MARK: Helpers

    /// The first index at which `pattern` occurs.
    private func find(_ bytes: [UInt8], pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count)
        where Array(bytes[start..<(start + pattern.count)]) == pattern {
            return start
        }
        return nil
    }
}
