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
                return target
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
        #expect(result.displaced.isEmpty)
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

        #expect(result.displaced == ["cover.jpg"])
        #expect(bin.taken == ["cover.jpg"])
        let recovered = try Data(contentsOf: bin.folder.appendingPathComponent("cover.jpg"))
        #expect(recovered == Self.jpeg(0xAB))
    }

    /// **The gap, closed.** The Trash used to be asked first, so while
    /// `trashItem` ran (or if the process died there) the book had no cover
    /// and the OPF claimed otherwise. Now the new picture is already at its
    /// path when the disposal is asked — checked from inside the disposal.
    @Test("the new cover is already in place when the Trash is asked for the old one")
    func newCoverIsInPlaceBeforeDisposal() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))
        let seen = Seen()
        let disposal = FolderDisposal { url in
            seen.coverAtDisposal = try? Data(contentsOf: folder.appendingPathComponent("cover.png"))
            return nil
        }

        try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: disposal)

        #expect(seen.coverAtDisposal == Self.png())
    }

    private final class Seen: @unchecked Sendable { var coverAtDisposal: Data? }

    /// The book is already correct when the Trash refuses, so that is a fact
    /// in the result and not a throw. The old picture is not lost and not
    /// swept: it stays in the folder under a hidden name that is not `.part`.
    @Test("a disposal that fails after the swap is reported, and the old cover is kept")
    func aFailedDisposalIsAFactNotAThrow() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))

        let result = try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: .none)

        #expect(result.generation == 1)
        #expect(result.written?.lastPathComponent == "cover.png")
        #expect(result.displaced == ["cover.jpg"])
        #expect(result.leftBehind.count == 1)
        let kept = try #require(result.leftBehind.first)
        #expect(kept.hasPrefix(CoverReplacement.asidePrefix))
        #expect(kept.hasSuffix("/cover.jpg"))
        #expect(try Data(contentsOf: folder.appendingPathComponent(kept)) == Self.jpeg(0xAB))
        #expect(CoverFile.url(in: folder)?.lastPathComponent == "cover.png")

        // The next write into that folder does not take it away.
        try CoverReplacement.replace(
            with: Self.png(0x33), in: folder, previousGeneration: 1, disposal: .none)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(kept).path))
    }

    // MARK: The failure branches of the swap

    /// The new picture cannot be renamed onto its path: a dangling symlink
    /// named `cover.png` is not "a cover" to `CoverFile.urls` (it follows the
    /// link), so it is not set aside, and `moveItem` refuses to land on it.
    /// Every cover that was set aside goes back to its own name.
    @Test("a failed rename of the new cover puts the old ones back")
    func failedLandingRollsBack() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("cover.png").path,
            withDestinationPath: "/nonexistent-shelf-test-target")

        #expect(throws: CoverReplacement.Refusal.self) {
            try CoverReplacement.replace(
                with: Self.png(), in: folder, previousGeneration: 0, disposal: .none)
        }

        #expect(try Data(contentsOf: folder.appendingPathComponent("cover.jpg")) == Self.jpeg(0xAB))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(CoverReplacement.asidePrefix) })
        #expect(!names.contains { $0.hasSuffix(".part") })
    }

    /// Two covers, the second cannot be renamed into the holder (a directory
    /// without write permission cannot change its parent): the first, already
    /// moved, goes back, the holder goes, nothing is written.
    @Test("a rename that fails inside setAside puts the earlier ones back")
    func failedSetAsideRollsBack() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        try Self.jpeg(0xA1).write(to: folder.appendingPathComponent("cover.jpg"))
        let stuck = folder.appendingPathComponent("cover.jpeg", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stuck.path)
        }

        #expect(throws: CoverReplacement.Refusal.self) {
            try CoverReplacement.replace(
                with: Self.png(), in: folder, previousGeneration: 0, disposal: .none)
        }

        #expect(try Data(contentsOf: folder.appendingPathComponent("cover.jpg")) == Self.jpeg(0xA1))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(CoverReplacement.asidePrefix) })
        #expect(!names.contains("cover.png"))
        #expect(!names.contains { $0.hasSuffix(".part") })
    }

    // MARK: Recovery of what an earlier swap left

    /// A crash between `setAside` and the landing of the new file leaves a
    /// book with no cover and the picture in a holder. The next replace
    /// brings it back before it does anything else, so it ends up in the
    /// Trash by the normal route instead of in a hidden folder for ever.
    @Test("a cover stranded in a holder by a crash is recovered by the next replace")
    func strandedCoverIsRecovered() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        let holder = folder.appendingPathComponent("\(CoverReplacement.asidePrefix)deadbeef")
        try FileManager.default.createDirectory(at: holder, withIntermediateDirectories: false)
        try Self.jpeg(0xAB).write(to: holder.appendingPathComponent("cover.jpg"))

        let result = try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        #expect(result.leftBehind.isEmpty)
        #expect(result.displaced == ["cover.jpg"])
        #expect(bin.taken == ["cover.jpg"])
        #expect(!FileManager.default.fileExists(atPath: holder.path))
        #expect(CoverFile.url(in: folder)?.lastPathComponent == "cover.png")
    }

    /// Refusals must not pile up: once the Trash works again, the next
    /// replace disposes of what an earlier refusal left and removes the holder.
    @Test("a picture an earlier refusal left behind goes to the Trash on the next replace")
    func refusedPictureIsRetried() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))
        let first = try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: .none)
        #expect(first.leftBehind.count == 1)

        let second = try CoverReplacement.replace(
            with: Self.png(0x33), in: folder, previousGeneration: 1, disposal: bin.disposal)

        #expect(second.leftBehind.isEmpty)
        #expect(bin.taken.sorted() == ["cover.jpg", "cover.png"])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(CoverReplacement.asidePrefix) })
    }

    @Test("a refusing Trash on the retry leaves the picture and still reports it")
    func refusedPictureStaysReported() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))
        try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: .none)

        let second = try CoverReplacement.replace(
            with: Self.png(0x33), in: folder, previousGeneration: 1, disposal: .none)

        let kept = second.leftBehind.filter { $0.hasSuffix("/cover.jpg") }
        #expect(kept.count == 1)
        let path = try #require(kept.first)
        #expect(try Data(contentsOf: folder.appendingPathComponent(path)) == Self.jpeg(0xAB))
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

        #expect(result.written?.lastPathComponent == "cover.jpg")
        #expect(temporary.names(in: "Austen, Jane/Emma (1)") == ["cover.jpg"])
    }

    /// **A folder can hold more than one cover**, and garbage-collecting only
    /// the first is worse than collecting none: `CoverFile.extensions` is
    /// searched in order, `jpeg` comes before `png`, so a surviving
    /// `cover.jpeg` is found *in preference to* the picture that was just
    /// written. The window then shows the old one again and the disk says it
    /// was replaced.
    ///
    /// Grown Calibre folders really do hold both spellings.
    @Test("every cover in the folder is displaced, not just the first one found")
    func allOfThemAreDisplaced() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Self.jpeg(0xA1).write(to: folder.appendingPathComponent("cover.jpg"))
        try Self.jpeg(0xA2).write(to: folder.appendingPathComponent("cover.jpeg"))

        let result = try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        // In `CoverFile.extensions` order, which is the order that decides
        // which of the two the window would have drawn.
        #expect(result.displaced == ["cover.jpg", "cover.jpeg"])
        #expect(temporary.names(in: "Austen, Jane/Emma (1)") == ["cover.png"])
        #expect(bin.taken.sorted() == ["cover.jpeg", "cover.jpg"])
    }

    // MARK: The half-written file

    /// Every runner in this project that writes through a `.part` names its
    /// prefix and sweeps its own leftovers — `ImportRunner.removePartials`,
    /// `ExportRunner`. This one does the same, and in the same place: the next
    /// write into that folder.
    ///
    /// It matters because nothing else would ever take it away.
    /// `CoverFile.isCover` says no, so `EmptiedFolder` counts it as somebody's
    /// data and keeps the folder alive, and `OrphanedFolders` adds its bytes to
    /// a folder it reports. A file Shelf dropped would be reported to the user
    /// as a file Shelf found.
    @Test("a half-written cover left by an interrupted run is swept by the next one")
    func leftoverPartIsSwept() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        let leftover = "\(CoverReplacement.partialPrefix)deadbeef.part"
        try Self.jpeg().write(to: folder.appendingPathComponent(leftover))

        try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        #expect(temporary.names(in: "Austen, Jane/Emma (1)") == ["cover.png"])
        // Swept, not moved to the Trash: it is Shelf's own debris and never was
        // anybody's picture. The Trash is for what a person might want back.
        #expect(bin.taken.isEmpty)
    }

    @Test("a dot file that is not Shelf's debris is left exactly where it is")
    func otherDotFilesAreNotSwept() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Data("keep me".utf8).write(to: folder.appendingPathComponent(".notes"))

        try CoverReplacement.replace(
            with: Self.png(), in: folder, previousGeneration: 0, disposal: bin.disposal)

        #expect(temporary.names(in: "Austen, Jane/Emma (1)") == [".notes", "cover.png"])
    }

    // MARK: Refusing before anything moves

    /// What the window asks *before* it writes the new generation into the
    /// OPF, so that bytes which were never a picture cost nothing at all.
    @Test("whether bytes could be a cover is answerable without writing anything")
    func acceptsIsAnswerableOnItsOwn() {
        #expect(CoverReplacement.accepts(Self.png()))
        #expect(CoverReplacement.accepts(Self.jpeg()))
        #expect(!CoverReplacement.accepts(Data("<html>Not Found</html>".utf8)))
        #expect(!CoverReplacement.accepts(Data()))
    }

    // MARK: Taking one away

    /// Not a menu item — **undo**. Setting the first cover on a book that had
    /// none has to be undoable, and the only honest undo of that is a folder
    /// with no cover in it again. Without this, undo would leave the picture
    /// where it was and only move the number back, which is the worst of both:
    /// the file says one thing and the book says another.
    @Test("removing a cover takes the file away and still raises the generation")
    func removing() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)
        try Self.jpeg(0xAB).write(to: folder.appendingPathComponent("cover.jpg"))

        let result = try CoverReplacement.remove(
            in: folder, previousGeneration: 2, disposal: bin.disposal)

        #expect(result.written == nil)
        #expect(result.displaced == ["cover.jpg"])
        // The generation moves even though nothing was written: what the grid
        // holds is a thumbnail of a picture that is no longer there.
        #expect(result.generation == 3)
        #expect(temporary.names(in: "Austen, Jane/Emma (1)").isEmpty)
        #expect(try Data(contentsOf: bin.folder.appendingPathComponent("cover.jpg")) == Self.jpeg(0xAB))
    }

    @Test("removing a cover from a book that has none changes nothing at all")
    func removingNothing() throws {
        let temporary = try TemporaryFolder()
        let folder = try temporary.folder("Austen, Jane/Emma (1)")
        let bin = try Bin(in: temporary.url)

        let result = try CoverReplacement.remove(
            in: folder, previousGeneration: 2, disposal: bin.disposal)

        #expect(result.displaced.isEmpty)
        // No file changed, so no cached thumbnail is stale.
        #expect(result.generation == 2)
        #expect(bin.taken.isEmpty)
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
            previousGeneration: book.coverGeneration, disposal: FolderDisposal { _ in nil })
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

