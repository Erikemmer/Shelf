import Foundation
import Testing

@testable import ShelfCore

#if canImport(Darwin)
    import Darwin
#endif

/// Proves `EPUBArchiveWriter` against the strictest form it is meant to
/// survive: read an archive, hand every entry straight back to the writer
/// unchanged, read the result a second time, and compare not just
/// decompressed payloads but the archives themselves, byte for byte.
///
/// Every valid archive below is built with `EPUBArchiveWriter` itself, never
/// `ShelfFixtures.ZipWriter` — these tests exist to prove the production
/// writer, and a fixture built by a second implementation of the same format
/// would not prove anything about this one (`docs/adr/0021-…`).
///
/// This is Sprint 10's own proof, and only that: nothing here reads or
/// changes an OPF's fields, nothing here is called by the app, and nothing
/// here writes a real book file. It exists so the next step — changing a
/// book's own metadata in place — has an archive writer it can already trust
/// with the parts that are not the change itself.
@Suite("Writing EPUBs: the strict round trip")
struct EPUBArchiveWriterTests {

    // MARK: The round trip itself

    /// Builds `entries`, reads the result, carries every entry straight
    /// through `EPUBArchiveWriter` a second time, and checks that the two
    /// archives agree in every way that matters: the same entry names, the
    /// same decompressed bytes, and — since every entry is now carried
    /// forward as `.passthrough` rather than decompressed and re-stored —
    /// the two archives' bytes are identical, not merely equivalent.
    private func assertStrictRoundTrip(_ entries: [ZipArchiveWriter.Entry]) throws {
        let firstBytes = try EPUBArchiveWriter.archive(entries)
        let first = try ZipReader(data: firstBytes)
        let rewritten = try EPUBArchiveWriter.entries(rewriting: first)
        let secondBytes = try EPUBArchiveWriter.archive(rewritten)
        let second = try ZipReader(data: secondBytes)

        #expect(second.entries.map(\.path) == first.entries.map(\.path))
        for entry in first.files {
            #expect(
                try second.data(at: entry.path) == (try first.data(at: entry.path)),
                "payload differs at \(entry.path)")
        }
        #expect(secondBytes == firstBytes, "the round-tripped archive is not byte-identical to the original")
    }

    // MARK: The nine (ten) shapes

    @Test("EPUB 2 – opf:role authorship, round-trips exactly")
    func epub2RoundTrip() throws {
        try assertStrictRoundTrip(Self.epub2())
    }

    @Test("EPUB 3 – refined roles and dcterms:modified, round-trips exactly")
    func epub3RoundTrip() throws {
        try assertStrictRoundTrip(Self.epub3())
    }

    @Test("a book with no cover at all round-trips exactly")
    func noCoverRoundTrip() throws {
        try assertStrictRoundTrip(Self.noCover())
    }

    /// The manifest naming a file that is not in the archive is a metadata
    /// problem for whoever reads the OPF (`EPUBMetadata` already copes with
    /// it); it is not a reason for the *archive* to be unreadable, and the
    /// writer must not need every reference to resolve to round-trip it.
    @Test("an OPF naming a cover the archive does not have round-trips exactly")
    func missingCoverFileRoundTrip() throws {
        try assertStrictRoundTrip(Self.coverReferencedButMissing())
    }

    @Test("an OPF that does not live in OEBPS round-trips exactly")
    func opfInSubfolderRoundTrip() throws {
        try assertStrictRoundTrip(Self.opfInSubfolder())
    }

    @Test("deep paths and non-ASCII names – an umlaut and a Cyrillic name – round-trip exactly")
    func deepNonASCIIRoundTrip() throws {
        try assertStrictRoundTrip(Self.deepNonASCIIPaths())
    }

    /// Every entry `epub2()` authors is `.raw`, which `ZipArchiveWriter`
    /// always stores — so this is not a special case to construct: it is
    /// what every author-produced fixture in this file already is. Named
    /// and asserted directly anyway, because the requirement was named
    /// directly. The *interesting* already-stored case — one carried
    /// forward from a source archive rather than authored here — is
    /// `deflateCompressedEntryStaysDeflated` below, proving the opposite:
    /// a passthrough entry that was *not* stored to begin with stays that
    /// way too.
    @Test("an entry that arrives already stored round-trips exactly, which is every author-produced entry here")
    func alreadyStoredRoundTrip() throws {
        let entries = Self.epub2()
        let archive = try ZipReader(data: try EPUBArchiveWriter.archive(entries))
        #expect(archive.entries.allSatisfy { $0.method == .stored })
        try assertStrictRoundTrip(entries)
    }

    @Test("a file the manifest never mentions still round-trips exactly")
    func unmanifestedFileRoundTrip() throws {
        try assertStrictRoundTrip(Self.withUnmanifestedFile())
    }

    /// Announced, not zip-encrypted – the same distinction `EPUBMetadata`
    /// and `DRMProbe` already read this file for (CONCEPT §12). The writer
    /// has no reason to treat it specially, and this proves it does not:
    /// the file passes through like any other entry.
    @Test("META-INF/encryption.xml – an EPUB announcing DRM – round-trips exactly")
    func drmAnnouncementRoundTrip() throws {
        try assertStrictRoundTrip(Self.withDRMAnnouncement())
    }

    /// What Erik actually asked to see: the archive's own byte size, before
    /// and after, for every one of the nine shapes. All nine are authored
    /// through `EPUBArchiveWriter` itself, so every entry in every one of
    /// them was already stored before the round trip even starts — which is
    /// exactly why a real, previously-DEFLATEd entry needed its own separate
    /// proof (`deflateCompressedEntryStaysDeflated`, below): none of these
    /// nine would have caught the original bug, because none of them was
    /// ever compressed to begin with.
    @Test("size before and after the round trip, named, for every shape")
    func sizeBeforeAndAfter() throws {
        let fixtures: [(name: String, entries: [ZipArchiveWriter.Entry])] = [
            ("EPUB 2", Self.epub2()),
            ("EPUB 3", Self.epub3()),
            ("no cover", Self.noCover()),
            ("cover referenced but missing", Self.coverReferencedButMissing()),
            ("OPF in a subfolder", Self.opfInSubfolder()),
            ("deep non-ASCII paths", Self.deepNonASCIIPaths()),
            ("already stored", Self.epub2()),
            ("unmanifested file", Self.withUnmanifestedFile()),
            ("DRM announcement", Self.withDRMAnnouncement()),
        ]
        for fixture in fixtures {
            let before = try EPUBArchiveWriter.archive(fixture.entries)
            let rewritten = try EPUBArchiveWriter.entries(rewriting: try ZipReader(data: before))
            let after = try EPUBArchiveWriter.archive(rewritten)
            print("\(fixture.name): \(before.count) bytes before, \(after.count) bytes after")
            #expect(after.count == before.count, "\(fixture.name) changed size on an unchanged round trip")
        }
    }

    // MARK: mimetype, first, stored, or refused

    @Test("mimetype missing entirely is refused")
    func missingMimetype() {
        #expect(throws: EPUBArchiveWriter.Failure.mimetypeMustBeFirst) {
            try EPUBArchiveWriter.archive([.raw(path: "a.txt", text: "x")])
        }
    }

    @Test("mimetype present but not first is refused")
    func mimetypeNotFirst() {
        #expect(throws: EPUBArchiveWriter.Failure.mimetypeMustBeFirst) {
            try EPUBArchiveWriter.archive([.raw(path: "a.txt", text: "x"), Self.mimetype])
        }
    }

    @Test("mimetype appearing twice is refused")
    func duplicateMimetype() {
        #expect(throws: EPUBArchiveWriter.Failure.duplicateMimetype) {
            try EPUBArchiveWriter.archive([Self.mimetype, Self.mimetype])
        }
    }

    @Test("an empty entry list has no mimetype, and is refused the same way as a missing one")
    func emptyIsRefused() {
        #expect(throws: EPUBArchiveWriter.Failure.mimetypeMustBeFirst) {
            try EPUBArchiveWriter.archive([])
        }
    }

    /// The check that only became necessary once entries could carry their
    /// own method forward: before `.passthrough` existed, every entry this
    /// writer produced was stored, so `mimetype` being stored was true by
    /// construction and needed no check of its own. Now it is not.
    @Test("mimetype present, first, but not stored is refused")
    func mimetypeNotStored() {
        let notStored = ZipArchiveWriter.Entry.passthrough(
            path: "mimetype", compressedData: Data([1, 2, 3]), method: .deflate,
            uncompressedSize: 10, crc32: 0, modTime: 0, modDate: 0)
        #expect(throws: EPUBArchiveWriter.Failure.mimetypeMustBeStored) {
            try EPUBArchiveWriter.archive([notStored])
        }
    }

    // MARK: Encrypted and corrupt entries

    @Test("a ZIP-encrypted entry is refused when copying an archive forward, named")
    func encryptedEntryRefused() throws {
        var data = try EPUBArchiveWriter.archive(Self.epub2())
        guard let offset = Self.centralDirectoryRecordOffset(of: "OEBPS/cover.jpg", in: data) else {
            Issue.record("no central directory entry for OEBPS/cover.jpg in the written archive")
            return
        }
        data[offset + 8] |= 0x01  // general-purpose bit 0: encrypted

        let archive = try ZipReader(data: data)
        #expect(archive.entry(at: "OEBPS/cover.jpg")?.isEncrypted == true)
        #expect(throws: EPUBArchiveWriter.Failure.encryptedEntry("OEBPS/cover.jpg")) {
            try EPUBArchiveWriter.entries(rewriting: archive)
        }
    }

    /// The check that replaces what unpacking-and-storing used to give for
    /// free: this writer no longer decompresses a passthrough entry's bytes
    /// to write them back out, so the CRC has to be checked on purpose or a
    /// corrupt source archive's corruption would go unnoticed and simply be
    /// copied into a second file.
    @Test("a source entry whose bytes do not match its own recorded CRC is refused, named")
    func corruptSourceEntryRefused() throws {
        var data = try EPUBArchiveWriter.archive(Self.epub2())
        guard let offset = Self.centralDirectoryRecordOffset(of: "OEBPS/text.xhtml", in: data) else {
            Issue.record("no central directory entry for OEBPS/text.xhtml in the written archive")
            return
        }
        data[offset + 16] ^= 0xFF  // the CRC field, four bytes in

        let archive = try ZipReader(data: data)
        #expect(throws: EPUBArchiveWriter.Failure.corruptSourceEntry("OEBPS/text.xhtml")) {
            try EPUBArchiveWriter.entries(rewriting: archive)
        }
    }

    /// Finds a central directory record's own offset, by name, the same way
    /// `ZipReaderTests` finds a signature to tamper with – except this walks
    /// every record rather than the last occurrence, because the name it is
    /// looking for is not necessarily unique across the whole byte stream.
    private static func centralDirectoryRecordOffset(of path: String, in data: Data) -> Int? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let nameBytes = Array(path.utf8)
        var index = 0
        while index + 46 <= bytes.count {
            guard Array(bytes[index..<(index + 4)]) == signature else {
                index += 1
                continue
            }
            let nameLength = Int(bytes[index + 28]) | (Int(bytes[index + 29]) << 8)
            let extraLength = Int(bytes[index + 30]) | (Int(bytes[index + 31]) << 8)
            let commentLength = Int(bytes[index + 32]) | (Int(bytes[index + 33]) << 8)
            let nameStart = index + 46
            if nameStart + nameLength <= bytes.count,
                Array(bytes[nameStart..<(nameStart + nameLength)]) == nameBytes
            {
                return index
            }
            index = nameStart + nameLength + extraLength + commentLength
        }
        return nil
    }

    // MARK: A genuinely DEFLATE-compressed entry
    //
    // The nine shapes above are all authored through EPUBArchiveWriter,
    // which only ever stores – so not one of them was ever compressed to
    // begin with, and re-running them alone would not have caught the bug
    // this file's writer used to have: decompressing a DEFLATEd entry and
    // storing it back, which for running text costs roughly 2.7 times the
    // entry's own size. Proving the fix needs an entry that was actually
    // compressed by something else, which neither writer in this codebase
    // can produce on purpose (`ZipArchiveWriter` and `ShelfFixtures`'
    // `ZipWriter` are both stored-only) – so this one is hand-built, the
    // same reason `InflateTests`' vectors are hand-built: a real DEFLATE
    // stream, from `python3 -c "import zlib; …"` at `wbits = -15`, embedded
    // rather than produced by code this project owns.

    /// Three invented paragraphs, not from any real book – varied enough
    /// that DEFLATE does not collapse them into the extreme ratios a
    /// repeated block gets, closer to what a real page of prose compresses
    /// to.
    private static let deflateTestProse = """
        The keeper of the small library had long since stopped counting the books that
        arrived without a name attached, their covers worn soft by hands she would never
        meet. Each morning she walked the narrow aisles before the doors opened, running
        a finger along the spines as though greeting old acquaintances, and each evening
        she wrote a line or two in a ledger nobody else had ever asked to read. It was not
        that the town lacked readers; it was that most of them preferred to borrow rather
        than to linger, and lingering was the whole of what she loved about the place.

        A traveller had once told her that every library was really two libraries at
        once: the one printed on the shelves, and the one remembered by whoever tended
        them. She thought about that remark more often than she admitted, usually while
        dusting a shelf nobody had touched in a year, wondering whether the second
        library would outlast the first. The valley outside had its own quiet rhythms,
        the river bending twice before it reached the sea, farmers arguing gently over
        fences, children racing bicycles down the one paved road, and none of it seemed
        to notice the small building where paper slowly turned the colour of weak tea.

        Sometimes a stranger would ask why she never sorted the unclaimed books by
        subject, the way a proper library should. She never had a tidy answer. The truth,
        which she rarely spoke aloud, was that she preferred discovering the shape of a
        collection by accident: a cookbook beside a treatise on bridges, a diary beside a
        manual for engines nobody built any more. Order, she suspected, was something
        readers imposed afterward, in their own heads, and it was not really hers to
        arrange for them in advance. She had made her peace with that a long time ago,
        somewhere between the second shelf and the window that never quite closed.
        """

    /// `zlib.compressobj(9, zlib.DEFLATED, -15)` of the text above, encoded
    /// UTF-8. 1 823 plain bytes → 926 compressed, ratio ≈ 1.97 – lower than
    /// the ratio Erik measured against a real EPUB (≈ 2.7), which is
    /// expected: a real book is longer and more repetitive across chapters
    /// than three unrelated paragraphs. The direction and the order of
    /// magnitude are what this test is proving, not the exact number.
    private static let deflateTestCompressedHex =
        "4d5531b6db380cec750a1cc0cf07c8565b6cb1d516c9052009b6984f110a49594fb7df1952765259a640600633807e2c2"
        + "65f669b65f18754fc2babc628318c59f3298bce123d3da58434e165f56db35926df530d38e68dd1fdabe049eba039871"
        + "7de1fa12ebe575149ba9a68ad3a2d36df181f32aebf2c17393c2729fea832b2529a8b14e43b7c8fb32443ccb09ad5bbf"
        + "c83dbb2229a255b88c62f9461f5849a7e888612adc8680fcfd65ecceea8e19b2516ce7be2ed41e5811fd0d546ab31de4"
        + "2c2552507df9f8b3c33aab29403874ebf760da92af8979b00a518e1005e4bd8e064af6089ae2513cf520f97907860336"
        + "b251f7d3ec562b1d6515243bd46c1259bce77f9b7825541681dd8ca86acfa9124eac44046a1697f49e8812d68f5522fe"
        + "156d9b23d2ce79e74f4d696ac78959931f13436ee9d457f26cd9e0e34168fc6740773935874aaa923b564c40630761f8"
        + "6bfa5667d598ce041424e7354b60bd53a34723c3f3e62093088f16ccde9c7815daf032f7f6be91deddb00a91a5376711"
        + "68baf77e3df31d9565b4723553807b05b43aba5d9e681bdb8cb77b6afc9593ff8810a37357fd14b248a1bd25a43ae3aa"
        + "fa1567a652f7b437a2c21da30efa599411b96c75b4cd2aebed3d65debd3149d3d1c207a5717abbd1b606113ce874f379"
        + "ac3012a6ae98d7d845c60f41f787ca1b69d7c5bc2dcfd122a8c0c2bfcda8381c372d6652d373215ce5b86edd3dcc6f10"
        + "810e21a8240ba6dee2e0c7a9387e695a3a7f9b9f3c2d3520553cee3f0b06ef109b4e78cd6649d183386e99c385c33317"
        + "c74525a23bbce5d9bc4437807558b411f08e1743301fdde2be38edc5777329370f394e8078db1e774619d3cfade56d2"
        + "61fa056515a6fbee2bc672a569b088b2b631eeadc42c21e3d9746c8b036b25d72bd99ea6a8b8375f9b6a3c87b28f3f6d"
        + "aab76e7b3d9171cb4e2c6f89cac2c4dd473d238550a901da6b2a87e52e57cd7b5d6e03bc82a5c0fab86e605336ff326e"
        + "991d0dfa0c2c037ecfe91c4a5b85ef4d5a16f483ac7540072210068c012caed3042fa4fa0d0826902011c8dc0c024c90"
        + "b986425d64cc012b87f382ec24f28e1a564db0b5c01a62e9d956de65658a822949679b8bbbfc97672e09622d7bd900c3"
        + "2e0e85122c5c7bd73a92b06e5eb823304cf9d08cc090ae354fbb2c88bba6377c36dc7b152ccc509d9f0daad9b0b555c6"
        + "819a5f5cb95d01f67e554e0384d8606a6b9f98de53ed5f285a43f4e9b78128bbbf46ab8759fa6306af217e6f932324b8"
        + "bae7e93263c6b0cba74856f7ff01"

    /// A hand-built archive – `mimetype` stored, one entry genuinely
    /// DEFLATE-compressed – simulating what a real EPUB tool writes.
    /// Neither writer in this codebase can produce this, which is the point:
    /// this is the shape the fix in `docs/adr/0021-…` exists to keep intact.
    private static func archiveWithADeflatedEntry() -> Data {
        let mimetype = Data("application/epub+zip".utf8)
        let plain = Data(deflateTestProse.utf8)
        let compressed = Hex.data(deflateTestCompressedHex)

        var output: [UInt8] = []
        var directory: [UInt8] = []

        func add(path: String, payload: Data, method: UInt16, crc: UInt32, uncompressedSize: Int) {
            let name = Array(path.utf8)
            let offset = UInt32(output.count)
            // A plausible, non-placeholder date – 15 June 2020, noon – so a
            // passthrough test can tell "carried the source's own stamp"
            // apart from "used the `.raw` placeholder".
            let modDate: UInt16 = 0x50CF
            let modTime: UInt16 = 0x6000

            output += [0x50, 0x4B, 0x03, 0x04]
            output += le16(20)
            output += le16(0x0800)
            output += le16(method)
            output += le16(modTime)
            output += le16(modDate)
            output += le32(crc)
            output += le32(UInt32(payload.count))
            output += le32(UInt32(uncompressedSize))
            output += le16(UInt16(name.count))
            output += le16(0)
            output += name
            output += Array(payload)

            directory += [0x50, 0x4B, 0x01, 0x02]
            directory += le16(20)
            directory += le16(20)
            directory += le16(0x0800)
            directory += le16(method)
            directory += le16(modTime)
            directory += le16(modDate)
            directory += le32(crc)
            directory += le32(UInt32(payload.count))
            directory += le32(UInt32(uncompressedSize))
            directory += le16(UInt16(name.count))
            directory += le16(0)  // extra field length
            directory += le16(0)  // comment length
            directory += le16(0)  // disk number start
            directory += le16(0)  // internal file attributes
            directory += le32(0)  // external file attributes
            directory += le32(offset)
            directory += name
        }

        add(
            path: "mimetype", payload: mimetype, method: 0, crc: ZipCRC32.of(mimetype),
            uncompressedSize: mimetype.count)
        add(
            path: "OEBPS/text.xhtml", payload: compressed, method: 8, crc: ZipCRC32.of(plain),
            uncompressedSize: plain.count)

        let directoryOffset = UInt32(output.count)
        output += directory
        output += [0x50, 0x4B, 0x05, 0x06]
        output += le16(0)  // this disk
        output += le16(0)  // disk with the directory's start
        output += le16(2)  // entries on this disk
        output += le16(2)  // entries in total
        output += le32(UInt32(directory.count))
        output += le32(directoryOffset)
        output += le16(0)  // comment length
        return Data(output)
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ]
    }

    @Test("the hand-built fixture itself reads back correctly, before it proves anything about the writer")
    func deflateFixtureReadsBack() throws {
        let archive = try ZipReader(data: Self.archiveWithADeflatedEntry())
        #expect(archive.entry(at: "OEBPS/text.xhtml")?.method == .deflate)
        #expect(try archive.text(at: "OEBPS/text.xhtml") == Self.deflateTestProse)
    }

    /// The test this whole section exists for: a passthrough entry keeps
    /// its source's compression, its source's modification stamp, and the
    /// archive does not balloon to roughly the size the plain text alone
    /// would take.
    @Test("a DEFLATE-compressed source entry stays compressed through the round trip, and the archive stays small")
    func deflateCompressedEntryStaysDeflated() throws {
        let before = Self.archiveWithADeflatedEntry()
        let firstRead = try ZipReader(data: before)
        let rewritten = try EPUBArchiveWriter.entries(rewriting: firstRead)
        let after = try EPUBArchiveWriter.archive(rewritten)
        let secondRead = try ZipReader(data: after)

        let entry = try #require(secondRead.entry(at: "OEBPS/text.xhtml"))
        #expect(entry.method == .deflate)
        #expect(entry.modDate == 0x50CF)  // the source's own stamp, not the `.raw` placeholder
        #expect(entry.modTime == 0x6000)
        #expect(try secondRead.text(at: "OEBPS/text.xhtml") == Self.deflateTestProse)

        print(
            "deflate-compressed entry: \(before.count) bytes before, \(after.count) bytes after "
                + "(plain text alone is \(Self.deflateTestProse.utf8.count) bytes)")
        // The bug this fixes turned every compressed entry into roughly its
        // own uncompressed size; the archive staying within a few dozen
        // bytes of its own size — header overhead only, no entry re-encoded
        // — is the difference between the two.
        #expect(abs(after.count - before.count) < 64)
    }

    // MARK: The 60 MB entry

    /// Re-measured after the `.passthrough` fix. This fixture's one large
    /// entry was authored through `EPUBArchiveWriter` itself (`.raw`), so it
    /// was already stored before the fix and stays stored after it — this
    /// specific number was never expected to fall the way a genuinely
    /// compressed entry's would (`deflateCompressedEntryStaysDeflated`
    /// above is what proves that side); it is re-measured because it is a
    /// real number that could have moved, not because the fix targets it.
    @Test("a ~60 MB entry round-trips exactly, and the cost of it is measured rather than assumed")
    func largeEntryMeasured() throws {
        let size = 60_000_000
        var payload = Data(count: size)
        payload.withUnsafeMutableBytes { buffer in
            let base = buffer.bindMemory(to: UInt8.self)
            for index in 0..<size { base[index] = UInt8(truncatingIfNeeded: index) }
        }
        let entries = Self.epub2() + [ZipArchiveWriter.Entry.raw(path: "OEBPS/video.bin", data: payload)]

        let before = Self.residentMemoryBytes()
        let start = ContinuousClock.now
        try assertStrictRoundTrip(entries)
        let elapsed = ContinuousClock.now - start
        let after = Self.residentMemoryBytes()

        print("EPUBArchiveWriter strict round trip, ~60 MB entry: \(elapsed)")
        if let before, let after {
            let deltaMB = Double(after - before) / 1_000_000
            print(
                "resident memory: +\(String(format: "%.1f", deltaMB)) MB "
                    + "(from \(before / 1_000_000) MB to \(after / 1_000_000) MB)")
        } else {
            print("resident memory: not measured on this platform")
        }
        #expect(elapsed < .seconds(10), "a 60 MB round trip took \(elapsed) – worth a look before this ships")
    }

    /// Resident memory of this process, in bytes. macOS only, the same
    /// reason `shelf-tool`'s `fileSystemName(of:)` is Darwin-only: Linux CI
    /// still proves correctness and timing here, just not this one number.
    private static func residentMemoryBytes() -> Int? {
        #if canImport(Darwin)
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Int(info.resident_size) : nil
        #else
            return nil
        #endif
    }

    // MARK: Fixtures, built through the writer under test

    private static let mimetype = ZipArchiveWriter.Entry.raw(path: "mimetype", text: "application/epub+zip")

    private static func container(opfPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    static func epub2() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>An EPUB 2 Book</dc:title>
                <dc:creator opf:role="aut" opf:file-as="Author, Ann">Ann Author</dc:creator>
                <dc:identifier id="uuid_id" opf:scheme="uuid">11111111-1111-1111-1111-111111111111</dc:identifier>
                <meta name="cover" content="cover-image"/>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .raw(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>An EPUB 2 book.</p></body></html>"),
            .raw(path: "OEBPS/cover.jpg", data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4])),
        ]
    }

    static func epub3() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>An EPUB 3 Book</dc:title>
                <dc:creator id="creator">Bea Bookwright</dc:creator>
                <meta refines="#creator" property="role" scheme="marc:relators">aut</meta>
                <dc:identifier id="uuid_id">urn:uuid:22222222-2222-2222-2222-222222222222</dc:identifier>
                <meta property="dcterms:modified">2026-09-21T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .raw(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>An EPUB 3 book.</p></body></html>"),
            .raw(path: "OEBPS/cover.png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2])),
        ]
    }

    static func noCover() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>No Cover At All</dc:title>
                <dc:identifier id="uuid_id" opf:scheme="uuid">33333333-3333-3333-3333-333333333333</dc:identifier>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .raw(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>No cover.</p></body></html>"),
        ]
    }

    /// Same OPF as `epub2()`, but the manifest's cover item resolves to
    /// nothing – `OEBPS/cover.jpg` is simply never written.
    static func coverReferencedButMissing() -> [ZipArchiveWriter.Entry] {
        Self.epub2().filter { $0.path != "OEBPS/cover.jpg" }
    }

    static func opfInSubfolder() -> [ZipArchiveWriter.Entry] {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>The OPF Lives Elsewhere</dc:title>
                <dc:identifier id="uuid_id" opf:scheme="uuid">44444444-4444-4444-4444-444444444444</dc:identifier>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .raw(path: "META-INF/container.xml", text: container(opfPath: "content/package.opf")),
            .raw(path: "content/package.opf", text: opf),
            .raw(path: "content/text.xhtml", text: "<html><body><p>Not in OEBPS.</p></body></html>"),
        ]
    }

    /// A chapter title with an umlaut, a folder named after it, and a cover
    /// whose file name is Cyrillic – both nested several folders deep.
    static func deepNonASCIIPaths() -> [ZipArchiveWriter.Entry] {
        let chapterPath = "OEBPS/Text/Kapitel Eins/Über die Königin.xhtml"
        let coverPath = "OEBPS/Bilder/Обложка/глава.jpg"
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uuid_id" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>Über die Königin</dc:title>
                <dc:identifier id="uuid_id" opf:scheme="uuid">55555555-5555-5555-5555-555555555555</dc:identifier>
                <meta name="cover" content="cover-image"/>
              </metadata>
              <manifest>
                <item id="text" href="Text/Kapitel Eins/Über die Königin.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="Bilder/Обложка/глава.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        return [
            mimetype,
            .raw(path: "META-INF/container.xml", text: container(opfPath: "OEBPS/content.opf")),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: chapterPath, text: "<html><body><p>Über die Königin.</p></body></html>"),
            .raw(path: coverPath, data: Data([0xFF, 0xD8, 0xFF, 0xE0, 5, 6, 7])),
        ]
    }

    static func withUnmanifestedFile() -> [ZipArchiveWriter.Entry] {
        Self.epub2() + [ZipArchiveWriter.Entry.raw(path: "OEBPS/notes-nobody-declared.txt", text: "leftover notes")]
    }

    static func withDRMAnnouncement() -> [ZipArchiveWriter.Entry] {
        // What a real ADEPT-protected EPUB carries – only its *presence* is
        // ever read (`EPUBMetadata.encryptionPath`, `DRMProbe`), so an
        // announcement rather than a real encryption is enough here too, and
        // is the only kind of "protected" content this repository ever holds
        // (CONCEPT §12).
        let encryption = """
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
                <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
                <CipherData><CipherReference URI="OEBPS/text.xhtml"/></CipherData>
              </EncryptedData>
            </encryption>
            """
        return Self.epub2() + [ZipArchiveWriter.Entry.raw(path: "META-INF/encryption.xml", text: encryption)]
    }
}
