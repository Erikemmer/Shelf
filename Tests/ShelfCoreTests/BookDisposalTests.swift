import Foundation
import Testing

@testable import ShelfCore

/// Sending a whole book — its folder, every file in it — to the Trash.
///
/// The other half of `FormatDisposal`, which refuses on purpose when asked
/// to take a book's last file: this is the deliberate, explicit command for
/// removing a book entirely, never a side effect of removing files one at a
/// time.
@Suite("Sending a whole book to the Trash")
struct BookDisposalTests {

    /// The same test double `FormatDisposalTests` uses.
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

    /// A one-file book on disk, the shape "My Clippings" actually has in a
    /// real library: a single file, no siblings, nothing left over once it
    /// goes.
    private func oneFileBook(in folder: TemporaryFolder) throws -> (Library, LibraryEntry) {
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let data = Data("clippings text".utf8)
        try folder.write("Lib/Unknown/My Clippings (1)/My Clippings - Unknown.epub", data: data)

        let book = Book(title: "My Clippings", authors: ["Unknown"])
        let entry = LibraryEntry(
            book: book, number: 1, folder: "Unknown/My Clippings (1)",
            formats: [
                BookFormat(
                    bookID: book.id, format: .epub, fileName: "My Clippings - Unknown.epub",
                    byteSize: Int64(data.count),
                    sha256: try FileDigest.sha256(
                        of: library.root.appendingPathComponent(
                            "Unknown/My Clippings (1)/My Clippings - Unknown.epub"),
                        makeHasher: hasher()))
            ])
        return (library, entry)
    }

    // MARK: remove

    @Test("removing a book's only file removes the whole book, folder and all")
    func removesTheWholeFolder() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try oneFileBook(in: folder)
        let bin = try Bin(in: folder.url)

        let result = try BookDisposal.remove(entry, library: library, disposal: bin.disposal)

        let bookURL = library.root.appendingPathComponent("Unknown/My Clippings (1)")
        #expect(!FileManager.default.fileExists(atPath: bookURL.path))
        #expect(bin.taken == ["My Clippings (1)"])
        #expect(result.relativeFolder == "Unknown/My Clippings (1)")
    }

    // MARK: restore

    @Test("restoring puts the whole folder back, every file verified by hash")
    func restoresVerified() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try oneFileBook(in: folder)
        let bin = try Bin(in: folder.url)
        let result = try BookDisposal.remove(entry, library: library, disposal: bin.disposal)

        let restored = try BookDisposal.restore(result, library: library, makeHasher: hasher())

        let bookURL = library.root.appendingPathComponent("Unknown/My Clippings (1)")
        #expect(restored == bookURL)
        let fileURL = bookURL.appendingPathComponent("My Clippings - Unknown.epub")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let digest = try FileDigest.sha256(of: fileURL, makeHasher: hasher())
        #expect(digest == entry.formats[0].sha256)
    }

    @Test("a Trash copy whose file changed is not restored as if nothing happened")
    func hashMismatch() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try oneFileBook(in: folder)
        let bin = try Bin(in: folder.url)
        let result = try BookDisposal.remove(entry, library: library, disposal: bin.disposal)

        try Data("tampered".utf8).write(
            to: bin.folder.appendingPathComponent("My Clippings (1)/My Clippings - Unknown.epub"))

        #expect(throws: BookDisposal.RestoreFailure.hashMismatch(fileName: "My Clippings - Unknown.epub")) {
            try BookDisposal.restore(result, library: library, makeHasher: hasher())
        }
    }

    @Test("restoring never overwrites a folder already at the book's old place")
    func destinationOccupied() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try oneFileBook(in: folder)
        let bin = try Bin(in: folder.url)
        let result = try BookDisposal.remove(entry, library: library, disposal: bin.disposal)

        try folder.write(
            "Lib/Unknown/My Clippings (1)/something else.txt", data: Data("new".utf8))

        #expect(throws: BookDisposal.RestoreFailure.destinationOccupied) {
            try BookDisposal.restore(result, library: library, makeHasher: hasher())
        }
    }

    @Test("a disposal that cannot say where the folder went cannot be restored")
    func noTrashLocation() throws {
        let folder = try TemporaryFolder()
        let (library, entry) = try oneFileBook(in: folder)
        let silent = FolderDisposal { url in
            try FileManager.default.removeItem(at: url)
            return nil
        }
        let result = try BookDisposal.remove(entry, library: library, disposal: silent)

        #expect(throws: BookDisposal.RestoreFailure.noTrashLocation) {
            try BookDisposal.restore(result, library: library, makeHasher: hasher())
        }
    }
}
