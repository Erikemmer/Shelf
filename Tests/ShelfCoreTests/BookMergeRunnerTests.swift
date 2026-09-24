import Foundation
import Testing

@testable import ShelfCore

/// Carrying out a merge for real: files actually moved and hashed, an
/// absorbed folder actually trashed and actually restorable, a run resumed
/// after only part of it happened, and the whole thing undone.
@Suite("Running and undoing a book merge")
struct BookMergeRunnerTests {

    private func hasher() -> HasherFactory { PortableSHA256Hasher.factory }

    /// The same test double `FormatDisposalTests`/`BookDisposalTests` use: a
    /// disposal that really moves the item, so a test can ask both "is it
    /// gone" and "can it still be got back".
    private final class Bin: @unchecked Sendable {
        let folder: URL
        init(in parent: URL) throws {
            folder = parent.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var disposal: FolderDisposal {
            FolderDisposal { [self] url in
                let target = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }

        func folderExists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
    }

    /// A two-book group on real disk: the survivor has an EPUB, the absorbed
    /// book has a MOBI of the same work — the exact shape every real group
    /// in Sprint 18's own library turned out to have.
    private func twoBookGroup(in folder: TemporaryFolder) throws -> (Library, LibraryEntry, LibraryEntry) {
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let epubData = Data("epub bytes".utf8)
        let mobiData = Data("mobi bytes".utf8)
        try folder.write("Lib/A/Schattenpfad (1)/Schattenpfad - A.epub", data: epubData)
        try folder.write("Lib/A/Schattenpfad (2)/Schattenpfad - A.mobi", data: mobiData)

        let survivorBook = Book(title: "Schattenpfad", authors: ["A"])
        let survivor = LibraryEntry(
            book: survivorBook, number: 1, folder: "A/Schattenpfad (1)",
            formats: [
                BookFormat(
                    bookID: survivorBook.id, format: .epub, fileName: "Schattenpfad - A.epub",
                    byteSize: Int64(epubData.count),
                    sha256: try FileDigest.sha256(
                        of: library.root.appendingPathComponent("A/Schattenpfad (1)/Schattenpfad - A.epub"),
                        makeHasher: hasher()))
            ])
        let absorbedBook = Book(title: "Schattenpfad", authors: ["A"])
        let absorbed = LibraryEntry(
            book: absorbedBook, number: 2, folder: "A/Schattenpfad (2)",
            formats: [
                BookFormat(
                    bookID: absorbedBook.id, format: .mobi, fileName: "Schattenpfad - A.mobi",
                    byteSize: Int64(mobiData.count),
                    sha256: try FileDigest.sha256(
                        of: library.root.appendingPathComponent("A/Schattenpfad (2)/Schattenpfad - A.mobi"),
                        makeHasher: hasher()))
            ])
        return (library, survivor, absorbed)
    }

    private func plan(survivor: LibraryEntry, absorbed: LibraryEntry) -> BookMergePlan {
        BookMergePlan(groups: [
            BookMergeGroupPlan(
                survivingID: survivor.id, survivingTitle: survivor.book.title, absorbedIDs: [absorbed.id],
                moves: absorbed.formats.map { BookMergeMove(sourceBookID: absorbed.id, format: $0) },
                discards: [], fills: [], conflicts: [], coverFromBookID: nil)
        ])
    }

    // MARK: run

    @Test("a merge moves the absorbed file in, verified by hash, and trashes the emptied folder")
    func runsAMerge() async throws {
        let folder = try TemporaryFolder()
        let (library, survivor, absorbed) = try twoBookGroup(in: folder)
        let bin = try Bin(in: folder.url)
        let runner = BookMergeRunner(makeHasher: hasher(), disposal: bin.disposal)
        let options = BookMergeRunner.Options(
            library: library, plan: plan(survivor: survivor, absorbed: absorbed),
            entries: [survivor.id: survivor, absorbed.id: absorbed])

        let outcome = try await runner.run(options)

        let survivorFolder = library.root.appendingPathComponent("A/Schattenpfad (1)")
        #expect(
            FileManager.default.fileExists(atPath: survivorFolder.appendingPathComponent("Schattenpfad - A.mobi").path))
        #expect(!FileManager.default.fileExists(atPath: library.root.appendingPathComponent("A/Schattenpfad (2)").path))
        #expect(bin.folderExists("Schattenpfad (2)"))

        #expect(outcome.groups.count == 1)
        #expect(Set(outcome.groups[0].newFormats.map(\.format)) == [.epub, .mobi])
        #expect(outcome.groups[0].absorbedIDs == [absorbed.id])
        #expect(!outcome.manifest.isEmpty)
    }

