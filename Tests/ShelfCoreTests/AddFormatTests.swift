import Foundation
import Testing

@testable import ShelfCore

/// Adding a second file to a book that is **already in the library**.
///
/// This is the case `Add Format…` performs, and the case a second import over
/// the same folder performs, and it is different from adding a format to a book
/// the same run just created: the runner has that one in hand, and this one it
/// does not.
///
/// The defect these tests pin down was found by looking at a screenshot. A book
/// whose folder held an EPUB, an AZW3, a MOBI and a PDF showed three formats in
/// the inspector. Nothing was lost on disk and a rebuild put it right, but
/// between the import and the next rebuild the index was simply wrong about
/// what the library held.
@Suite("Adding a format to a book the library already has")
struct AddFormatTests {

    private func hasher() -> HasherFactory { PortableSHA256Hasher.factory }

    private func candidate(
        _ folder: TemporaryFolder, _ name: String, _ format: BookFileFormat, _ book: Book
    ) throws -> ImportCandidate {
        let data: Data
        switch format {
        case .epub: data = SyntheticEPUB(book: book, cover: MinimalPNG.cover(width: 8, height: 12, seed: 1)).data()
        case .mobi, .azw3: data = SyntheticMobi(book: book, isAZW3: format == .azw3).data()
        default: data = SyntheticPDF(book: book).data()
        }
        let url = try folder.write("source/\(name)", data: data)
        let read = BookFileReader.read(url: url, format: format)
        return ImportCandidate(
            source: url, byteSize: Int64(data.count), format: format,
            sha256: try FileDigest.sha256(of: url, makeHasher: hasher()),
            book: read.book, cover: read.cover, coverName: read.coverName, drm: read.drm)
    }

    /// The knowledge an importer builds from the index before planning.
    private func knowledge(from entries: [LibraryEntry]) -> ImportKnowledge {
        var digests: [String: UUID] = [:]
        var titleKeys: [String: [UUID]] = [:]
        var formats: [UUID: Set<BookFileFormat>] = [:]
        var folders: [UUID: String] = [:]
        for entry in entries {
            for format in entry.formats {
                digests[format.sha256] = entry.id
                formats[entry.id, default: []].insert(format.format)
            }
            titleKeys[DuplicateKey.titleAuthor(for: entry.book), default: []].append(entry.id)
            folders[entry.id] = entry.folder
        }
        return ImportKnowledge(
            digests: digests, titleKeys: titleKeys, formatsByBook: formats, foldersByBook: folders)
    }

    /// **The defect.** Import an EPUB, then import its AZW3 and MOBI in a
    /// second run, the way a person adding formats to an existing library does.
    @Test("a second run keeps the formats the first run put there")
    func keepsTheEarlierFormats() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let book = Book(title: "A Desolation", authors: ["Becky Lefevre"])

        // Run one: the EPUB alone.
        let first = ImportPlanner.plan(candidates: [try candidate(temporary, "a.epub", .epub, book)])
        let firstRun = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: first, sourceDescription: "run 1"))
        let existing = firstRun.entries
        #expect(existing.count == 1)
        #expect(existing[0].formats.map(\.format) == [.epub])

        // Run two: the same book's AZW3 and MOBI, planned against what run one
        // left behind.
        let second = ImportPlanner.plan(
            candidates: [
                try candidate(temporary, "a.azw3", .azw3, book),
                try candidate(temporary, "a.mobi", .mobi, book),
            ],
            knowledge: knowledge(from: existing),
            startingNumber: (existing.map(\.number).max() ?? 0) + 1)

        // Both are additions to the book that is there, not new books.
        #expect(second.newBookCount == 0)
        #expect(second.addedFormatCount == 2)

        let secondRun = try await ImportRunner(makeHasher: hasher())
            .run(
                .init(library: library, plan: second, sourceDescription: "run 2"),
                existingEntry: { id in existing.first { $0.id == id } })

        let entry = try #require(secondRun.entries.first)
        #expect(
            entry.formats.map(\.format).sorted() == [.epub, .azw3, .mobi].sorted(),
            "the entry handed to the index lists \(entry.formats.map(\.format.label)) — the EPUB is gone")
        // And the things a fresh, empty entry would also have lost.
        #expect(entry.number == existing[0].number, "the book's folder number was reset")
        #expect(entry.folder == existing[0].folder)
        #expect(entry.id == existing[0].id)
        #expect(entry.book.title == "A Desolation")
    }

    /// The same run creating the book and then adding to it always worked,
    /// because the runner has that entry in hand. Kept so a fix to the case
    /// above cannot break the case below.
    @Test("a book created and extended in one run still gets all its formats")
    func withinOneRun() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let book = Book(title: "Ancillary Justice", authors: ["Ann Leckie"])

        let plan = ImportPlanner.plan(candidates: [
            try candidate(temporary, "a.epub", .epub, book),
            try candidate(temporary, "a.azw3", .azw3, book),
            try candidate(temporary, "a.mobi", .mobi, book),
        ])
        #expect(plan.newBookCount == 1)
        #expect(plan.addedFormatCount == 2)

        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: plan, sourceDescription: "one run"))
        let entry = try #require(outcome.entries.first)
        #expect(entry.formats.map(\.format).sorted() == [.epub, .azw3, .mobi].sorted())
        #expect(entry.number > 0)
    }

    /// Without the lookup the runner cannot know, and the old behaviour is what
    /// it falls back to. This test says what that costs, so nobody removes the
    /// lookup thinking it is decoration.
    @Test("with no way to ask, the runner says so by losing the earlier formats")
    func withoutTheLookup() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let book = Book(title: "A Desolation", authors: ["Becky Lefevre"])

        let first = ImportPlanner.plan(candidates: [try candidate(temporary, "a.epub", .epub, book)])
        let existing = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: first, sourceDescription: "run 1")).entries

        let second = ImportPlanner.plan(
            candidates: [try candidate(temporary, "a.azw3", .azw3, book)],
            knowledge: knowledge(from: existing),
            startingNumber: (existing.map(\.number).max() ?? 0) + 1)
        // No `existingEntry`: the default.
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: second, sourceDescription: "run 2"))

        #expect(outcome.entries.first?.formats.map(\.format) == [.azw3])
        // The folder on disk still holds both, which is why this was invisible:
        // nothing was lost, the index was merely wrong until the next rebuild.
        let folder = library.root.appendingPathComponent(try #require(existing.first).folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(names.contains { $0.hasSuffix(".epub") })
        #expect(names.contains { $0.hasSuffix(".azw3") })
    }
}
