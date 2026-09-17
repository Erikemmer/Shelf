import Foundation
import Testing

@testable import ShelfCore

/// What an interrupted import leaves on the disk, and what the next run does
/// with it.
///
/// The defect these tests pin down was measured: a killed import of a Calibre
/// library left 23 book folders on disk that the index had never been told
/// about, and the next run — finding nothing in the index — planned those books
/// again and copied them into *second* folders. Nothing was lost and nothing
/// was overwritten, which is exactly why it went unnoticed; the library simply
/// grew a pile nobody could see. A library must not accumulate that.
@Suite("Folders no book points at")
struct OrphanedFoldersTests {

    private func hasher() -> HasherFactory { PortableSHA256Hasher.factory }

    /// Builds candidates from synthetic EPUBs, the way every other import test
    /// does — the books these tests read are made in the test.
    private func candidates(_ folder: TemporaryFolder, books: [Book]) throws -> [ImportCandidate] {
        try books.enumerated().map { index, book in
            let cover = MinimalPNG.cover(width: 10, height: 15, seed: UInt8(index % 200))
            let epub = SyntheticEPUB(book: book, cover: cover).data()
            let url = try folder.write("source/\(index).epub", data: epub)
            let read = try EPUBMetadata.read(url: url)
            return ImportCandidate(
                source: url, byteSize: Int64(epub.count), format: .epub,
                sha256: try FileDigest.sha256(of: url, makeHasher: hasher()),
                book: read.book, cover: read.cover, coverName: read.coverName)
        }
    }

    private func books(_ count: Int) -> [Book] {
        (0..<count).map { Book(title: "Book \($0)", authors: ["Author \($0 % 3)"]) }
    }

    // MARK: Finding them

