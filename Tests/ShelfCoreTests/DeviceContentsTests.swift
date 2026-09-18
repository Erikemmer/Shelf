import Foundation
import Testing

@testable import ShelfCore

/// What is on a device, which books of the library those files are, and what
/// happens when somebody asks for them to be deleted.
@Suite("What is on a device")
struct DeviceContentsTests {

    private func entry(
        _ title: String, author: String = "Jane Austen", formats: [BookFileFormat] = [.epub]
    )
        -> LibraryEntry
    {
        let book = Book(title: title, authors: [author])
        return LibraryEntry(
            book: book, number: 1, folder: "f",
            formats: formats.map {
                BookFormat(
                    bookID: book.id, format: $0, fileName: "x.\($0.fileExtension)", byteSize: 1,
                    sha256: "\(title)-\($0.rawValue)")
            })
    }

    private var kobo: DeviceProfile {
        DeviceProfiles.profile(id: "kobo")
            ?? .init(id: "", name: "", markers: [], booksFolder: "", formats: [], preferredFormats: [])
    }

    // MARK: Matching

    /// The strong rule: Shelf put the file there and wrote down the digest it
    /// read back off the device.
    @Test("a file Shelf sent is matched through the manifest")
    func matchedByManifest() {
        let emma = entry("Emma")
        var manifest = DeviceManifest(deviceID: "kobo")
        manifest.record(
            .init(
                path: "Somebody Renamed This.epub", bookID: emma.id, title: "Emma", author: "Jane Austen",
                format: .epub, byteSize: 1, sha256: "Emma-epub"))

        let matched = DeviceContents.matched(
            [DeviceFile(path: "Somebody Renamed This.epub", format: .epub, byteSize: 1)],
            to: [emma], manifest: manifest, profile: kobo)

        #expect(matched.first?.bookID == emma.id)
        #expect(matched.first?.matchedBy == .manifest)
    }

    /// The weak rule, and the only one available for a book somebody else put
    /// on the card.
    @Test("a file nobody sent is matched by the name Shelf would have given it")
    func matchedByName() {
        let emma = entry("Emma")
        let matched = DeviceContents.matched(
            [DeviceFile(path: "Jane Austen - Emma.epub", format: .epub, byteSize: 1)],
            to: [emma], manifest: DeviceManifest(deviceID: "kobo"), profile: kobo)

        #expect(matched.first?.bookID == emma.id)
        #expect(matched.first?.matchedBy == .name)
    }

    @Test("a file that is nothing in the library stays unmatched")
    func unmatched() {
        let matched = DeviceContents.matched(
            [DeviceFile(path: "Some Other Book.epub", format: .epub, byteSize: 1)],
            to: [entry("Emma")], manifest: DeviceManifest(deviceID: "kobo"), profile: kobo)
        #expect(matched.first?.bookID == nil)
        #expect(DeviceContents.booksOnDevice(matched).isEmpty)
    }

    /// Two library books that would be called the same on the card cannot be
    /// told apart by name, so the badge does not guess between them — the
    /// manifest is what resolves such a pair.
    @Test("the manifest beats the name when both could answer")
    func manifestWins() {
        let first = entry("Emma")
        let second = entry("Emma")
        var manifest = DeviceManifest(deviceID: "kobo")
        manifest.record(
            .init(
                path: "Jane Austen - Emma.epub", bookID: second.id, title: "Emma", author: "Jane Austen",
                format: .epub, byteSize: 1, sha256: "x"))

        let matched = DeviceContents.matched(
            [DeviceFile(path: "Jane Austen - Emma.epub", format: .epub, byteSize: 1)],
            to: [first, second], manifest: manifest, profile: kobo)
        #expect(matched.first?.bookID == second.id)
    }

    /// A Kobo's own folders hold tens of thousands of files, and none of them
    /// is a book.
    @Test("listing a device finds its books and not its firmware")
    func listing() throws {
        let temporary = try TemporaryFolder()
        let volume = try temporary.folder("volume")
        try temporary.write("volume/Jane Austen - Emma.epub", text: "a book")
        try temporary.write("volume/A Comic.cbz", text: "a comic")
        try temporary.write("volume/notes.txt", text: "not a book")
        try temporary.write("volume/.kobo/KoboReader.sqlite", text: "not a book either")
        try temporary.write("volume/.shelf/device-manifest.json", text: "{}")

        let device = ConnectedDevice(
            volume: MountedVolume(url: volume, name: "KOBOeReader"), profile: kobo)
        let files = DeviceContents.list(on: device)
        #expect(files.map(\.path) == ["A Comic.cbz", "Jane Austen - Emma.epub"])
    }

    // MARK: Deleting

