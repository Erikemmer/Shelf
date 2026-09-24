import Foundation
import Testing

@testable import ShelfCore

@Suite("The library folder")
struct LibraryTests {

    @Test("creating a library lays out .shelf/ and writes library.json")
    func create() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("My Library")
        let (library, descriptor) = try Library.create(at: root, name: "My Library")

        #expect(Library.isLibrary(root))
        #expect(folder.exists("My Library/.shelf/library.json"))
        #expect(folder.exists("My Library/.shelf/covers"))
        #expect(descriptor.name == "My Library")
        #expect(descriptor.schemaVersion == LibraryDescriptor.currentSchemaVersion)
        #expect(descriptor.nextBookNumber == 1)
        #expect(library.name == "My Library")
    }

    @Test("a library takes its name from the folder when none is given")
    func defaultName() throws {
        let folder = try TemporaryFolder()
        let (_, descriptor) = try Library.create(at: try folder.folder("Books"))
        #expect(descriptor.name == "Books")
    }

    @Test("authorSortOverrides survives a round trip through library.json")
    func authorSortOverridesRoundTrip() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Lib")
        var (library, descriptor) = try Library.create(at: root)
        descriptor.authorSortOverrides["Ludwig van Beethoven"] = "van Beethoven, Ludwig"
        try library.write(descriptor)

        let reread = try library.readDescriptor()
        #expect(reread.authorSortOverrides["Ludwig van Beethoven"] == "van Beethoven, Ludwig")
    }

    /// A `library.json` written before this field existed has no key for it
    /// at all — the same leniency `customColumns` already needed.
    @Test("a library.json with no authorSortOverrides key decodes to an empty one")
    func authorSortOverridesDefaultsWhenMissing() throws {
        let json = """
            {"schemaVersion": 1, "name": "Old Library", "createdAt": "2026-01-01T00:00:00Z"}
            """
        let descriptor = try LibraryDescriptor.decoder.decode(LibraryDescriptor.self, from: Data(json.utf8))
        #expect(descriptor.authorSortOverrides.isEmpty)
        #expect(descriptor.shelves.isEmpty)
        #expect(descriptor.customColumns.isEmpty)
    }

    /// Overwriting `library.json` would orphan the index and with it every
    /// shelf the user built by hand.
    @Test("creating a library where one already is, is refused")
    func createTwice() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Lib")
        try Library.create(at: root)
        #expect(throws: Library.Failure.alreadyALibrary("Lib")) { try Library.create(at: root) }
    }

    @Test("opening a folder that is not a library says so")
    func openNonLibrary() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Just A Folder")
        #expect(throws: Library.Failure.notALibrary("Just A Folder")) { try Library.open(root) }
    }

    @Test("what was created is what is read back")
    func reopen() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Lib")
        var (library, descriptor) = try Library.create(at: root, name: "Lib")
        descriptor.nextBookNumber = 42
        descriptor.shelves = [Shelf(name: "Fiction")]
        try library.write(descriptor)

        let (reopened, read) = try Library.open(root)
        #expect(read.nextBookNumber == 42)
        #expect(read.shelves.map(\.name) == ["Fiction"])
        #expect(reopened.root == library.root)
    }

    /// A library written by a newer Shelf could hold fields this version does
    /// not know, and writing it back would drop them.
    @Test("a library from a newer Shelf is refused rather than risked")
    func newerSchema() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Future")
        let (library, _) = try Library.create(at: root)
        var descriptor = try library.readDescriptor()
        descriptor.schemaVersion = LibraryDescriptor.currentSchemaVersion + 5
        try library.write(descriptor)

        #expect(
            throws: Library.Failure.newerSchema(
                found: LibraryDescriptor.currentSchemaVersion + 5,
                supported: LibraryDescriptor.currentSchemaVersion)
        ) { try Library.open(root) }
    }

    @Test("a lost covers folder is recreated on open rather than failing")
    func coversFolderRecreated() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Lib")
        let (library, _) = try Library.create(at: root)
        try FileManager.default.removeItem(at: library.coversFolder)
        #expect(!folder.exists("Lib/.shelf/covers"))

        _ = try Library.open(root)
        #expect(folder.exists("Lib/.shelf/covers"))
    }

    /// The number is stored rather than derived from the highest folder, so a
    /// book deleted in the Finder cannot make the next import reuse its number
    /// and land in a folder that still has files in it.
    @Test("book numbers are handed out from a stored counter and never reused")
    func bookNumbers() {
        var descriptor = LibraryDescriptor(name: "x")
        #expect(descriptor.takeBookNumber() == 1)
        #expect(descriptor.takeBookNumber() == 2)
        #expect(descriptor.nextBookNumber == 3)
    }

    @Test("the paths inside a library are the ones the concept names")
    func paths() {
        let library = Library(root: URL(fileURLWithPath: "/books/My Library"))
        #expect(library.privateFolder.lastPathComponent == ".shelf")
        #expect(library.indexURL.lastPathComponent == "library.sqlite")
        #expect(library.descriptorURL.lastPathComponent == "library.json")
        #expect(library.coversFolder.lastPathComponent == "covers")
        #expect(
            library.folder(for: Book(title: "Emma", authors: ["Jane Austen"]), number: 3).path
                == "/books/My Library/Austen, Jane/Emma (3)")
    }

    /// SQLite in a synced folder is a known way to lose a database. Shelf opens
    /// it anyway – the folder is still the truth – but says so first.
    @Test("a library in a synced folder is opened with a warning, not refused")
    func syncWarning() {
        let iCloud = Library(
            root: URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Books"))
        #expect(iCloud.syncWarning?.contains("iCloud Drive") == true)

        let dropbox = Library(root: URL(fileURLWithPath: "/Users/x/Dropbox/Books"))
        #expect(dropbox.syncWarning?.contains("Dropbox") == true)

        #expect(Library(root: URL(fileURLWithPath: "/Volumes/Books/Library")).syncWarning == nil)
    }

    @Test("library.json is readable text with sorted keys and ISO dates")
    func descriptorFormat() throws {
        let folder = try TemporaryFolder()
        let root = try folder.folder("Lib")
        try Library.create(at: root, name: "Lib")
        let text = try String(contentsOf: Library(root: root).descriptorURL, encoding: .utf8)
        #expect(text.contains("\"createdAt\""))
        #expect(text.contains("\"schemaVersion\" : 1"))
        // Sorted keys: createdAt comes before name comes before nextBookNumber.
        guard let created = text.range(of: "createdAt"), let name = text.range(of: "\"name\"") else {
            Issue.record("the descriptor is missing its keys")
            return
        }
        #expect(created.lowerBound < name.lowerBound)
    }
}

