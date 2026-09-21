import Foundation
import Testing

@testable import ShelfCore

/// `Organize Library…` — the first thing in this program that moves a book's
/// folder.
///
/// Every trap the brief names has a test here, and most of them are traps
/// because they are silent: a collision that picks a winner buries a book, a
/// case-only rename on a Mac is a write into itself, and a `moveItem` that
/// returns success is not the same as a folder that arrived.
@Suite("Putting the folders back in step with the metadata")
struct OrganizeTests {

    private func entry(
        _ title: String, author: String = "Jane Austen", number: Int = 1, folder: String? = nil
    ) -> LibraryEntry {
        let book = Book(title: title, authors: [author])
        let path = folder ?? BookFolderName.relativePath(for: book, number: number)
        return LibraryEntry(book: book, number: number, folder: path, formats: [])
    }

    /// Everything the plan asks about the disk, answered from a set.
    private func exists(_ paths: Set<String>) -> (String) -> Bool { { paths.contains($0) } }

    // MARK: The plan

    @Test("a book whose folder already matches its metadata is counted, not moved")
    func alreadyInPlace() {
        let book = entry("Emma")
        let plan = OrganizePlanner.plan(
            entries: [book], foldsCase: true, folderExists: exists([book.folder]))
        #expect(plan.moves.isEmpty)
        #expect(plan.alreadyInPlace == 1)
    }

    @Test("a folder named after an old title is moved to the new one")
    func staleFolderMoves() {
        let book = entry("Ancillary Justice", folder: "Austen, Jane/Ancilary Justice (1)")
        let plan = OrganizePlanner.plan(
            entries: [book], foldsCase: true, folderExists: exists([book.folder]))
        #expect(plan.moves.count == 1)
        #expect(plan.moves.first?.from == "Austen, Jane/Ancilary Justice (1)")
        #expect(plan.moves.first?.to == "Austen, Jane/Ancillary Justice (1)")
        #expect(plan.moves.first?.isCaseOnly == false)
    }

    // MARK: Collisions

    /// Two books wanting one path: **both** are left alone. Picking one of them
    /// is how a book quietly ends up inside another book's folder.
    @Test("two books that want the same folder are both left where they are")
    func collision() {
        // The running number is what normally keeps two same-named books
        // apart, so the collision has to be made by giving them the same one.
        let one = LibraryEntry(
            book: Book(title: "Emma", authors: ["Jane Austen"]), number: 7, folder: "old/one",
            formats: [])
        let two = LibraryEntry(
            book: Book(title: "Emma", authors: ["Jane Austen"]), number: 7, folder: "old/two",
            formats: [])
        let plan = OrganizePlanner.plan(
            entries: [one, two], foldsCase: true, folderExists: exists(["old/one", "old/two"]))

        #expect(plan.moves.isEmpty)
        #expect(plan.blocked.count == 2)
        #expect(plan.blocked.allSatisfy { $0.reason == .collision })
    }

    /// The Mac-only one. Two paths differing only in capitals are one folder
    /// on a folding volume and two folders on a case-sensitive one, so the
    /// same library is a collision on one disk and not on another.
    @Test("a pair differing only in capitals collides on a folding volume and not on a sensitive one")
    func caseOnlyCollision() {
        let one = LibraryEntry(
            book: Book(title: "Emma", authors: ["Jane Austen"]), number: 7, folder: "old/one",
            formats: [])
        let two = LibraryEntry(
            book: Book(title: "EMMA", authors: ["Jane Austen"]), number: 7, folder: "old/two",
            formats: [])
        let here = OrganizePlanner.plan(
            entries: [one, two], foldsCase: true, folderExists: exists(["old/one", "old/two"]))
        #expect(here.moves.isEmpty)
        #expect(here.blocked.allSatisfy { $0.reason == .caseOnlyCollision })

        let elsewhere = OrganizePlanner.plan(
            entries: [one, two], foldsCase: false, folderExists: exists(["old/one", "old/two"]))
        #expect(elsewhere.moves.count == 2)
        #expect(elsewhere.blocked.isEmpty)
    }