/// How big a picture is allowed to be once it is a cover, and when it is left
/// exactly as it arrived.
///
/// The *rule* is here and the ImageIO that carries it out is in `App/Shelf`,
/// the same split `EmptiedFolder` has from `FolderDisposal` and
/// `BookFileReader` has from `PDFFileReader`: the decision is a pure function
/// tested on Linux, the act needs a Mac.
///
/// Two things are being kept apart. A person dropping a 40 MB photograph next
/// to an 800 KB book has made a library that is mostly pictures of books. And a
/// cover that is already the right size must come through **byte for byte**:
/// re-encoding it would lose quality to gain nothing, which is the rule
/// `ImportRunner.writeCover` has followed since Sprint 1.
@Suite("How large a cover is allowed to be")
struct CoverImageRuleTests {

    private func facts(_ width: Int, _ height: Int, _ ext: String? = "jpg") -> CoverImageFacts {
        CoverImageFacts(pixelWidth: width, pixelHeight: height, fileExtension: ext)
    }

    @Test("a cover already within the limit is written exactly as it arrived")
    func smallEnoughIsUntouched() {
        #expect(CoverImageRule.preparation(for: facts(1_000, 1_500)) == .asIs)
        #expect(CoverImageRule.preparation(for: facts(1_600, 1_067)) == .asIs)
    }