    /// ADR 0014: the confirmation names every file. A dialog saying "Delete
    /// 214 files?" names nothing and can be agreed to by accident.
    @Test("the confirmation names every single file, and says the library is untouched")
    func confirmationNamesEveryFile() {
        let emma = entry("Emma")
        let files = [
            DeviceFile(path: "documents/A.epub", format: .epub, byteSize: 100, bookID: emma.id),
            DeviceFile(path: "documents/B.epub", format: .epub, byteSize: 200),
        ]
        let confirmation = DeviceDeletion.Confirmation(
            deviceName: "KINDLE", files: files, titles: [emma.id: "Emma"])

        #expect(confirmation.question == "Delete 2 files from “KINDLE”?")
        #expect(confirmation.lines == ["documents/A.epub  —  Emma", "documents/B.epub"])
        #expect(confirmation.lines.count == files.count)
        #expect(confirmation.explanation.contains("library is not touched"))
        #expect(confirmation.totalBytes == 300)
    }

    @Test("deleting removes the named files and takes them out of the manifest")
    func deleting() throws {
        let temporary = try TemporaryFolder()
        let volume = try temporary.folder("volume")
        try temporary.write("volume/A.epub", text: "one")
        try temporary.write("volume/B.epub", text: "two")

        var manifest = DeviceManifest(deviceID: "kobo")
        for name in ["A.epub", "B.epub"] {
            manifest.record(
                .init(
                    path: name, bookID: UUID(), title: name, author: "x", format: .epub, byteSize: 3,
                    sha256: name))
        }

        let outcome = DeviceDeletion.delete(
            [DeviceFile(path: "A.epub", format: .epub, byteSize: 3)], fromVolume: volume,
            manifest: &manifest)

        #expect(outcome.deleted == ["A.epub"])
        #expect(outcome.failed.isEmpty)
        #expect(!temporary.exists("volume/A.epub"))
        #expect(temporary.exists("volume/B.epub"), "only what was named is deleted")
        #expect(manifest.entries.map(\.path) == ["B.epub"])
    }

    /// A manifest is a file on a card somebody else may have written, and a
    /// `..` in it must not reach the library.
    @Test("a path that points off the device is refused, not followed")
    func noEscape() throws {
        let temporary = try TemporaryFolder()
        let volume = try temporary.folder("volume")
        try temporary.write("outside.epub", text: "a file that is not on the device")

        var manifest = DeviceManifest(deviceID: "kobo")
        let outcome = DeviceDeletion.delete(
            [
                DeviceFile(path: "../outside.epub", format: .epub, byteSize: 1),
                DeviceFile(path: "/etc/hosts", format: .epub, byteSize: 1),
            ],
            fromVolume: volume, manifest: &manifest)

        #expect(outcome.deleted.isEmpty)
        #expect(outcome.failed.count == 2)
        #expect(temporary.exists("outside.epub"))
    }

    // MARK: The manifest itself

    @Test("a manifest survives being written and read back")
    func manifestRoundTrip() throws {
        let temporary = try TemporaryFolder()
        let volume = try temporary.folder("volume")
        var manifest = DeviceManifest(deviceID: "kindle")
        let id = UUID()
        manifest.record(
            .init(
                path: "documents/Jane Austen - Emma.azw3", bookID: id, title: "Emma", author: "Jane Austen",
                format: .azw3, byteSize: 42, sha256: "abc"))
        try manifest.write(toVolume: volume)

        let read = DeviceManifest.read(fromVolume: volume, deviceID: "kindle")
        #expect(read.entries.count == 1)
        #expect(read.bookIDs == [id])
        #expect(read.formats(of: id) == [.azw3])
        #expect(read.digests == ["abc"])
    }

    /// The manifest is a cache of the card, exactly as the index is a cache of
    /// the library folder: losing it costs speed and nothing else.
    @Test("a manifest that is missing or broken comes back empty rather than throwing")
    func brokenManifest() throws {
        let temporary = try TemporaryFolder()
        let volume = try temporary.folder("volume")
        #expect(DeviceManifest.read(fromVolume: volume, deviceID: "kobo").entries.isEmpty)

        try temporary.write("volume/.shelf/device-manifest.json", text: "{ not json")
        #expect(DeviceManifest.read(fromVolume: volume, deviceID: "kobo").entries.isEmpty)
    }

    /// Sending a book again after editing its metadata writes the same path
    /// with new bytes; two rows for one file would make the next resume skip
    /// the wrong one.
    @Test("recording the same path twice replaces the row rather than adding one")
    func recordReplaces() {
        var manifest = DeviceManifest(deviceID: "kobo")
        let id = UUID()
        for digest in ["first", "second"] {
            manifest.record(
                .init(
                    path: "A.epub", bookID: id, title: "A", author: "x", format: .epub, byteSize: 1,
                    sha256: digest))
        }
        #expect(manifest.entries.count == 1)
        #expect(manifest.entries.first?.sha256 == "second")
    }
}