@Suite("What the file system says about a file")
struct FileFactsTests {

    @Test("size and date come from the file itself")
    func plainFile() throws {
        let folder = try TemporaryFolder()
        let payload = Data(repeating: 0xAB, count: 4_096)
        let url = try folder.write("book.epub", data: payload)

        guard let facts = FileFacts.of(url) else {
            Issue.record("no facts for a file that exists")
            return
        }
        #expect(facts.byteSize == 4_096)
        #expect(facts.url.lastPathComponent == "book.epub")
    }

    /// `attributesOfItem(atPath:)` reports a *symlink's* own size – about eighty
    /// bytes – while `FileHandle` follows the link and reads the real content.
    /// A symlinked book therefore imported with the right bytes and the wrong
    /// size. Found by importing real books through symlinks.
    @Test("a symlink is followed, so the size is the real file's")
    func symlink() throws {
        let folder = try TemporaryFolder()
        let payload = Data(repeating: 0xCD, count: 10_000)
        let real = try folder.write("real/book.epub", data: payload)
        let link = folder.url.appendingPathComponent("link.epub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // What the naive reading would have said.
        let naive = try FileManager.default.attributesOfItem(atPath: link.path)[.size] as? Int64
        #expect(naive != 10_000)

        guard let facts = FileFacts.of(link) else {
            Issue.record("no facts for a symlink")
            return
        }
        #expect(facts.byteSize == 10_000)
        #expect(facts.url.lastPathComponent == "book.epub")
    }

    @Test("a file that is not there has no facts, rather than zero ones")
    func missing() {
        #expect(FileFacts.of(URL(fileURLWithPath: "/nonexistent/nothing.epub")) == nil)
    }
}
