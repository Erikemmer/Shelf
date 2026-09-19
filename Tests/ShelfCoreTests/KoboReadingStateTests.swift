import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// Reading a Kobo back: how far somebody has read, what the device's shelves
/// are called, and what it is reading now.
///
/// **Read only, and through a copy** (CONCEPT §8.1, ADR 0009). The fixture is
/// synthetic — `SyntheticKoboDatabase` writes the tables and columns a real
/// device has and nothing else, because a borrowed `KoboReader.sqlite` would
/// carry somebody's reading history into this repository.
@Suite("Reading a Kobo back")
struct KoboReadingStateTests {

    private func database(_ entries: [SyntheticKoboDatabase.Entry], in folder: TemporaryFolder) throws -> URL {
        let volume = try folder.folder("volume")
        try SyntheticKoboDatabase(entries: entries)
            .write(to: volume.appendingPathComponent(KoboReadingState.relativePath))
        return volume
    }

    @Test("progress, read status and the device's own shelves come back")
    func reading() throws {
        let folder = try TemporaryFolder()
        let volume = try database(
            [
                .init(
                    path: "Jane Austen - Emma.epub", title: "Emma", author: "Jane Austen",
                    percentRead: 42, status: .reading, shelves: ["On the train", "Classics"],
                    lastReadAt: Date(timeIntervalSince1970: 1_700_000_000)),
                .init(
                    path: "Ursula K. Le Guin - The Dispossessed.epub", title: "The Dispossessed",
                    author: "Ursula K. Le Guin", percentRead: 100, status: .finished),
                .init(path: "A Third Book.epub", title: "A Third Book", author: "Nobody"),
            ], in: folder)

        let reading = try KoboReadingState().read(volume: volume, cacheDirectory: folder.url)

        #expect(reading.books.count == 3)
        let emma = try #require(reading.book(at: "Jane Austen - Emma.epub"))
        #expect(emma.percentRead == 42)
        #expect(emma.status == .reading)
        #expect(emma.shelves == ["Classics", "On the train"])
        #expect(emma.lastReadAt == Date(timeIntervalSince1970: 1_700_000_000))

        let dispossessed = try #require(reading.book(at: "Ursula K. Le Guin - The Dispossessed.epub"))
        #expect(dispossessed.status == .finished)
        #expect(dispossessed.percentRead == 100)

        let third = try #require(reading.book(at: "A Third Book.epub"))
        #expect(third.status == .unread)
        #expect(third.shelves.isEmpty)
    }

    /// The paths have to line up with a listing of the volume, or nothing can
    /// be joined to a book.
    @Test("a ContentID becomes the path the file really has on the volume")
    func contentIDs() {
        #expect(
            KoboReadingState.path(fromContentID: "file:///mnt/onboard/Books/Emma.epub") == "Books/Emma.epub")
        #expect(
            KoboReadingState.path(fromContentID: "file:///mnt/onboard/Jane%20Austen%20-%20Emma.epub")
                == "Jane Austen - Emma.epub")
        // An SD card is a different volume, and attaching its reading position
        // to a file on this one would be attaching it to the wrong book.
        #expect(KoboReadingState.path(fromContentID: "file:///mnt/sd/Emma.epub") == nil)
        #expect(KoboReadingState.path(fromContentID: "12345-abcde") == nil)
    }

    /// A firmware that writes a value this version has never seen must not
    /// stop a library from opening.
    @Test("an unknown read status is unread, not a crash")
    func unknownStatus() {
        #expect(KoboReadingState.ReadStatus.of(7) == .unread)
        #expect(KoboReadingState.ReadStatus.of(2) == .finished)
    }

    @Test("a volume with no Kobo database says so rather than coming back empty")
    func noDatabase() throws {
        let folder = try TemporaryFolder()
        let volume = try folder.folder("volume")
        #expect(throws: KoboReadingState.Failure.self) {
            _ = try KoboReadingState().read(volume: volume, cacheDirectory: folder.url)
        }
    }

    /// The whole point of ADR 0009, and the one claim this feature has to
    /// earn: the device's own file is byte for byte what it was.
    @Test("the device's database is not written to, byte for byte")
    func neverWritesToTheDevice() throws {
        let folder = try TemporaryFolder()
        let volume = try database(
            [.init(path: "A.epub", title: "A", author: "B", percentRead: 10, status: .reading)], in: folder)
        let file = volume.appendingPathComponent(KoboReadingState.relativePath)
        let before = try FileDigest.sha256(of: file, makeHasher: PortableSHA256Hasher.factory)

        for _ in 0..<3 {
            _ = try KoboReadingState().read(volume: volume, cacheDirectory: folder.url)
        }

        #expect(try FileDigest.sha256(of: file, makeHasher: PortableSHA256Hasher.factory) == before)
        // And no journal or WAL was left beside it by the reading.
        #expect(!folder.exists("volume/.kobo/KoboReader.sqlite-wal"))
        #expect(!folder.exists("volume/.kobo/KoboReader.sqlite-journal"))
    }

    /// The copy goes into a folder of its own and is taken away again — the
    /// cache folder's rule is that a run removes exactly what it made.
    @Test("the copy it makes is cleaned up again")
    func copyIsCleanedUp() throws {
        let folder = try TemporaryFolder()
        let cache = try folder.folder("cache")
        let volume = try database([.init(path: "A.epub", title: "A", author: "B")], in: folder)

        _ = try KoboReadingState().read(volume: volume, cacheDirectory: cache)
        #expect(folder.names(in: "cache").isEmpty)
    }

    /// What the library does with it: the device's state, joined to the books
    /// by the path the file has on the volume.
    @Test("a reading position is joined to the library's book through the file's path")
    func joinedToTheLibrary() throws {
        let folder = try TemporaryFolder()
        let volume = try database(
            [
                .init(
                    path: "Jane Austen - Emma.epub", title: "Emma", author: "Jane Austen", percentRead: 60,
                    status: .reading)
            ],
            in: folder)
        // The file itself, as it really lies on the card.
        try folder.write("volume/Jane Austen - Emma.epub", text: "a synthetic book")
        let reading = try KoboReadingState().read(volume: volume, cacheDirectory: folder.url)

        let book = Book(title: "Emma", authors: ["Jane Austen"])
        let entry = LibraryEntry(
            book: book, number: 1, folder: "f",
            formats: [
                BookFormat(bookID: book.id, format: .epub, fileName: "x.epub", byteSize: 1, sha256: "d")
            ])
        let profile = try #require(DeviceProfiles.profile(id: "kobo"))
        let device = ConnectedDevice(volume: MountedVolume(url: volume, name: "KOBOeReader"), profile: profile)
        let matched = DeviceContents.matched(
            DeviceContents.list(on: device), to: [entry], manifest: DeviceManifest(deviceID: "kobo"),
            profile: profile)

        let file = try #require(matched.first)
        #expect(file.bookID == entry.id)
        #expect(reading.book(at: file.path)?.percentRead == 60)
    }
}