    @Test("a folder the index does not know is found, with every file in it named")
    func findsOne() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let plan = ImportPlanner.plan(candidates: try candidates(temporary, books: books(3)))
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: plan, sourceDescription: "test"))
        #expect(outcome.entries.count == 3)

        // The index knows two of the three: the third is what a killed run
        // looks like from the outside.
        let known = Set(outcome.entries.dropLast().map(\.folder))
        let orphans = OrphanedFolders.find(in: library, knownFolders: known)

        #expect(orphans.count == 1)
        let orphan = try #require(orphans.first)
        #expect(orphan.path == outcome.entries.last?.folder)
        #expect(orphan.bookID == outcome.entries.last?.id)
        #expect(orphan.holdsABook)
        #expect(orphan.byteSize > 0)
        // The book file, its cover and its OPF – the dialog names all three.
        #expect(orphan.files.contains(where: { $0.hasSuffix(".epub") }))
        #expect(orphan.files.contains(OPFDocument.fileName))
        #expect(orphan.files.count == 3)
    }

    @Test("a library whose index knows every folder has no orphans")
    func findsNoneWhenAllKnown() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let plan = ImportPlanner.plan(candidates: try candidates(temporary, books: books(4)))
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: plan, sourceDescription: "test"))

        #expect(OrphanedFolders.find(in: library, knownFolders: Set(outcome.entries.map(\.folder))).isEmpty)
    }

    /// The index stores the folder it wrote; a case-insensitive file system may
    /// hand the same folder back spelled differently. Calling that an orphan
    /// would offer to trash a book that is perfectly well filed.
    @Test("a folder that differs from the index only in case is not an orphan")
    func caseDoesNotMakeAnOrphan() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let plan = ImportPlanner.plan(candidates: try candidates(temporary, books: books(2)))
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: plan, sourceDescription: "test"))

        let shouted = Set(outcome.entries.map { $0.folder.uppercased() })
        #expect(OrphanedFolders.find(in: library, knownFolders: shouted).isEmpty)
    }

    @Test("the library's own .shelf folder is never an orphan")
    func privateFolderIsNotAnOrphan() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let orphans = OrphanedFolders.find(in: library, knownFolders: [])
        #expect(orphans.allSatisfy { !$0.path.hasPrefix(Library.privateFolderName) })
    }

    @Test("a folder whose OPF is gone is still reported, just without a book to blame")
    func folderWithoutOPF() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let plan = ImportPlanner.plan(candidates: try candidates(temporary, books: books(1)))
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: plan, sourceDescription: "test"))
        let folder = try #require(outcome.entries.first?.folder)
        try FileManager.default.removeItem(
            at: library.root.appendingPathComponent(folder).appendingPathComponent(OPFDocument.fileName))

        let orphan = try #require(OrphanedFolders.find(in: library, knownFolders: []).first)
        #expect(orphan.bookID == nil)
        #expect(orphan.holdsABook)
        // Unclaimable: without the UUID there is nothing to match it against,
        // and guessing from the title is how one book's files end up in
        // another book's folder.
        #expect(OrphanedFolders.claimable([orphan], importing: Set(outcome.entries.map(\.id))).isEmpty)
    }

    // MARK: The resume

    /// The whole point. A run is killed after writing folders the index never
    /// heard of; the next run over the same source must end with one folder per
    /// book, not two.
    @Test("a resumed import re-uses the folders the killed run left, instead of making second ones")
    func resumeReusesInsteadOfDuplicating() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let all = try candidates(temporary, books: books(6))

        // Run one, killed: it wrote all six folders and the index was told
        // about only the first two.
        let first = ImportPlanner.plan(candidates: all)
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: first, sourceDescription: "run 1"))
        let saved = Array(outcome.entries.prefix(2))
        #expect(folderCount(in: library) == 6)

        // Run two over the same source. Its knowledge is what the index holds –
        // two books – plus what adoption takes back.
        let orphans = OrphanedFolders.find(in: library, knownFolders: Set(saved.map(\.folder)))
        #expect(orphans.count == 4)

        let claimed = OrphanedFolders.claimable(orphans, importing: Set(all.map(\.book.id)))
        #expect(claimed.count == 4)
        let adopted = OrphanedFolders.adopt(claimed, in: library, makeHasher: hasher())
        #expect(adopted.count == 4)

        let entries = saved + adopted
        let second = ImportPlanner.plan(
            candidates: all,
            knowledge: knowledge(from: entries),
            startingNumber: (entries.map(\.number).max() ?? 0) + 1,
            existingFolders: Set(entries.map(\.folder)))

        // Nothing left to do: every one of the six is already on disk.
        #expect(second.operations.isEmpty)
        #expect(second.skipped.count == 6)

        _ = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: second, sourceDescription: "run 2"))

        // Six books, six folders. Before the fix this was twelve.
        #expect(folderCount(in: library) == 6)
        #expect(OrphanedFolders.find(in: library, knownFolders: Set(entries.map(\.folder))).isEmpty)
        #expect(Set(entries.map(\.id)) == Set(all.map(\.book.id)))
    }

    /// Without adoption the same run makes a second folder for every book the
    /// index lost — the behaviour this whole file exists to stop. Kept as a
    /// test so the defect cannot come back quietly.
    @Test("without adoption the same resume doubles the folders – the defect, pinned")
    func withoutAdoptionItDuplicates() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let all = try candidates(temporary, books: books(6))

        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: ImportPlanner.plan(candidates: all), sourceDescription: "run 1"))
        let saved = Array(outcome.entries.prefix(2))

        // `existingFolders` comes off the disk, exactly as `ImportModel` reads
        // it — which is what makes the second run give the four books folders
        // of their own rather than colliding with the ones already there.
        let second = ImportPlanner.plan(
            candidates: all,
            knowledge: knowledge(from: saved),
            startingNumber: (saved.map(\.number).max() ?? 0) + 1,
            existingFolders: foldersOnDisk(in: library))
        #expect(second.operations.count == 4)

        let outcome2 = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: second, sourceDescription: "run 2"))
        #expect(outcome2.report.failures.isEmpty)
        #expect(folderCount(in: library) == 10)
    }

    @Test("adoption copies nothing and writes nothing into the folder")
    func adoptionTouchesNothing() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let all = try candidates(temporary, books: books(2))
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: ImportPlanner.plan(candidates: all), sourceDescription: "run 1"))

        let folder = try #require(outcome.entries.first?.folder)
        let url = library.root.appendingPathComponent(folder)
        let before = try snapshot(of: url)

        let orphans = OrphanedFolders.find(in: library, knownFolders: [])
        _ = OrphanedFolders.adopt(orphans, in: library, makeHasher: hasher())

        #expect(try snapshot(of: url) == before)
    }

    /// The adopted entry has to be the entry a rebuild would make of the same
    /// folder, or the index and a later `Rebuild Index from Folders` would
    /// disagree about a book that never moved.
    @Test("an adopted folder gives the same entry a rebuild would")
    func adoptionMatchesTheRebuilder() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let all = try candidates(temporary, books: books(3))
        _ = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: ImportPlanner.plan(candidates: all), sourceDescription: "run"))

        let adopted = OrphanedFolders.adopt(
            OrphanedFolders.find(in: library, knownFolders: []), in: library, makeHasher: hasher())
        let rebuilt = try IndexRebuilder(makeHasher: hasher()).rebuild(library).entries

        #expect(adopted.count == rebuilt.count)
        for entry in adopted {
            let other = try #require(rebuilt.first { $0.id == entry.id })
            #expect(entry.folder == other.folder)
            #expect(entry.number == other.number)
            #expect(entry.formats.map(\.sha256) == other.formats.map(\.sha256))
            #expect(entry.book.title == other.book.title)
        }
    }

    // MARK: The report

    @Test("the report counts the orphans, names them, and says nothing was removed")
    func reportNamesThem() {
        let report = ImportReport(
            libraryName: "Lib", sourceDescription: "test", newBooks: 2,
            copiedByFormat: [.epub: 2], copiedBytes: 100,
            reclaimedFolders: ["Author 0/Book 0 (1)"],
            orphanedFolders: ["Author 1/Book 9 (12)", "Author 2/Book 4 (7)"])

        #expect(report.headline.contains("2 orphaned folders"))
        let text = report.rendered()
        #expect(text.contains("Author 1/Book 9 (12)"))
        #expect(text.contains("Author 2/Book 4 (7)"))
        #expect(text.contains("Nothing was removed"))
        #expect(text.contains("Taken back from an interrupted run: 1 folder"))
        #expect(text.contains("Author 0/Book 0 (1)"))
    }

    @Test("an import with nothing left over says nothing about orphans at all")
    func reportStaysQuietWhenThereAreNone() {
        let report = ImportReport(
            libraryName: "Lib", sourceDescription: "test", newBooks: 1, copiedByFormat: [.epub: 1])
        #expect(!report.headline.contains("orphan"))
        #expect(!report.rendered().contains("orphan"))
    }

    // MARK: Helpers

    private func knowledge(from entries: [LibraryEntry]) -> ImportKnowledge {
        var digests: [String: UUID] = [:]
        var isbns: [String: UUID] = [:]
        var titleKeys: [String: [UUID]] = [:]
        var formats: [UUID: Set<BookFileFormat>] = [:]
        var folders: [UUID: String] = [:]
        for entry in entries {
            for format in entry.formats {
                digests[format.sha256] = entry.id
                formats[entry.id, default: []].insert(format.format)
            }
            if let isbn = entry.book.isbn { isbns[isbn] = entry.id }
            titleKeys[DuplicateKey.titleAuthor(for: entry.book), default: []].append(entry.id)
            folders[entry.id] = entry.folder
        }
        return ImportKnowledge(
            digests: digests, isbns: isbns, titleKeys: titleKeys,
            formatsByBook: formats, foldersByBook: folders)
    }

    /// Every book folder that is there, the way `ImportModel` lists them for
    /// the planner.
    private func foldersOnDisk(in library: Library) -> Set<String> {
        let manager = FileManager.default
        var result: Set<String> = []
        let authors =
            ((try? manager.contentsOfDirectory(
                at: library.root, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [])
            .filter { $0.hasDirectoryPath && $0.lastPathComponent != Library.privateFolderName }
        for author in authors {
            let books =
                ((try? manager.contentsOfDirectory(
                    at: author, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [])
                .filter(\.hasDirectoryPath)
            for book in books { result.insert("\(author.lastPathComponent)/\(book.lastPathComponent)") }
        }
        return result
    }

    /// Book folders two levels down, the layout's own depth.
    private func folderCount(in library: Library) -> Int {
        let manager = FileManager.default
        let authors =
            ((try? manager.contentsOfDirectory(
                at: library.root, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [])
            .filter { $0.hasDirectoryPath && $0.lastPathComponent != Library.privateFolderName }
        return authors.reduce(0) { total, author in
            total
                + (((try? manager.contentsOfDirectory(
                    at: author, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [])
                    .filter(\.hasDirectoryPath).count)
        }
    }

    /// Name, size and modification date of everything in a folder – enough to
    /// notice a write that should not have happened.
    private func snapshot(of folder: URL) throws -> [String] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: folder.path).sorted()
        return try names.map { name in
            let attributes = try manager.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            let size = (attributes[.size] as? Int64) ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(name)|\(size)|\(modified)"
        }
    }
}