    /// A book whose *own* folder differs from its target only in case is not a
    /// collision at all — it is the one move that needs two renames.
    @Test("a book renaming its own folder's capitals is a move, and knows it needs two steps")
    func caseOnlyMove() {
        let book = Book(title: "Emma", authors: ["jane austen"])
        let wanted = BookFolderName.relativePath(for: book, number: 1)
        let entry = LibraryEntry(
            book: book, number: 1, folder: wanted.uppercased(), formats: [])
        let plan = OrganizePlanner.plan(
            entries: [entry], foldsCase: true, folderExists: exists([entry.folder]),
            // On a folding volume the destination "exists" — it is the source.
            folderIsEmpty: { _ in false })
        #expect(plan.moves.count == 1)
        #expect(plan.moves.first?.isCaseOnly == true)
    }

    // MARK: The other three traps

    @Test("a destination that already holds something is refused, and an empty one is not")
    func occupiedDestination() {
        let book = entry("Emma", folder: "old/emma")
        let wanted = OrganizePlanner.target(for: book)

        let occupied = OrganizePlanner.plan(
            entries: [book], foldsCase: true, folderExists: exists(["old/emma", wanted]),
            folderIsEmpty: { _ in false })
        #expect(occupied.moves.isEmpty)
        #expect(occupied.blocked.first?.reason == .destinationIsNotEmpty)

        // An empty folder left over from something is not an obstacle.
        let empty = OrganizePlanner.plan(
            entries: [book], foldsCase: true, folderExists: exists(["old/emma", wanted]),
            folderIsEmpty: { _ in true })
        #expect(empty.moves.count == 1)
    }

    @Test("a book whose folder is not there is reported, not moved")
    func sourceMissing() {
        let book = entry("Emma", folder: "old/emma")
        let plan = OrganizePlanner.plan(entries: [book], foldsCase: true, folderExists: exists([]))
        #expect(plan.moves.isEmpty)
        #expect(plan.blocked.first?.reason == .sourceMissing)
    }

    /// The 255-byte limit is *per component* and counted in bytes, not
    /// characters. `BookFolderName` already cuts to it; this checks that it
    /// really does, for a title of emoji, where one character is four bytes.
    @Test("a title far over the byte limit still produces a legal path")
    func overLongNames() {
        let long = String(repeating: "📚", count: 300)
        let book = Book(title: long, authors: [String(repeating: "ä", count: 300)])
        let path = BookFolderName.relativePath(for: book, number: 999)
        for component in path.split(separator: "/") {
            #expect(component.utf8.count <= BookFolderName.maxComponentBytes)
        }
        #expect(OrganizePlanner.overLongComponent(in: path) == nil)
        // And the check itself catches one that is over, so the guard is not
        // a line that can never fire.
        #expect(OrganizePlanner.overLongComponent(in: "a/\(String(repeating: "x", count: 256))") != nil)
    }

    // MARK: The run itself

    private func library(_ temporary: TemporaryFolder) throws -> Library {
        let library = Library(root: try temporary.folder("library"))
        try library.write(LibraryDescriptor(name: "Test"))
        return library
    }

