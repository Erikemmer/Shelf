import Foundation
import Testing

@testable import ShelfCore

/// Sending one of a book's format files to the Trash, keeping the book.
///
/// Unlike `EPUBFileReplacement`, which deliberately offers no ⌘Z because it
/// swaps a book's own content in place, this type only ever removes a whole,
/// unmodified file and puts nothing in its place — so a hash-verified move
/// back out of the Trash is both possible and tested here, not merely
/// promised in a doc comment.
@Suite("Sending one format file to the Trash")
struct FormatDisposalTests {

    /// The same test double `CoverReplacementTests` and `EPUBFileReplacementTests`
    /// use: a disposal that really moves the file, so a test can ask both "is
    /// it gone from the book's folder" and "can it still be got back".
    private final class Bin: @unchecked Sendable {
        let folder: URL
        private(set) var taken: [String] = []

        init(in parent: URL) throws {
            folder = parent.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        var disposal: FolderDisposal {
            FolderDisposal { [self] url in
                let target = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: url, to: target)
                taken.append(url.lastPathComponent)
                return target
            }
        }
    }

    private func hasher() -> HasherFactory { PortableSHA256Hasher.factory }

    /// A book with two format files, both written to disk so `remove` and
    /// `restore` have real bytes to move and hash — not just an in-memory
    /// `LibraryEntry` claiming files that are not there.
    private func twoFormatBook(in folder: TemporaryFolder) throws -> (Library, LibraryEntry) {
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let epubData = Data("epub bytes".utf8)
        let kfxData = Data("CONT".utf8) + Data([0, 0, 0, 0])
        try folder.write("Lib/A/Book (1)/Book - A.epub", data: epubData)
        try folder.write("Lib/A/Book (1)/Book - A.kfx", data: kfxData)

        let book = Book(title: "Book", authors: ["A"])
        let entry = LibraryEntry(
            book: book, number: 1, folder: "A/Book (1)",
            formats: [
                BookFormat(
                    bookID: book.id, format: .epub, fileName: "Book - A.epub",
                    byteSize: Int64(epubData.count),
                    sha256: try FileDigest.sha256(
                        of: library.root.appendingPathComponent("A/Book (1)/Book - A.epub"), makeHasher: hasher())),
                BookFormat(
                    bookID: book.id, format: .kfx, fileName: "Book - A.kfx",
                    byteSize: Int64(kfxData.count),
                    sha256: try FileDigest.sha256(
                        of: library.root.appendingPathComponent("A/Book (1)/Book - A.kfx"), makeHasher: hasher())),
            ])
        return (library, entry)
    }

    // MARK: remove

    @Test("removing a non-last format moves it to the Trash and leaves the book with one file")
    func removesOneOfTwo() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try twoFormatBook(in: folder)
        let bin = try Bin(in: folder.url)
        let kfx = try #require(entry.formats.first { $0.format == .kfx })

        let result = try FormatDisposal.remove(kfx, from: entry, library: library, disposal: bin.disposal)

