import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// The counting protocol, and the bridge from a Calibre library to the
/// importer that was already there.
@Suite("Importing from Calibre")
struct CalibreImportTests {

    /// A closure and not a returned tuple. `TemporaryFolder` deletes its folder
    /// in `deinit`, and a caller writing `let (_, library, _) = try fixture()`
    /// throws the folder away on the spot — the library value survives, every
    /// file it points at does not, and eight tests failed at once with numbers
    /// that all looked like nought.
    private func withFixture(
        count: Int = 5, quirks: Bool = true,
        _ body: (CalibreLibrary, URL) throws -> Void
    ) throws {
        let root = try TemporaryFolder()
        let folder = root.url.appending(path: "Calibre Library")
        let cache = root.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try SyntheticCalibreLibrary.write(to: folder, options: .init(count: count, includeQuirks: quirks))
        let library = try CalibreReader().read(folder: folder, cacheDirectory: cache)
        try withExtendedLifetime(root) { try body(library, folder) }
    }

    // MARK: The counting protocol

    /// Both sides, because they disagree: `data` is what the library believes
    /// and the folder is what it has. A count from one of them alone is the one
    /// that makes an import look fine and then fail halfway.
    @Test("the census counts the database and the disk, and says where they differ")
    func census() throws {
        try withFixture() { library, _ in
            let census = CalibreCensusTaker(freeSpace: { _ in 1_000_000_000 })
                .take(of: library, destination: URL(fileURLWithPath: "/tmp"))

            #expect(census.books == 5)
            #expect(census.authors == 3)
            #expect(census.series == 2)
            #expect(census.tags == 3)
            // Five books, five listed EPUBs, one of which is not on the disk.
            #expect(census.formats[.epub] == 4)
            #expect(census.missingFiles.count == 1)
            #expect(census.orphanFiles.count == 1)
            #expect(census.booksWithoutCover == 1)
            #expect(census.totalBytes > 0)
            #expect(census.customColumns.count == 4)
            #expect(census.unknownColumns.count == 1)
        }
    }

    /// The same 5 % `ImportPlan` uses, so the sheet and the runner cannot
    /// disagree about what "enough room" means (ADR 0002, decision 5).
    @Test("room needed is the payload plus five per cent, and it is checked")
    func roomNeeded() throws {
        try withFixture() { library, _ in
            let tight = CalibreCensusTaker(freeSpace: { _ in 1 })
                .take(of: library, destination: URL(fileURLWithPath: "/tmp"))
            #expect(tight.requiredBytes > tight.totalBytes)
            #expect(tight.requiredBytes == Int64((Double(tight.totalBytes) * ImportPlan.freeSpaceMargin).rounded(.up)))
            #expect(tight.hasRoom == false)
            #expect(!tight.mayImport)

            let roomy = CalibreCensusTaker(freeSpace: { _ in 1_000_000_000 })
                .take(of: library, destination: URL(fileURLWithPath: "/tmp"))
            #expect(roomy.hasRoom == true)
            #expect(roomy.mayImport)
        }
    }

    /// Nobody has chosen a destination yet, so there is no free-space line —
    /// rather than a guess, or a zero that reads as "no room".
    @Test("with no destination there is no free-space answer at all")
    func noDestination() throws {
        try withFixture() { library, _ in
            let census = CalibreCensusTaker().take(of: library)
            #expect(census.availableBytes == nil)
            #expect(census.hasRoom == nil)
            #expect(census.mayImport)
            #expect(!census.lines().contains { $0.contains("Free at the destination") })
        }
    }

    /// `cover.jpg` and `metadata.opf` are furniture, not orphans. A real orphan
    /// is a book file Calibre left behind when a format was removed from the
    /// library but not from the folder.
    @Test("only a book file counts as an orphan")
    func orphansAreBooks() throws {
        try withFixture() { library, _ in
            let census = CalibreCensusTaker().take(of: library)
            #expect(census.orphanFiles == ["Le Guin, Ursula K./An Orphan (999)/orphan.epub"])
        }
    }

    // MARK: The bridge

    @Test("every file that is there becomes a candidate, with Calibre's metadata")
    func candidates() throws {
        try withFixture() { library, _ in
            let read = CalibreImportSource(makeHasher: PortableSHA256Hasher.factory).read(library)

            #expect(read.candidates.count == 4)
            #expect(read.missingFiles.count == 1)
            let first = try #require(read.candidates.first)
            #expect(first.format == .epub)
            #expect(first.sha256.count == 64)
            #expect(first.book.publisher == "Gollancz")
            #expect(!first.book.tags.isEmpty)
        }
    }

    /// Calibre's UUID travels on the candidate, which is what lets a resumed
    /// import rejoin its own books rather than copying them again.
    @Test("the candidate carries Calibre's UUID, not a fresh one")
    func candidateKeepsTheUUID() throws {
        try withFixture() { library, _ in
            let read = CalibreImportSource(makeHasher: PortableSHA256Hasher.factory).read(library)
            let fromDatabase = Set(library.books.map(\.book.id))
            #expect(read.candidates.allSatisfy { fromDatabase.contains($0.book.id) })
        }
    }

    /// Somebody who replaced a bad cover did it in Calibre, next to the book.
    /// Reading the EPUB again would quietly undo that.
    @Test("the cover comes from Calibre's cover.jpg, and is named after its bytes")
    func coverComesFromTheFolder() throws {
        try withFixture() { library, _ in
            let read = CalibreImportSource(makeHasher: PortableSHA256Hasher.factory).read(library)
            let withCover = try #require(read.candidates.first { $0.cover != nil })
            // Calibre calls it `cover.jpg` whatever the bytes are; `CoverFile` names
            // it after what it actually holds, so a PNG arrives as `cover.png`.
            #expect(withCover.coverName == "cover.png")
        }
    }

    @Test("a book the database lists and the disk has not got is reported, not imported")
    func missingFileIsReported() throws {
        try withFixture() { library, _ in
            let read = CalibreImportSource(makeHasher: PortableSHA256Hasher.factory).read(library)
            #expect(
                read.missingFiles == ["Clarke, Susanna/Synthetic Book 3 (3)/Synthetic Book 3 - Clarke, Susanna.epub"])
            // And the other four came through regardless.
            #expect(read.candidates.count == 4)
        }
    }

    /// The custom values are on the *book*, because the book is what the
    /// planner and the runner carry. The first version kept them in a field of
    /// `CalibreBook` beside the book, and every one of them was dropped
    /// silently — nothing fails when a dictionary is empty.
    @Test("the custom column values ride on the book into the import")
    func customValuesReachTheCandidate() throws {
        try withFixture() { library, _ in
            let read = CalibreImportSource(makeHasher: PortableSHA256Hasher.factory).read(library)
            let first = try #require(read.candidates.first)
            #expect(first.book.customValues["pages"] != nil)
            #expect(first.book.customValues["shelf_note"] != nil)
        }
    }
}
