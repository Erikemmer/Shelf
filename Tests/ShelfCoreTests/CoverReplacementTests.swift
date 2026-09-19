import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// Replacing the cover beside a book.
///
/// Until now a cover arrived exactly twice: at import, out of the book file,
/// and from the net when the folder had none. Both were one-way. This is the
/// path that puts a *different* picture there, and the two things it must not
/// get wrong are the two things a picture on disk can be wrong about: the old
/// file being gone rather than recoverable, and the new file being there while
/// the window still draws the old one.
@Suite("Replacing the cover beside a book")
struct CoverReplacementTests {

    /// The smallest bytes `CoverFile` will name. The magic number is what is
    /// being tested around, so the rest of the file is filler.
    private static func jpeg(_ filler: UInt8 = 0x11) -> Data {
        Data([0xFF, 0xD8, 0xFF] + Array(repeating: filler, count: 29))
    }

    private static func png(_ filler: UInt8 = 0x22) -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: filler, count: 24))
    }

    /// A disposal that moves what it is given into a folder of its own, so a
    /// test can ask both "is it gone from the book folder" and "can it still be
    /// got back" — which is what the Trash means and what `removeItem` does not.
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
            }
        }
    }

    // MARK: The generation

    /// **The test the whole feature hangs on.** The cover cache is keyed by
    /// UUID, size and generation (ADR 0005, decision 4) and the generation is
    /// the only part of that key a replaced cover can change. Without the bump
    /// the new picture is on disk and the grid goes on drawing the old one
    /// out of `.shelf/covers/` — right on the disk, wrong in the window.
    @Test("replacing a cover raises the generation, so the cached thumbnail misses")
    func replacingRaisesTheGeneration() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Self.jpeg().write(to: folder.appendingPathComponent("cover.jpg"))

        let result = try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        #expect(result.generation == 1)
        let before = CoverCacheKey(bookID: UUID(), pixelWidth: 400, generation: 0)
        var after = before
        after.generation = result.generation
        #expect(before != after)
    }

    @Test("a book that had no cover at all starts at generation 1 like any other")
    func firstCoverAlsoCounts() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)

        let result = try CoverReplacement.replace(
            with: Self.jpeg(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        #expect(result.generation == 1)
        #expect(result.displaced == nil)
        #expect(bin.taken.isEmpty)
    }

    // MARK: What happens to the picture that was there

    /// "Nothing is deleted outright" has to be a rule about the mechanism and
    /// not only about the intent — the lesson `OrganizeRunner` paid for in the
    /// closing run. The replaced cover is somebody's own scan as often as not.
    @Test("the cover that was there goes to the disposal, not to removeItem")
    func theOldCoverIsRecoverable() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))

        let result = try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 3, disposal: bin.disposal)

        #expect(result.displaced == "cover.jpg")
        #expect(bin.taken == ["cover.jpg"])
        let recovered = try Data(contentsOf: bin.folder.appendingPathComponent("cover.jpg"))
        #expect(recovered == Self.jpeg(0xAB))
    }

    /// A disposal that cannot move the old file leaves everything exactly as it
    /// was. The alternative is to overwrite it, which is the one thing this
    /// project does not do.
    @Test("a disposal that fails means nothing is written and nothing is lost")
    func aFailedDisposalChangesNothing() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))

        #expect(throws: CoverReplacement.Refusal.self) {
            try CoverReplacement.replace(
                with: Self.png(), in: folder, previousGeneration: 0, disposal: .none)
        }

        let untouched = try Data(contentsOf: folder.appendingPathComponent("cover.jpg"))
        #expect(untouched == Self.jpeg(0xAB))
        // And no half-written file left beside it.
        #expect(temporary.names(in: "Austen, Jane/Emma (1)") == ["cover.jpg"])
    }

    /// The old cover is `cover.png` and the new one is a JPEG: writing
    /// `cover.jpg` beside it would leave two covers in the folder, and
    /// `CoverFile.url` answers with whichever comes first in its list — so the
    /// window would draw one of them and the Finder would show the other.
    @Test("a new cover in another format does not leave the old one beside it")
    func theExtensionFollowsTheBytes() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Self.png().write(to: folder.appendingPathComponent("cover.png"))

        let result = try CoverReplacement.replace(
            with: Self.jpeg(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        #expect(result.written.lastPathComponent == "cover.jpg")
        #expect(temporary.names(in: "Austen, Jane/Emma (1)") == ["cover.jpg"])
    }

    // MARK: What is refused

    /// A service that answers an HTML error page with a 200, or somebody
    /// dropping a `.txt` on the inspector. Checked *before* the old cover is
    /// touched, so a book cannot lose its picture to a file that was never one.
    @Test("bytes that are not a picture are refused before anything is displaced")
    func notAnImage() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))

        #expect(throws: CoverReplacement.Refusal.notAnImage) {
            try CoverReplacement.replace(
                with: Data("<html>Not Found</html>".utf8), in: folder, previousGeneration: 0,
                disposal: bin.disposal)
        }
        #expect(bin.taken.isEmpty)
        #expect(try Data(contentsOf: folder.appendingPathComponent("cover.jpg")) == Self.jpeg(0xAB))
    }

    /// The rule that is not negotiable: a book file is never written, deleted
    /// or overwritten (CONCEPT §4, "Won't"). A cover lands beside it and
    /// nowhere else.
    @Test("the book file beside the cover is not touched, byte for byte")
    func theBookFileIsNotTouched() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        let bookFile = folder.appendingPathComponent("Emma.epub")
        let bookBytes = Data("PK\u{03}\u{04}a whole book".utf8)
        try bookBytes.write(to: bookFile)
        try Self.jpeg().write(to: folder.appendingPathComponent("cover.jpg"))

        try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        #expect(try Data(contentsOf: bookFile) == bookBytes)
        #expect(temporary.names(in: "Austen, Jane/Emma (1)") == ["Emma.epub", "cover.png"])
    }
}