        let bookURL = library.root.appendingPathComponent("A/Book (1)")
        #expect(!FileManager.default.fileExists(atPath: bookURL.appendingPathComponent("Book - A.kfx").path))
        #expect(FileManager.default.fileExists(atPath: bookURL.appendingPathComponent("Book - A.epub").path))
        #expect(bin.taken == ["Book - A.kfx"])
        #expect(result.relativePath == "A/Book (1)/Book - A.kfx")
        #expect(result.trashedAt == bin.folder.appendingPathComponent("Book - A.kfx"))
    }

    @Test("removing a book's only format is refused, untouched")
    func refusesTheLastFormat() throws {
        let folder = try TemporaryFolder()
        let (library, twoFormats) = try twoFormatBook(in: folder)
        let bin = try Bin(in: folder.url)
        var entry = twoFormats
        let epub = try #require(entry.formats.first { $0.format == .epub })
        entry.formats = [epub]

        #expect(throws: FormatDisposal.Refusal.lastFormat) {
            try FormatDisposal.remove(epub, from: entry, library: library, disposal: bin.disposal)
        }
        let bookURL = library.root.appendingPathComponent("A/Book (1)")
        #expect(FileManager.default.fileExists(atPath: bookURL.appendingPathComponent("Book - A.epub").path))
        #expect(bin.taken.isEmpty)
    }

    // MARK: restore

    @Test("restoring puts the file back at exactly its old path, verified by hash")
    func restoresVerified() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try twoFormatBook(in: folder)
        let bin = try Bin(in: folder.url)
        let kfx = try #require(entry.formats.first { $0.format == .kfx })
        let result = try FormatDisposal.remove(kfx, from: entry, library: library, disposal: bin.disposal)

        let restored = try FormatDisposal.restore(result, library: library, makeHasher: hasher())

        let bookURL = library.root.appendingPathComponent("A/Book (1)")
        #expect(restored == bookURL.appendingPathComponent("Book - A.kfx"))
        #expect(FileManager.default.fileExists(atPath: restored.path))
        #expect(!FileManager.default.fileExists(atPath: bin.folder.appendingPathComponent("Book - A.kfx").path))
        let restoredDigest = try FileDigest.sha256(of: restored, makeHasher: hasher())
        #expect(restoredDigest == kfx.sha256)
    }

    @Test("a disposal that cannot say where the file went cannot be restored")
    func noTrashLocation() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try twoFormatBook(in: folder)
        let kfx = try #require(entry.formats.first { $0.format == .kfx })
        // Really removes the file, but – like a disposal that cannot report a
        // destination – answers `nil`, so `restore` has nothing to go on.
        let silent = FolderDisposal { url in
            try FileManager.default.removeItem(at: url)
            return nil
        }
        let result = try FormatDisposal.remove(kfx, from: entry, library: library, disposal: silent)

        #expect(throws: FormatDisposal.RestoreFailure.noTrashLocation) {
            try FormatDisposal.restore(result, library: library, makeHasher: hasher())
        }
    }

    @Test("a Trash copy that changed since is not restored as if nothing happened")
    func hashMismatch() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try twoFormatBook(in: folder)
        let bin = try Bin(in: folder.url)
        let kfx = try #require(entry.formats.first { $0.format == .kfx })
        let result = try FormatDisposal.remove(kfx, from: entry, library: library, disposal: bin.disposal)

        // Somebody (or something) edited the file while it sat in the Trash.
        try Data("tampered".utf8).write(to: bin.folder.appendingPathComponent("Book - A.kfx"))

        #expect(throws: FormatDisposal.RestoreFailure.hashMismatch) {
            try FormatDisposal.restore(result, library: library, makeHasher: hasher())
        }
    }

    @Test("a Trash copy that is gone is not silently treated as restored")
    func trashItemMissing() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try twoFormatBook(in: folder)
        let bin = try Bin(in: folder.url)
        let kfx = try #require(entry.formats.first { $0.format == .kfx })
        let result = try FormatDisposal.remove(kfx, from: entry, library: library, disposal: bin.disposal)

        try FileManager.default.removeItem(at: bin.folder.appendingPathComponent("Book - A.kfx"))

        #expect(throws: FormatDisposal.RestoreFailure.trashItemMissing) {
            try FormatDisposal.restore(result, library: library, makeHasher: hasher())
        }
    }

    @Test("restoring never overwrites something already at the file's old place")
    func destinationOccupied() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try twoFormatBook(in: folder)
        let bin = try Bin(in: folder.url)
        let kfx = try #require(entry.formats.first { $0.format == .kfx })
        let result = try FormatDisposal.remove(kfx, from: entry, library: library, disposal: bin.disposal)

        // Something else now sits where the file used to be – a re-import, or
        // a person's own new file with the same name.
        try Data("someone else's file".utf8).write(
            to: library.root.appendingPathComponent("A/Book (1)/Book - A.kfx"))

        #expect(throws: FormatDisposal.RestoreFailure.destinationOccupied) {
            try FormatDisposal.restore(result, library: library, makeHasher: hasher())
        }
        // And the impostor is left exactly as it was.
        let stillThere = try Data(contentsOf: library.root.appendingPathComponent("A/Book (1)/Book - A.kfx"))
        #expect(String(decoding: stillThere, as: UTF8.self) == "someone else's file")
    }
}