    /// **The defect this test exists for.** Found live against the real
    /// library: two different EPUBs of the same book competing, and the
    /// *survivor's own* copy loses `FormatPreference`'s tie-break to the
    /// absorbed book's. The file was correctly gone from disk either way —
    /// the index still claimed it existed, because the survivor's own
    /// pre-existing formats were never filtered against what this same
    /// group had just discarded.
    @Test("a survivor's own file, discarded by a tie-break, is gone from the new format list too")
    func discardedSurvivorFormatIsRemoved() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        try folder.write("Lib/A/Book (1)/survivor.epub", data: Data("weaker copy".utf8))
        try folder.write("Lib/A/Book (2)/winner.epub", data: Data("stronger copy, no DRM".utf8))

        let survivorBook = Book(title: "Book", authors: ["A"])
        let survivorFormat = BookFormat(
            bookID: survivorBook.id, format: .epub, fileName: "survivor.epub", byteSize: 11,
            sha256: try FileDigest.sha256(
                of: library.root.appendingPathComponent("A/Book (1)/survivor.epub"), makeHasher: hasher()),
            drm: .adobeADEPT)
        let survivor = LibraryEntry(book: survivorBook, number: 1, folder: "A/Book (1)", formats: [survivorFormat])

        let absorbedBook = Book(title: "Book", authors: ["A"])
        let winnerFormat = BookFormat(
            bookID: absorbedBook.id, format: .epub, fileName: "winner.epub", byteSize: 21,
            sha256: try FileDigest.sha256(
                of: library.root.appendingPathComponent("A/Book (2)/winner.epub"), makeHasher: hasher()))
        let absorbed = LibraryEntry(book: absorbedBook, number: 2, folder: "A/Book (2)", formats: [winnerFormat])

        let bin = try Bin(in: folder.url)
        let runner = BookMergeRunner(makeHasher: hasher(), disposal: bin.disposal)
        let groupPlan = BookMergeGroupPlan(
            survivingID: survivor.id, survivingTitle: "Book", absorbedIDs: [absorbed.id],
            moves: [BookMergeMove(sourceBookID: absorbed.id, format: winnerFormat)],
            discards: [
                BookMergeDiscard(sourceBookID: survivor.id, format: survivorFormat, reason: .losingTiebreak)
            ], fills: [], conflicts: [], coverFromBookID: nil)
        let options = BookMergeRunner.Options(
            library: library, plan: BookMergePlan(groups: [groupPlan]),
            entries: [survivor.id: survivor, absorbed.id: absorbed])

        let outcome = try await runner.run(options)

        let newFormats = outcome.groups[0].newFormats
        #expect(newFormats.map(\.fileName) == ["winner.epub"])
        #expect(!newFormats.contains { $0.fileName == "survivor.epub" })
    }