    @Test("a picture longer than the limit is brought down to it")
    func tooLargeIsScaled() {
        #expect(
            CoverImageRule.preparation(for: facts(4_000, 6_000))
                == .reencode(longEdge: CoverImageRule.maxEdgePixels))
        // Landscape too: the *long* edge is the one that is measured, whichever
        // way round the picture is. A comic page scanned in a spread is wide.
        #expect(
            CoverImageRule.preparation(for: facts(6_000, 4_000))
                == .reencode(longEdge: CoverImageRule.maxEdgePixels))
    }

    /// The open panel offers HEIC and TIFF because a Mac is full of both, and
    /// `CoverFile` can name neither — a folder holding `cover.heic` has a book
    /// with no cover as far as every other part of this program is concerned.
    /// So those are always written again as JPEG, however small they are.
    @Test("a format the folder cannot name is written again as JPEG, at its own size")
    func unnameableIsTranscoded() {
        #expect(CoverImageRule.preparation(for: facts(800, 1_200, nil)) == .reencode(longEdge: 1_200))
    }

    /// Scaling a 400 px scan *up* to the limit would make a blurry file four
    /// times the size of the sharp one. The limit is a ceiling, never a target.
    @Test("a small picture is never enlarged to meet the limit")
    func neverEnlarged() {
        #expect(CoverImageRule.preparation(for: facts(300, 400, nil)) == .reencode(longEdge: 400))
    }

    /// A picture ImageIO could not measure at all. Re-encoding at the ceiling
    /// is the safe answer: whatever it is, what lands beside the book is a
    /// JPEG of a size this program chose.
    @Test("a picture whose size could not be read is re-encoded at the ceiling")
    func unmeasurable() {
        #expect(
            CoverImageRule.preparation(for: facts(0, 0, nil))
                == .reencode(longEdge: CoverImageRule.maxEdgePixels))
    }
}