    private func book(
        _ library: Library, title: String, at folder: String, text: String = "a synthetic book"
    ) throws -> LibraryEntry {
        let url = library.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url.appendingPathComponent("\(title).epub"))
        try Data("<opf/>".utf8).write(to: url.appendingPathComponent("metadata.opf"))
        return LibraryEntry(
            book: Book(title: title, authors: ["Jane Austen"]), number: 1, folder: folder,
            formats: [])
    }

    @Test("a folder really moves, and every byte in it is the same afterwards")
    func moveAndVerify() async throws {
        let temporary = try TemporaryFolder()
        let library = try self.library(temporary)
        let entry = try book(library, title: "Emma", at: "Wrong/Place (1)")
        let wanted = OrganizePlanner.target(for: entry)

        let plan = OrganizePlanner.plan(
            entries: [entry], foldsCase: VolumeCase.folds(at: library.root),
            folderExists: { FileManager.default.fileExists(atPath: library.root.appendingPathComponent($0).path) })
        #expect(plan.moves.count == 1)

        let outcome = try await OrganizeRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(library: library, plan: plan))

        #expect(outcome.report.failures.isEmpty)
        #expect(outcome.report.moved.count == 1)
        #expect(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(wanted).path))
        #expect(!FileManager.default.fileExists(atPath: library.root.appendingPathComponent("Wrong/Place (1)").path))
        // The book file is byte for byte what it was — moved, never rewritten.
        let moved = library.root.appendingPathComponent(wanted).appendingPathComponent("Emma.epub")
        #expect(try Data(contentsOf: moved) == Data("a synthetic book".utf8))
        // And the manifest says where it came from, with the digests read back.
        #expect(outcome.manifest.entries.first?.from == "Wrong/Place (1)")
        #expect(outcome.manifest.entries.first?.digests["Emma.epub"] != nil)
    }

    @Test("undo puts every folder back, and takes the manifest away when it is done")
    func undoPutsItBack() async throws {
        let temporary = try TemporaryFolder()
        let library = try self.library(temporary)
        let entry = try book(library, title: "Emma", at: "Wrong/Place (1)")
        let runner = OrganizeRunner(makeHasher: PortableSHA256Hasher.factory)

        let plan = OrganizePlanner.plan(
            entries: [entry], foldsCase: VolumeCase.folds(at: library.root),
            folderExists: { FileManager.default.fileExists(atPath: library.root.appendingPathComponent($0).path) })
        let done = try await runner.run(.init(library: library, plan: plan))
        #expect(done.report.moved.count == 1)

        let back = try await runner.undo(done.manifest, in: library)
        #expect(back.report.failures.isEmpty)
        #expect(back.report.isUndo)
        #expect(
            FileManager.default.fileExists(
                atPath: library.root.appendingPathComponent("Wrong/Place (1)/Emma.epub").path))
        #expect(!FileManager.default.fileExists(atPath: OrganizeManifest.url(in: library).path))
    }

    /// The resume: a manifest naming a book already moved means the second run
    /// skips it rather than failing on a source that is not there.
    @Test("a resumed organise skips what the first run already moved")
    func resume() async throws {
        let temporary = try TemporaryFolder()
        let library = try self.library(temporary)
        let entry = try book(library, title: "Emma", at: "Wrong/Place (1)")
        let runner = OrganizeRunner(makeHasher: PortableSHA256Hasher.factory)
        let plan = OrganizePlanner.plan(
            entries: [entry], foldsCase: VolumeCase.folds(at: library.root),
            folderExists: { FileManager.default.fileExists(atPath: library.root.appendingPathComponent($0).path) })

        let first = try await runner.run(.init(library: library, plan: plan))
        // The same plan again — as a resume would have it, because the plan was
        // made before the first run and nothing has recomputed it.
        let second = try await runner.run(
            .init(library: library, plan: plan, manifest: first.manifest))
        #expect(second.report.failures.isEmpty)
        #expect(second.report.moved.isEmpty)
        // And it still says where the book is now.
        #expect(second.moved.first?.folder == OrganizePlanner.target(for: entry))
    }

    /// The one move with a halfway state, and the proof that the halfway state
    /// is survivable: a folder parked between two renames is put back by the
    /// next run rather than left under a name nothing points at.
    @Test("a folder parked by a killed case-only move is recovered by the next run")
    func recoversAParkedFolder() async throws {
        let temporary = try TemporaryFolder()
        let library = try self.library(temporary)
        let runner = OrganizeRunner(makeHasher: PortableSHA256Hasher.factory)

        // Exactly what a kill between the two renames leaves: the folder in
        // the staging place, and a manifest that says so.
        let staging = OrganizeRunner.stagingPath(for: library)
        let entry = try book(library, title: "Emma", at: staging)
        var manifest = OrganizeManifest()
        manifest.inFlight = .init(
            bookID: entry.book.id, staging: staging, from: "Austen, Jane/Emma (1)",
            to: "austen, jane/Emma (1)")
        try manifest.write(in: library)

        let outcome = try await runner.run(
            .init(library: library, plan: .empty, manifest: OrganizeManifest.read(in: library)))

        #expect(outcome.report.failures.isEmpty)
        // It went to the destination, which was free.
        #expect(
            FileManager.default.fileExists(
                atPath: library.root.appendingPathComponent("austen, jane/Emma (1)/Emma.epub").path))
        #expect(!FileManager.default.fileExists(atPath: library.root.appendingPathComponent(staging).path))
        #expect(OrganizeManifest.read(in: library).inFlight == nil)
    }

    // MARK: The one folder an organise makes go away

    /// Which names are the file system talking to itself. An allow-list, and
    /// never "anything beginning with a dot": a dot file is how a great many
    /// programs keep something that matters.
    @Test("system residue is recognised by name, and a hidden file somebody made is not")
    func systemResidue() {
        for name in [".DS_Store", ".localized", ".fseventsd", ".Spotlight-V100", "Thumbs.db"] {
            #expect(EmptiedFolder.isSystemResidue(name))
        }
        // Spotlight's carry a volume UUID, so they are matched by prefix.
        #expect(EmptiedFolder.isSystemResidue(".Spotlight-V100-Store-V2"))
        #expect(EmptiedFolder.isSystemResidue("._Emma.epub"))

        // Somebody's own hidden files, which must keep a folder alive.
        for name in [".gitignore", ".calibre", ".notes.txt", ".shelf", "cover.jpg", "Emma.epub"] {
            #expect(!EmptiedFolder.isSystemResidue(name), "\(name) is not system residue")
        }

        #expect(EmptiedFolder.holdsNothingButResidue([]))
        #expect(EmptiedFolder.holdsNothingButResidue([".DS_Store", ".localized"]))
        #expect(!EmptiedFolder.holdsNothingButResidue([".DS_Store", "Emma.epub"]))
        #expect(!EmptiedFolder.holdsNothingButResidue([".gitignore"]))
    }

    /// Which paths may be considered at all: the parent of a moved folder,
    /// one level below the root, never `.shelf`.
    @Test("only the author folder a move came out of is ever a candidate")
    func onlyTheAuthorFolder() {
        #expect(EmptiedFolder.candidate(parentOf: "Atwood, Adrian/Emma (1)") == "Atwood, Adrian")
        // Not the root itself, and not something deeper than an author folder.
        #expect(EmptiedFolder.candidate(parentOf: "Emma (1)") == nil)
        #expect(EmptiedFolder.candidate(parentOf: "a/b/Emma (1)") == nil)
        // Never Shelf's own folder.
        #expect(EmptiedFolder.candidate(parentOf: "\(Library.privateFolderName)/moving/x") == nil)
    }

    /// **It goes to the Trash, and there is no other way out.** The runner is
    /// handed a disposal that moves nothing and counts instead: afterwards the
    /// folder is still on the disk, which is what says the runner has no
    /// `removeItem` of its own behind the seam.
    @Test("an emptied author folder is handed to the disposal, never removed directly")
    func emptiedFolderGoesThroughTheSeam() async throws {
        let temporary = try TemporaryFolder()
        let library = try self.library(temporary)
        let mover = try book(library, title: "Emma", at: "Wrong/Emma (1)")
        // The Finder has been in here. That used to keep the folder for ever.
        try Data("finder".utf8).write(to: library.root.appendingPathComponent("Wrong/.DS_Store"))

        let asked = Recorder()
        let spy = FolderDisposal { url in
            asked.record(url.lastPathComponent)
            return nil
        }
        let plan = OrganizePlanner.plan(
            entries: [mover], foldsCase: VolumeCase.folds(at: library.root),
            folderExists: { OrganizeBookProbe.exists($0, under: library.root) })
        let outcome = try await OrganizeRunner(
            makeHasher: PortableSHA256Hasher.factory, disposal: spy
        ).run(.init(library: library, plan: plan))

        #expect(outcome.report.failures.isEmpty)
        #expect(asked.names == ["Wrong"])
        #expect(outcome.report.emptiedFolders == ["Wrong"])
        // The spy moved nothing, so the folder is still there. If the runner
        // had a removeItem of its own, this would be gone.
        #expect(FileManager.default.fileExists(atPath: library.root.appendingPathComponent("Wrong").path))
        #expect(outcome.report.rendered().contains("in the Trash"))
    }

    /// A folder that still holds something somebody made is not offered to the
    /// disposal at all — not even to be refused.
    @Test("a folder holding anything of somebody's own is never offered for disposal")
    func aFolderWithContentsIsNotOffered() async throws {
        let temporary = try TemporaryFolder()
        let library = try self.library(temporary)
        let mover = try book(library, title: "Emma", at: "Keep/Emma (1)")
        try Data("mine".utf8).write(to: library.root.appendingPathComponent("Keep/.gitignore"))

        let asked = Recorder()
        let spy = FolderDisposal { url in
            asked.record(url.lastPathComponent)
            return nil
        }
        let plan = OrganizePlanner.plan(
            entries: [mover], foldsCase: VolumeCase.folds(at: library.root),
            folderExists: { OrganizeBookProbe.exists($0, under: library.root) })
        let outcome = try await OrganizeRunner(
            makeHasher: PortableSHA256Hasher.factory, disposal: spy
        ).run(.init(library: library, plan: plan))

        #expect(asked.names.isEmpty)
        #expect(outcome.report.emptiedFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: library.root.appendingPathComponent("Keep/.gitignore").path))
    }

    /// A disposal that fails leaves the folder where it is *and* keeps it out
    /// of the report — a folder reported as gone that is still there is worse
    /// than one that was never touched.
    @Test("a disposal that fails is not reported as a folder that went")
    func aFailedDisposalIsNotReported() async throws {
        let temporary = try TemporaryFolder()
        let library = try self.library(temporary)
        let mover = try book(library, title: "Emma", at: "Wrong/Emma (1)")

        let plan = OrganizePlanner.plan(
            entries: [mover], foldsCase: VolumeCase.folds(at: library.root),
            folderExists: { OrganizeBookProbe.exists($0, under: library.root) })
        let outcome = try await OrganizeRunner(
            makeHasher: PortableSHA256Hasher.factory, disposal: .none
        ).run(.init(library: library, plan: plan))

        #expect(outcome.report.moved.count == 1)
        #expect(outcome.report.emptiedFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: library.root.appendingPathComponent("Wrong").path))
    }

    /// What the disposal seam was asked to dispose of.
    ///
    /// A little class with a lock rather than a captured `var`: the closure is
    /// `@Sendable`, so nothing else would compile, and a test that proves
    /// *which* folders were offered has to hold the list somewhere.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        func record(_ name: String) {
            lock.lock()
            defer { lock.unlock() }
            seen.append(name)
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    /// `VolumeCase` measures rather than assumes, and the test says what this
    /// machine answered rather than asserting a value that would be wrong on
    /// somebody else's disk.
    @Test("whether the volume folds case is measured, and the answer is self-consistent")
    func caseIsMeasured() throws {
        let temporary = try TemporaryFolder()
        let folds = VolumeCase.folds(at: temporary.url)
        try temporary.write("Fitzek/x.txt", text: "x")
        #expect(temporary.exists("fitzek/x.txt") == folds)
        #expect(VolumeCase.same("A/B", "a/b", folding: folds) == folds)
        #expect(VolumeCase.same("A/B", "A/B", folding: folds))
        #expect(VolumeCase.isCaseOnly(from: "A", to: "a", folding: folds) == folds)
        #expect(!VolumeCase.isCaseOnly(from: "A", to: "B", folding: folds))
    }
}