    @Test("resuming with a manifest from a partial run does not redo the group that already happened")
    func resumesWithoutRedoing() async throws {
        let folder = try TemporaryFolder()
        let (library, survivorOne, absorbedOne) = try twoBookGroup(in: folder)
        // A second, independent group, so the plan really has two groups.
        try folder.write("Lib/B/Sternfall (3)/Sternfall - B.epub", data: Data("epub two".utf8))
        try folder.write("Lib/B/Sternfall (4)/Sternfall - B.mobi", data: Data("mobi two".utf8))
        let survivorTwoBook = Book(title: "Sternfall", authors: ["B"])
        let survivorTwo = LibraryEntry(
            book: survivorTwoBook, number: 3, folder: "B/Sternfall (3)",
            formats: [
                BookFormat(
                    bookID: survivorTwoBook.id, format: .epub, fileName: "Sternfall - B.epub", byteSize: 8,
                    sha256: try FileDigest.sha256(
                        of: library.root.appendingPathComponent("B/Sternfall (3)/Sternfall - B.epub"),
                        makeHasher: hasher()))
            ])
        let absorbedTwoBook = Book(title: "Sternfall", authors: ["B"])
        let absorbedTwo = LibraryEntry(
            book: absorbedTwoBook, number: 4, folder: "B/Sternfall (4)",
            formats: [
                BookFormat(
                    bookID: absorbedTwoBook.id, format: .mobi, fileName: "Sternfall - B.mobi", byteSize: 8,
                    sha256: try FileDigest.sha256(
                        of: library.root.appendingPathComponent("B/Sternfall (4)/Sternfall - B.mobi"),
                        makeHasher: hasher()))
            ])

        let bin = try Bin(in: folder.url)
        let runner = BookMergeRunner(makeHasher: hasher(), disposal: bin.disposal)
        let entries: [UUID: LibraryEntry] = [
            survivorOne.id: survivorOne, absorbedOne.id: absorbedOne, survivorTwo.id: survivorTwo,
            absorbedTwo.id: absorbedTwo,
        ]

        // "Crashed" after only the first group: run with a plan of one group only.
        let firstPlan = plan(survivor: survivorOne, absorbed: absorbedOne)
        let firstOutcome = try await runner.run(
            BookMergeRunner.Options(library: library, plan: firstPlan, entries: entries))
        #expect(firstOutcome.groups.count == 1)

        // Resume: the FULL plan, with the manifest the partial run left.
        let fullPlan = BookMergePlan(
            groups: firstPlan.groups + plan(survivor: survivorTwo, absorbed: absorbedTwo).groups)
        let resumed = try await runner.run(
            BookMergeRunner.Options(
                library: library, plan: fullPlan, entries: entries, manifest: firstOutcome.manifest))

        #expect(resumed.groups.count == 2)
        // Group one's manifest entry is untouched by the second call — the
        // proof that it was recognised as done rather than attempted again
        // (attempting it again would have thrown: the file is no longer
        // where the plan says it was).
        #expect(resumed.manifest.entry(for: survivorOne.id) == firstOutcome.manifest.entry(for: survivorOne.id))
        #expect(
            FileManager.default.fileExists(
                atPath: library.root.appendingPathComponent("B/Sternfall (3)/Sternfall - B.mobi").path))
    }

    // MARK: undo

    @Test("undoing a merge puts every file and folder back, verified by hash")
    func undoesAMerge() async throws {
        let folder = try TemporaryFolder()
        let (library, survivor, absorbed) = try twoBookGroup(in: folder)
        let bin = try Bin(in: folder.url)
        let runner = BookMergeRunner(makeHasher: hasher(), disposal: bin.disposal)
        let options = BookMergeRunner.Options(
            library: library, plan: plan(survivor: survivor, absorbed: absorbed),
            entries: [survivor.id: survivor, absorbed.id: absorbed])
        let outcome = try await runner.run(options)

        let undone = try await runner.undo(outcome.manifest, in: library)

        let survivorFolder = library.root.appendingPathComponent("A/Schattenpfad (1)")
        let absorbedFolder = library.root.appendingPathComponent("A/Schattenpfad (2)")
        #expect(
            !FileManager.default.fileExists(atPath: survivorFolder.appendingPathComponent("Schattenpfad - A.mobi").path)
        )
        #expect(
            FileManager.default.fileExists(atPath: survivorFolder.appendingPathComponent("Schattenpfad - A.epub").path))
        #expect(
            FileManager.default.fileExists(atPath: absorbedFolder.appendingPathComponent("Schattenpfad - A.mobi").path))
        #expect(undone.manifest.isEmpty)
        #expect(undone.undone.count == 1)
        #expect(undone.undone[0].restoredEntries.map(\.id) == [absorbed.id])

        let restoredDigest = try FileDigest.sha256(
            of: absorbedFolder.appendingPathComponent("Schattenpfad - A.mobi"), makeHasher: hasher())
        #expect(restoredDigest == absorbed.formats[0].sha256)
    }

    @Test("a discarded duplicate is restored too, verified by hash, not just moved-in files")
    func undoesADiscardedDuplicate() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let sharedData = Data("identical bytes".utf8)
        try folder.write("Lib/A/Book (1)/Book - A.epub", data: sharedData)
        try folder.write("Lib/A/Book (2)/Book - A (copy).epub", data: sharedData)
        let digest = try FileDigest.sha256(
            of: library.root.appendingPathComponent("A/Book (1)/Book - A.epub"), makeHasher: hasher())

        let survivorBook = Book(title: "Book", authors: ["A"])
        let survivor = LibraryEntry(
            book: survivorBook, number: 1, folder: "A/Book (1)",
            formats: [
                BookFormat(
                    bookID: survivorBook.id, format: .epub, fileName: "Book - A.epub",
                    byteSize: Int64(sharedData.count),
                    sha256: digest)
            ])
        let absorbedBook = Book(title: "Book", authors: ["A"])
        let discardedFormat = BookFormat(
            bookID: absorbedBook.id, format: .epub, fileName: "Book - A (copy).epub",
            byteSize: Int64(sharedData.count), sha256: digest)
        let absorbed = LibraryEntry(book: absorbedBook, number: 2, folder: "A/Book (2)", formats: [discardedFormat])

        let bin = try Bin(in: folder.url)
        let runner = BookMergeRunner(makeHasher: hasher(), disposal: bin.disposal)
        let groupPlan = BookMergeGroupPlan(
            survivingID: survivor.id, survivingTitle: "Book", absorbedIDs: [absorbed.id], moves: [],
            discards: [
                BookMergeDiscard(sourceBookID: absorbed.id, format: discardedFormat, reason: .byteIdenticalDuplicate)
            ],
            fills: [], conflicts: [], coverFromBookID: nil)
        let options = BookMergeRunner.Options(
            library: library, plan: BookMergePlan(groups: [groupPlan]),
            entries: [survivor.id: survivor, absorbed.id: absorbed])

        let outcome = try await runner.run(options)
        #expect(!FileManager.default.fileExists(atPath: library.root.appendingPathComponent("A/Book (2)").path))

        let undone = try await runner.undo(outcome.manifest, in: library)
        let restored = library.root.appendingPathComponent("A/Book (2)/Book - A (copy).epub")
        #expect(FileManager.default.fileExists(atPath: restored.path))
        let restoredDigest = try FileDigest.sha256(of: restored, makeHasher: hasher())
        #expect(restoredDigest == digest)
        #expect(undone.manifest.isEmpty)
    }
}