/// The two-write protocol behind changing a cover, end to end: the generation
/// through `MetadataEditor`, then the picture through `CoverReplacement`, with
/// the generation put back if the picture write fails.
///
/// This is `LibraryModel.applyCover`'s core, pulled out here so it is
/// testable at all — `LibraryModel` lives in `App/Shelf` and has no test
/// target of its own (`docs/BACKLOG.md`).
@Suite("Committing a cover change: the generation, then the picture")
struct CoverChangeCommitTests {

    private func png(_ seed: UInt8 = 1) -> Data {
        MinimalPNG.cover(width: 10, height: 15, seed: seed)
    }

    /// A book on disk with an index entry to match, ready for `commit`.
    private func book(
        in temporary: TemporaryFolder, withCover: Bool
    ) async throws -> (library: Library, entry: LibraryEntry, folder: URL, index: LibraryIndex) {
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let book = Book(title: "Emma", authors: ["Jane Austen"])
        let folder = library.root.appendingPathComponent("Austen, Jane/Emma (1)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("PK\u{03}\u{04}".utf8).write(to: folder.appendingPathComponent("Emma.epub"))
        if withCover {
            try png(9).write(to: folder.appendingPathComponent("cover.png"))
        }
        try OPFDocument.write(book, to: folder)
        let entry = LibraryEntry(book: book, number: 1, folder: "Austen, Jane/Emma (1)")
        let index = try LibraryIndex(inMemory: "commit-\(UUID().uuidString)")
        try await index.save(entry)
        return (library, entry, folder, index)
    }

    /// The Trash refusing after the swap used to vanish between `replace` and
    /// the window. `commit` now carries it, and the generation stays raised.
    @Test("a Trash that refuses after the swap reaches the caller through commit")
    func leftBehindSurvivesCommit() async throws {
        let temporary = try TemporaryFolder()
        let (library, entry, _, index) = try await book(in: temporary, withCover: true)

        let outcome = try await CoverReplacement.commit(
            png(2), to: entry, library: library, index: index, disposal: .none)

        guard case .wrote(let updated, let leftBehind) = outcome else {
            Issue.record("expected .wrote, got \(outcome)")
            return
        }
        #expect(updated.book.coverGeneration == 1)
        #expect(leftBehind.count == 1)
        #expect(leftBehind.first?.hasSuffix("/cover.png") == true)
    }

    @Test("a successful commit writes the picture and the generation together")
    func successWritesBoth() async throws {
        let temporary = try TemporaryFolder()
        let (library, entry, folder, index) = try await book(in: temporary, withCover: false)

        let outcome = try await CoverReplacement.commit(
            png(), to: entry, library: library, index: index)

        guard case .wrote(let updated, _) = outcome else {
            Issue.record("expected .wrote, got \(outcome)")
            return
        }
        #expect(updated.book.coverGeneration == 1)
        #expect(CoverFile.url(in: folder) != nil)

        // The OPF and the index agree with what `commit` returned.
        let onDisk = try OPFDocument.read(
            Data(contentsOf: folder.appendingPathComponent("metadata.opf")), fallbackTitle: "x")
        #expect(onDisk.book.coverGeneration == 1)
        let indexed = try await index.entry(id: entry.id)
        #expect(indexed?.book.coverGeneration == 1)
    }

    /// `commit(nil, …)` is what "Remove Cover" calls in the window
    /// (`LibraryModel.applyCover`) — the same two-write protocol as a
    /// replacement, only the picture half takes the file away instead of
    /// writing a new one. `CoverReplacement.remove` itself is tested above;
    /// this is the path the menu item actually goes down.
    @Test("commit(nil, …) is Remove Cover: it takes the file away and still bumps the generation")
    func removingThroughCommit() async throws {
        let temporary = try TemporaryFolder()
        let (library, entry, folder, index) = try await book(in: temporary, withCover: true)

        let outcome = try await CoverReplacement.commit(
            nil, to: entry, library: library, index: index)

        guard case .wrote(let updated, _) = outcome else {
            Issue.record("expected .wrote, got \(outcome)")
            return
        }
        #expect(updated.book.coverGeneration == 1)
        #expect(CoverFile.url(in: folder) == nil)

        let onDisk = try OPFDocument.read(
            Data(contentsOf: folder.appendingPathComponent("metadata.opf")), fallbackTitle: "x")
        #expect(onDisk.book.coverGeneration == 1)
        let indexed = try await index.entry(id: entry.id)
        #expect(indexed?.book.coverGeneration == 1)
    }

    /// **The test this whole fix hangs on.** A failed picture write fails the
    /// second half of the write; the generation was already bumped in the
    /// first. Left alone, `metadata.opf` would claim the cover was changed
    /// when the folder says otherwise. Driven through Remove Cover, whose
    /// disposal still runs before anything else and can still refuse
    /// (`replace` no longer can: its disposal comes after the swap).
    @Test("a failed picture write reverts the generation, so the OPF does not lie about it")
    func failedPictureWriteRevertsTheGeneration() async throws {
        let temporary = try TemporaryFolder()
        let (library, entry, folder, index) = try await book(in: temporary, withCover: true)

        let outcome = try await CoverReplacement.commit(
            nil, to: entry, library: library, index: index, disposal: .none)

        guard case .refused(let refusal) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        guard case .cannotDisplace = refusal else {
            Issue.record("expected .cannotDisplace, got \(refusal)")
            return
        }
        let onDisk = try OPFDocument.read(
            Data(contentsOf: folder.appendingPathComponent("metadata.opf")), fallbackTitle: "x")
        #expect(onDisk.book.coverGeneration == 0)
        let indexed = try await index.entry(id: entry.id)
        #expect(indexed?.book.coverGeneration == 0)
        #expect(try Data(contentsOf: folder.appendingPathComponent("cover.png")) == png(9))
    }

    /// The other side of the same change: a Trash that refuses after a
    /// replacement's swap must NOT revert the generation — the picture did
    /// change, and reverting would make the window draw the old thumbnail.
    @Test("a Trash that refuses after the swap keeps the new generation")
    func disposalFailureAfterSwapKeepsTheGeneration() async throws {
        let temporary = try TemporaryFolder()
        let (library, entry, folder, index) = try await book(in: temporary, withCover: true)

        let outcome = try await CoverReplacement.commit(
            png(2), to: entry, library: library, index: index, disposal: .none)

        guard case .wrote(let updated, _) = outcome else {
            Issue.record("expected .wrote, got \(outcome)")
            return
        }
        #expect(updated.book.coverGeneration == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent("cover.png")) == png(2))
    }
}