/// Where the generation has to live for the window to be right twice: after
/// the app is started again, and after the index has been thrown away.
///
/// The number is kept in the book, which means in `metadata.opf` — the same
/// answer ADR 0008 gave the shelves and ADR 0010 gave Calibre's columns. The
/// folder is the truth and the index is a cache (ADR 0001), so anything the
/// index alone remembered would be forgotten by
/// `Library ▸ Rebuild Index from Folders`, and the grid would go back to a
/// thumbnail of the picture the user replaced.
@Suite("A replaced cover is still the new one tomorrow")
struct CoverGenerationTests {

    private func book(generation: Int) -> Book {
        var book = Book(title: "Emma", authors: ["Jane Austen"])
        book.coverGeneration = generation
        return book
    }

    @Test("the generation goes through the OPF and comes back")
    func opfRoundTrip() throws {
        let written = book(generation: 4)
        let parsed = try OPFDocument.read(Data(OPFDocument.render(written).utf8), fallbackTitle: "x")
        #expect(parsed.book.coverGeneration == 4)
    }

    /// A book nobody has ever changed the cover of has no such meta, and an
    /// imported Calibre library has none either. Zero, not a failure to parse.
    @Test("an OPF without the meta is generation zero, and writes no meta")
    func absentMeansZero() throws {
        let plain = book(generation: 0)
        let text = OPFDocument.render(plain)
        #expect(!text.contains("cover_generation"))
        let parsed = try OPFDocument.read(Data(text.utf8), fallbackTitle: "x")
        #expect(parsed.book.coverGeneration == 0)
    }

    @Test("the index carries the generation back, so a restart draws the new cover")
    func theIndexKeepsIt() async throws {
        let index = try LibraryIndex(inMemory: "cover-generation")
        var entry = LibraryEntry(book: book(generation: 7), number: 1, folder: "Austen, Jane/Emma (1)")
        entry.book.coverGeneration = 7
        try await index.save(entry)

        let read = try await index.entry(id: entry.id)
        #expect(read?.book.coverGeneration == 7)
    }

    /// **The whole chain, end to end**, and the one the brief asks for by
    /// name: replace the picture, write the number through the same editor
    /// every other field goes through, throw the index away, rebuild from the
    /// folders — and the grid still asks for the new cover rather than the
    /// thumbnail of the old one.
    @Test("a rebuild from the folders keeps the new cover, not the old thumbnail")
    func itSurvivesARebuild() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let book = Book(title: "Emma", authors: ["Jane Austen"])
        let folder = library.root.appendingPathComponent("Austen, Jane/Emma (1)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("PK\u{03}\u{04}".utf8).write(to: folder.appendingPathComponent("Emma.epub"))
        try OPFDocument.write(book, to: folder)
        let entry = LibraryEntry(book: book, number: 1, folder: "Austen, Jane/Emma (1)")

        let index = try LibraryIndex(inMemory: "rebuild-cover")
        try await index.save(entry)

        // What the inspector does: put the picture there, then write the number
        // the picture changed.
        let replaced = try CoverReplacement.replace(
            with: MinimalPNG.cover(width: 10, height: 15, seed: 3), in: folder,
            previousGeneration: book.coverGeneration, disposal: FolderDisposal { _ in })
        let change = MetadataChange.make(from: book) { $0.coverGeneration = replaced.generation }
        try await MetadataEditor(library: library).apply(change, to: entry, in: index)

        // And now the index is thrown away, which is what ADR 0001 says may
        // happen at any time.
        let rebuilt = try IndexRebuilder(makeHasher: PortableSHA256Hasher.factory).rebuild(library)
        #expect(rebuilt.entries.first?.book.coverGeneration == 1)
    }

    /// Changing a cover is an edit like any other, so it is undone like any
    /// other and the Edit menu names it.
    @Test("a changed cover is a field of its own, with its own name in the Edit menu")
    func itIsAField() {
        let before = book(generation: 0)
        var after = before
        after.coverGeneration = 1
        let change = MetadataChange(before: before, after: after)

        #expect(!change.isEmpty)
        #expect(change.fields == [.cover])
        #expect(change.actionName == "Cover")
        #expect(change.inverse.after.coverGeneration == 0)
    }
}
