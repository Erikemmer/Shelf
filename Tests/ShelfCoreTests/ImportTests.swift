import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// The planner. Pure, so the whole of "what would this import do" is tested
/// without a disk – and the counting protocol the user confirms is the same
/// value the runner is handed.
@Suite("Planning an import")
struct ImportPlannerTests {

    private func candidate(
        name: String,
        title: String,
        author: String? = "An Author",
        format: BookFileFormat = .epub,
        isbn: String? = nil,
        digest: String = UUID().uuidString,
        byteSize: Int64 = 1_000
    ) -> ImportCandidate {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        return ImportCandidate(
            source: URL(fileURLWithPath: "/source/\(name)"),
            byteSize: byteSize,
            format: format,
            sha256: digest,
            book: Book(title: title, authors: author.map { [$0] } ?? [], identifiers: identifiers))
    }

    @Test("a book the library does not have becomes a new book in its own folder")
    func newBook() {
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "Emma", author: "Jane Austen")],
            startingNumber: 7)

        #expect(plan.newBookCount == 1)
        #expect(plan.addedFormatCount == 0)
        #expect(plan.skipped.isEmpty)
        guard case .newBook(let new)? = plan.operations.first else {
            Issue.record("expected a new book")
            return
        }
        #expect(new.number == 7)
        #expect(new.folder == "Austen, Jane/Emma (7)")
        #expect(new.fileName == "Emma - Jane Austen.epub")
    }

    @Test("numbers are handed out in order from where the library's counter stands")
    func numbering() {
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(name: "a.epub", title: "A"),
                candidate(name: "b.epub", title: "B"),
                candidate(name: "c.epub", title: "C"),
            ],
            startingNumber: 10)
        let numbers = plan.operations.compactMap { operation -> Int? in
            if case .newBook(let new) = operation { return new.number }
            return nil
        }
        #expect(numbers.sorted() == [10, 11, 12])
    }

    // MARK: Files that lie next to each other

    /// The rule the Sprint 4 screenshot asked for. A folder of downloads holds
    /// `Title - Author.epub`, `.azw3`, `.mobi` and `.pdf`; only the EPUB has
    /// metadata worth the name, and the PDF's is its file name. Before this
    /// rule they became two, three or four books, because the only thing that
    /// could have joined them was a title the PDF did not have.
    @Test("files with one stem in one folder are one book, whatever they say about themselves")
    func siblingsAreOneBook() {
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(name: "Emma - Jane Austen.epub", title: "Emma", author: "Jane Austen"),
                // What a PDF with no metadata at all comes out as.
                candidate(name: "Emma - Jane Austen.pdf", title: "Emma - Jane Austen", author: nil, format: .pdf),
                candidate(name: "Emma - Jane Austen.mobi", title: "", author: nil, format: .mobi),
            ],
            startingNumber: 4)

        #expect(plan.newBookCount == 1)
        #expect(plan.addedFormatCount == 2)
        #expect(plan.skipped.isEmpty)
        // The EPUB is the one that becomes the book, so its metadata is the
        // book's and the other two join the folder it named.
        let folders = Set(
            plan.operations.map { operation -> String in
                switch operation {
                case .newBook(let new): return new.folder
                case .addFormat(let add): return add.folder
                }
            })
        #expect(folders == ["Austen, Jane/Emma (4)"])
    }

    /// The same stem in a *different* folder is a different book: two
    /// downloads of the same title in two places are exactly the case the
    /// three duplicate rules are for, and this one must not pre-empt them.
    @Test("the same stem in another folder is not the same book")
    func siblingsAreFolderWide() {
        var second = candidate(name: "Emma - Jane Austen.pdf", title: "Something Else", author: nil, format: .pdf)
        second.source = URL(fileURLWithPath: "/elsewhere/Emma - Jane Austen.pdf")
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "Emma - Jane Austen.epub", title: "Emma", author: "Jane Austen"), second])

        #expect(plan.newBookCount == 2)
    }

    /// Two files of the *same* format under one stem cannot both be the book's
    /// EPUB, so the second is what it has always been: a duplicate inside the
    /// import.
    @Test("two files of one format under one stem are still a duplicate")
    func siblingsOfTheSameFormat() {
        var second = candidate(name: "Emma - Jane Austen.EPUB", title: "Emma", author: "Jane Austen")
        second.source = URL(fileURLWithPath: "/source/Emma - Jane Austen.EPUB")
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "Emma - Jane Austen.epub", title: "Emma", author: "Jane Austen"), second])

        #expect(plan.newBookCount == 1)
        #expect(plan.skipped.map(\.reason) == [.duplicateWithinImport])
    }

    /// A book the library already holds still wins over a sibling: the file is
    /// added to the book that is there rather than to a second copy of it.
    @Test("a sibling group joins the book the library already has")
    func siblingsJoinAnExistingBook() {
        let existing = UUID()
        let key = DuplicateKey.titleAuthor(title: "Emma", author: "Jane Austen")
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(name: "Emma - Jane Austen.epub", title: "Emma", author: "Jane Austen"),
                candidate(name: "Emma - Jane Austen.pdf", title: "Emma - Jane Austen", author: nil, format: .pdf),
            ],
            knowledge: ImportKnowledge(
                titleKeys: [key: [existing]],
                formatsByBook: [existing: [.epub]],
                foldersByBook: [existing: "Austen, Jane/Emma (2)"]))

        #expect(plan.newBookCount == 0)
        #expect(plan.addedFormatCount == 1)
        #expect(plan.skipped.map(\.reason) == [.sameTitleAndAuthor])
        guard case .addFormat(let add)? = plan.operations.first else {
            Issue.record("expected the PDF to join the book already in the library")
            return
        }
        #expect(add.bookID == existing)
        #expect(add.folder == "Austen, Jane/Emma (2)")
    }

    // MARK: The three duplicate tests (CONCEPT §2.4)

    /// The strongest of the three: two files with the same SHA-256 are the same
    /// bytes, whatever they are called.
    @Test("the same bytes are skipped, whatever the file is called")
    func duplicateByContent() {
        let existing = UUID()
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "copy.epub", title: "Different Title", digest: "same")],
            knowledge: ImportKnowledge(digests: ["same": existing]))

        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.sameContent])
    }

    @Test("the same ISBN in the same format is skipped")
    func duplicateByISBN() {
        let existing = UUID()
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "Dune", isbn: "9780441013593")],
            knowledge: ImportKnowledge(
                isbns: ["9780441013593": existing],
                formatsByBook: [existing: [.epub]]))

        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.sameISBN])
    }

    @Test("the same title and author in the same format is skipped")
    func duplicateByTitleAndAuthor() {
        let existing = UUID()
        let key = DuplicateKey.titleAuthor(title: "Emma", author: "Jane Austen")
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "Emma", author: "Jane Austen")],
            knowledge: ImportKnowledge(titleKeys: [key: [existing]], formatsByBook: [existing: [.epub]]))

        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.sameTitleAndAuthor])
    }

    /// Same book, new format: one more file in the folder it already has. Never
    /// a second folder – that is what makes "Add Format…" and dragging a second
    /// file the same thing.
    @Test("the same book in a format it does not have is added to it")
    func newFormatForExistingBook() {
        let existing = UUID()
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.azw3", title: "Dune", format: .azw3, isbn: "9780441013593")],
            knowledge: ImportKnowledge(
                isbns: ["9780441013593": existing],
                formatsByBook: [existing: [.epub]]))

        #expect(plan.newBookCount == 0)
        #expect(plan.addedFormatCount == 1)
        guard case .addFormat(let add)? = plan.operations.first else {
            Issue.record("expected a format to be added")
            return
        }
        #expect(add.bookID == existing)
    }

    /// An ISBN names an edition; a title does not. "Dune" by Frank Herbert is
    /// one title and a dozen editions.
    @Test("ISBN is checked before title and author")
    func isbnBeforeTitle() {
        let byISBN = UUID()
        let byTitle = UUID()
        let key = DuplicateKey.titleAuthor(title: "Dune", author: "Frank Herbert")
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(
                    name: "a.azw3", title: "Dune", author: "Frank Herbert", format: .azw3,
                    isbn: "9780441013593")
            ],
            knowledge: ImportKnowledge(
                isbns: ["9780441013593": byISBN],
                titleKeys: [key: [byTitle]],
                formatsByBook: [byISBN: [.epub], byTitle: [.epub]]))

        guard case .addFormat(let add)? = plan.operations.first else {
            Issue.record("expected a format to be added")
            return
        }
        #expect(add.bookID == byISBN)
    }

    /// Two library books with the same title and author and no ISBN are a mess
    /// Shelf must not make worse by picking one of them.
    @Test("an ambiguous title match makes a new book rather than guessing")
    func ambiguousMatch() {
        let key = DuplicateKey.titleAuthor(title: "Dune", author: "Frank Herbert")
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "Dune", author: "Frank Herbert")],
            knowledge: ImportKnowledge(titleKeys: [key: [UUID(), UUID()]]))
        #expect(plan.newBookCount == 1)
        #expect(plan.skipped.isEmpty)
    }

    // MARK: Duplicates inside one import

    @Test("the same file dropped twice is imported once")
    func duplicateWithinImport() {
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(name: "a.epub", title: "Emma", digest: "same"),
                candidate(name: "b.epub", title: "Emma", digest: "same"),
            ])
        #expect(plan.newBookCount == 1)
        #expect(plan.skipped.map(\.reason) == [.duplicateWithinImport])
    }

    /// A drop containing both the EPUB and the AZW3 of one book has to create
    /// one book with two formats, not two books.
    @Test("an EPUB and an AZW3 of one book in one drop become one book")
    func twoFormatsInOneImport() {
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(name: "a.epub", title: "Dune", author: "Frank Herbert", format: .epub),
                candidate(name: "a.azw3", title: "Dune", author: "Frank Herbert", format: .azw3),
            ])
        #expect(plan.newBookCount == 1)
        #expect(plan.addedFormatCount == 1)

        guard
            case .newBook(let new) = plan.operations.first(where: {
                if case .newBook = $0 { return true } else { return false }
            }),
            case .addFormat(let add) = plan.operations.first(where: {
                if case .addFormat = $0 { return true } else { return false }
            })
        else {
            Issue.record("expected one new book and one added format")
            return
        }
        // Both files end up in the same folder.
        #expect(add.folder == new.folder)
    }

    @Test("the same book in the same format twice in one drop is skipped once")
    func sameFormatTwiceInOneImport() {
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(name: "a.epub", title: "Dune", author: "Frank Herbert", digest: "one"),
                candidate(name: "b.epub", title: "Dune", author: "Frank Herbert", digest: "two"),
            ])
        #expect(plan.newBookCount == 1)
        #expect(plan.skipped.map(\.reason) == [.duplicateWithinImport])
    }

    // MARK: Folders

    /// Writing into a folder that has somebody else's files in it is the one
    /// thing an import must not do.
    @Test("a folder that already exists gets a suffix rather than being written into")
    func folderCollision() {
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "Emma", author: "Jane Austen")],
            startingNumber: 3,
            existingFolders: ["Austen, Jane/Emma (3)"])
        guard case .newBook(let new)? = plan.operations.first else {
            Issue.record("expected a new book")
            return
        }
        #expect(new.folder == "Austen, Jane/Emma (3)-2")
    }

    /// APFS is case-insensitive, so two folders differing only in case would be
    /// one folder on a normal Mac.
    @Test("folder collisions are compared without regard to case")
    func folderCollisionCaseInsensitive() {
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "emma", author: "Jane Austen")],
            startingNumber: 3,
            existingFolders: ["Austen, Jane/Emma (3)"])
        guard case .newBook(let new)? = plan.operations.first else {
            Issue.record("expected a new book")
            return
        }
        #expect(new.folder.hasSuffix("-2"))
    }

    @Test("a name that needs sanitising is sanitised on the way in")
    func sanitisedFolder() {
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "Vol. 1/2: A Book", author: "A/B")],
            startingNumber: 1)
        guard case .newBook(let new)? = plan.operations.first else {
            Issue.record("expected a new book")
            return
        }
        #expect(!new.folder.contains("/2"))
        #expect(new.folder.split(separator: "/").count == 2)
    }

    // MARK: The counting protocol

    @Test("two runs over the same files produce the same plan")
    func planIsStable() {
        let candidates = (1...20).map { candidate(name: "\($0).epub", title: "Book \($0)") }
        let first = ImportPlanner.plan(candidates: candidates, startingNumber: 1)
        let second = ImportPlanner.plan(candidates: candidates.reversed(), startingNumber: 1)
        #expect(first == second)
    }

    @Test("the plan says what it will do, in the words the sheet shows")
    func summary() {
        let existing = UUID()
        let plan = ImportPlanner.plan(
            candidates: [
                candidate(name: "a.epub", title: "New One", byteSize: 2_000_000),
                candidate(name: "b.azw3", title: "Dune", format: .azw3, isbn: "1", byteSize: 1_000_000),
                candidate(name: "c.epub", title: "Copy", digest: "known"),
            ],
            knowledge: ImportKnowledge(
                digests: ["known": existing], isbns: ["1": existing], formatsByBook: [existing: [.epub]]))

        #expect(plan.summary() == "1 new book · 1 new format · 1 skipped · 2.9 MB")
        #expect(plan.fileCount == 2)
        #expect(plan.count(of: .epub) == 1)
        #expect(plan.count(of: .azw3) == 1)
    }

    @Test("nothing to import says so rather than showing zeroes")
    func emptySummary() {
        #expect(ImportPlan.empty.summary() == "Nothing to import")
        #expect(ImportPlan.empty.isEmpty)
    }

    /// Running out of space halfway is the one failure that leaves a library
    /// half-imported, so the check is a number the plan can state up front.
    @Test("the space needed carries five per cent of headroom")
    func requiredBytes() {
        let plan = ImportPlanner.plan(
            candidates: [candidate(name: "a.epub", title: "A", byteSize: 1_000_000)])
        #expect(plan.totalBytes == 1_000_000)
        #expect(plan.requiredBytes == 1_050_000)
    }

    @Test("every skip reason has words a person can read")
    func skipReasonsAreLegible() {
        for reason in SkippedImport.Reason.allCases {
            #expect(!reason.label.isEmpty)
        }
    }
}

/// The runner. This one does touch the disk, because copying and verifying is
/// the whole point – and because "the copy call returned success" is not the
/// same as "the file is intact".
@Suite("Running an import")
struct ImportRunnerTests {

    private func makeSource(
        _ folder: TemporaryFolder, name: String, book: Book, cover: Data? = nil
    ) throws
        -> ImportCandidate
    {
        let epub = SyntheticEPUB(book: book, cover: cover).data()
        let url = try folder.write("source/\(name)", data: epub)
        let read = try EPUBMetadata.read(url: url)
        let digest = try FileDigest.sha256(of: url, makeHasher: PortableSHA256Hasher.factory)
        return ImportCandidate(
            source: url, byteSize: Int64(epub.count), format: .epub, sha256: digest,
            book: read.book, cover: read.cover, coverName: read.coverName, warnings: read.warnings)
    }

    private func runner() -> ImportRunner {
        ImportRunner(makeHasher: PortableSHA256Hasher.factory)
    }

    @Test("a book is copied into its folder with its cover and its OPF")
    func importsOneBook() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let candidate = try makeSource(
            folder, name: "emma.epub",
            book: Book(title: "Emma", authors: ["Jane Austen"]),
            cover: MinimalPNG.cover(width: 10, height: 15, seed: 3))

        let plan = ImportPlanner.plan(candidates: [candidate], startingNumber: 1)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "a test"))

        #expect(outcome.report.everythingVerified)
        #expect(outcome.report.newBooks == 1)
        #expect(outcome.entries.count == 1)
        #expect(
            folder.names(in: "Lib/Austen, Jane/Emma (1)") == [
                "Emma - Jane Austen.epub", "cover.png", "metadata.opf",
            ])
        #expect(outcome.nextBookNumber == 2)
    }

    /// The source is only ever read. That is the promise the whole design
    /// exists to earn, so it is checked rather than assumed.
    @Test("the source folder is untouched, byte for byte")
    func sourceIsUntouched() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let candidate = try makeSource(folder, name: "a.epub", book: Book(title: "A", authors: ["B"]))

        let before = try FileDigest.sha256(of: candidate.source, makeHasher: PortableSHA256Hasher.factory)
        let names = folder.names(in: "source")

        let plan = ImportPlanner.plan(candidates: [candidate], startingNumber: 1)
        _ = try await runner().run(ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        #expect(folder.names(in: "source") == names)
        #expect(try FileDigest.sha256(of: candidate.source, makeHasher: PortableSHA256Hasher.factory) == before)
    }

    /// "Verified" has to mean a digest was compared, not that a copy call
    /// returned success.
    @Test("the copy's digest is the one recorded, and it matches the source")
    func verification() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let candidate = try makeSource(folder, name: "a.epub", book: Book(title: "A", authors: ["B"]))

        let plan = ImportPlanner.plan(candidates: [candidate], startingNumber: 1)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        guard let format = outcome.entries.first?.formats.first else {
            Issue.record("no format recorded")
            return
        }
        #expect(format.sha256 == candidate.sha256)
        let copied = library.root.appendingPathComponent("B/A (1)/\(format.fileName)")
        #expect(try FileDigest.sha256(of: copied, makeHasher: PortableSHA256Hasher.factory) == candidate.sha256)
    }

    /// The bug the synthetic library's every-hundredth long title found: the
    /// temporary name used to be the destination's name with a prefix, which
    /// pushed a 255-byte file name over the limit and failed the copy for the
    /// longest titles only.
    @Test("a title long enough to fill the name limit still imports")
    func veryLongTitle() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let title = String(repeating: "A Very Long Title ", count: 30)
        let candidate = try makeSource(
            folder, name: "long.epub", book: Book(title: title, authors: ["An Author"]))

        let plan = ImportPlanner.plan(candidates: [candidate], startingNumber: 1)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        #expect(outcome.report.everythingVerified)
        #expect(outcome.report.failures.isEmpty)
    }

    @Test("no half-written file is left behind, whatever happened")
    func noPartialsLeft() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let candidates = try (1...5).map {
            try makeSource(folder, name: "\($0).epub", book: Book(title: "Book \($0)", authors: ["A"]))
        }
        let plan = ImportPlanner.plan(candidates: candidates, startingNumber: 1)
        _ = try await runner().run(ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        let walker = FileManager.default.enumerator(atPath: library.root.path)
        var partials = 0
        while let name = walker?.nextObject() as? String {
            if name.contains(ImportRunner.partialPrefix) { partials += 1 }
        }
        #expect(partials == 0)
    }

    @Test("a second format lands in the folder the book already has")
    func addFormat() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let book = Book(title: "Dune", authors: ["Frank Herbert"], identifiers: ["isbn": "9780441013593"])

        // Two *different* files, as a real EPUB and a real AZW3 are: identical
        // bytes would be caught by the content check, which is the right
        // answer for identical bytes but not what this test is about.
        let epub = try makeSource(
            folder, name: "dune.epub", book: book, cover: MinimalPNG.cover(width: 8, height: 12, seed: 1))
        var azw3 = try makeSource(
            folder, name: "dune.azw3", book: book, cover: MinimalPNG.cover(width: 8, height: 12, seed: 2))
        azw3.format = .azw3

        let plan = ImportPlanner.plan(candidates: [epub, azw3], startingNumber: 1)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        #expect(outcome.report.everythingVerified)
        #expect(outcome.entries.count == 1)
        #expect(outcome.entries.first?.formats.count == 2)
        #expect(
            folder.names(in: "Lib/Herbert, Frank/Dune (1)") == [
                "Dune - Frank Herbert.azw3", "Dune - Frank Herbert.epub", "cover.png", "metadata.opf",
            ])
    }

    /// Byte-identical files really are duplicates, whatever their extensions
    /// claim – and the content check is what says so.
    @Test("two identical files with different extensions are one file")
    func identicalBytesDifferentExtension() throws {
        let folder = try TemporaryFolder()
        let book = Book(title: "Dune", authors: ["Frank Herbert"], identifiers: ["isbn": "1"])
        let epub = try makeSource(folder, name: "dune.epub", book: book)
        var azw3 = try makeSource(folder, name: "dune2.epub", book: book)
        azw3.format = .azw3

        let plan = ImportPlanner.plan(candidates: [epub, azw3], startingNumber: 1)
        #expect(plan.newBookCount == 1)
        #expect(plan.skipped.map(\.reason) == [.duplicateWithinImport])
    }

    /// EPUB is the format Sprint 1 can read metadata out of, so it is the one
    /// that should define the book – not whichever file name sorts first.
    @Test("the preferred format defines the new book, whatever the file names are")
    func preferredFormatWins() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let book = Book(title: "Dune", authors: ["Frank Herbert"], identifiers: ["isbn": "1"])

        // "aaa.azw3" sorts before "zzz.epub", so only the format rule can put
        // the EPUB first.
        let epub = try makeSource(
            folder, name: "zzz.epub", book: book, cover: MinimalPNG.cover(width: 8, height: 12, seed: 1))
        var azw3 = try makeSource(
            folder, name: "aaa.azw3", book: book, cover: MinimalPNG.cover(width: 8, height: 12, seed: 2))
        azw3.format = .azw3

        let plan = ImportPlanner.plan(candidates: [epub, azw3], startingNumber: 1)
        guard case .newBook(let new)? = plan.operations.first else {
            Issue.record("expected a new book first")
            return
        }
        #expect(new.candidate.format == .epub)

        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))
        #expect(outcome.report.everythingVerified)
    }

    /// Adding an AZW3 must not silently change the cover the user is used to.
    @Test("adding a format keeps the cover the book already had")
    func coverIsNotReplaced() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let book = Book(title: "Dune", authors: ["Frank Herbert"], identifiers: ["isbn": "1"])

        let first = MinimalPNG.cover(width: 8, height: 12, seed: 1)
        let second = MinimalPNG.cover(width: 8, height: 12, seed: 200)
        let epub = try makeSource(folder, name: "dune.epub", book: book, cover: first)
        var azw3 = try makeSource(folder, name: "dune.azw3", book: book, cover: second)
        azw3.format = .azw3

        let plan = ImportPlanner.plan(candidates: [epub, azw3], startingNumber: 1)
        _ = try await runner().run(ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        let coverURL = library.root.appendingPathComponent("Herbert, Frank/Dune (1)/cover.png")
        #expect(try Data(contentsOf: coverURL) == first)
    }

    /// Refused before the first byte: running out of space halfway is the one
    /// failure that leaves a library half-imported.
    @Test("not enough space is refused up front, before anything is copied")
    func notEnoughSpace() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let candidate = try makeSource(folder, name: "a.epub", book: Book(title: "A", authors: ["B"]))
        let plan = ImportPlanner.plan(candidates: [candidate], startingNumber: 1)

        let tightRunner = ImportRunner(makeHasher: PortableSHA256Hasher.factory, freeSpace: { _ in 10 })
        await #expect(throws: ImportRunner.Failure.notEnoughSpace(needed: plan.requiredBytes, available: 10)) {
            try await tightRunner.run(
                ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))
        }
        #expect(folder.names(in: "Lib") == [".shelf"])
    }

    /// A source that vanished between the plan and the run is one file's
    /// problem, not the import's.
    @Test("a file that cannot be read fails alone and is named in the report")
    func oneFileFails() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let good = try makeSource(folder, name: "good.epub", book: Book(title: "Good", authors: ["A"]))
        var missing = try makeSource(folder, name: "gone.epub", book: Book(title: "Gone", authors: ["A"]))
        try FileManager.default.removeItem(at: missing.source)
        missing.source = folder.url.appendingPathComponent("source/gone.epub")

        let plan = ImportPlanner.plan(candidates: [good, missing], startingNumber: 1)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        #expect(!outcome.report.everythingVerified)
        #expect(outcome.report.failures.count == 1)
        #expect(outcome.report.failures.first?.path.hasSuffix("gone.epub") == true)
        // The good one still went in.
        #expect(outcome.entries.count == 1)
        #expect(outcome.report.newBooks == 1)
    }

    /// The counter must move forward even when every book failed, or the next
    /// import would aim at folder 1.
    @Test("the book counter never goes backwards, even after a failed run")
    func counterMovesForward() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        var missing = try makeSource(folder, name: "gone.epub", book: Book(title: "Gone", authors: ["A"]))
        try FileManager.default.removeItem(at: missing.source)
        missing.source = folder.url.appendingPathComponent("source/gone.epub")

        let plan = ImportPlanner.plan(candidates: [missing], startingNumber: 50)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))
        #expect(outcome.nextBookNumber == 51)
    }

    @Test("the OPF next to the book says what the index says")
    func opfMatchesIndex() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let book = Book(
            title: "Ancillary Justice", authors: ["Ann Leckie"],
            series: SeriesRef(name: "Imperial Radch", index: 1), tags: ["space opera"])
        let candidate = try makeSource(folder, name: "a.epub", book: book)

        let plan = ImportPlanner.plan(candidates: [candidate], startingNumber: 1)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        guard let entry = outcome.entries.first else {
            Issue.record("nothing imported")
            return
        }
        let opf = library.root.appendingPathComponent(entry.folder).appendingPathComponent("metadata.opf")
        let parsed = try OPFDocument.read(try Data(contentsOf: opf), fallbackTitle: "x")
        #expect(parsed.book.id == entry.book.id)
        #expect(parsed.book.title == entry.book.title)
        #expect(parsed.book.series == entry.book.series)
        #expect(parsed.book.tags == entry.book.tags)
    }

    @Test("a book with no cover still imports, with a warning in the report")
    func withoutCover() async throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))
        let candidate = try makeSource(
            folder, name: "a.epub", book: Book(title: "No Cover", authors: ["A"]), cover: nil)

        let plan = ImportPlanner.plan(candidates: [candidate], startingNumber: 1)
        let outcome = try await runner().run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: "x"))

        #expect(outcome.report.everythingVerified)
        #expect(outcome.report.warnings.contains { $0.message.contains("cover") })
        #expect(!folder.exists("Lib/A/No Cover (1)/cover.png"))
    }
}

@Suite("The import report")
struct ImportReportTests {

    @Test("the headline leads with what was verified")
    func headline() {
        let report = ImportReport(
            libraryName: "Lib", sourceDescription: "a folder",
            newBooks: 3, addedFormats: 1, copiedByFormat: [.epub: 3, .azw3: 1], copiedBytes: 5_000_000)
        #expect(report.headline == "Verified · 4 files · 3 new books · 1 new format")
        #expect(report.everythingVerified)
    }

    /// The word is the same as Selector's, so a user of both apps reads the
    /// same words for the same guarantee.
    @Test("a failure says NOT VERIFIED and names every file")
    func failureHeadline() {
        let report = ImportReport(
            libraryName: "Lib", sourceDescription: "a folder",
            failures: [.init(path: "/x/broken.epub", message: "checksum mismatch")])
        #expect(report.headline == "FAILED: 1 file not verified")
        #expect(!report.everythingVerified)

        let text = report.rendered()
        #expect(text.contains("NOT VERIFIED"))
        #expect(text.contains("/x/broken.epub"))
        #expect(text.contains("checksum mismatch"))
    }

    /// A skipped file is a decision the user may disagree with, and they cannot
    /// if they cannot see which file it was.
    @Test("skipped files are named, not only counted")
    func skippedAreNamed() {
        let report = ImportReport(
            libraryName: "Lib", sourceDescription: "x",
            skipped: [
                .init(path: "/x/dup.epub", reason: .sameContent),
                .init(path: "/x/same-isbn.epub", reason: .sameISBN),
            ])
        let text = report.rendered()
        #expect(text.contains("/x/dup.epub"))
        #expect(text.contains("/x/same-isbn.epub"))
        #expect(text.contains("identical file"))
    }

    @Test("the report ends by saying the source is untouched")
    func sourceUntouchedLine() {
        let text = ImportReport(libraryName: "Lib", sourceDescription: "x").rendered()
        #expect(text.contains("Nothing at the source was changed, moved or deleted."))
    }

    /// The history of what came into a library is worth more than the last run
    /// alone, and it is only a few hundred bytes per import.
    @Test("a second import is appended, not written over the first")
    func appending() throws {
        let folder = try TemporaryFolder()
        let (library, _) = try Library.create(at: try folder.folder("Lib"))

        try ImportReport(libraryName: "Lib", sourceDescription: "first run").append(to: library)
        try ImportReport(libraryName: "Lib", sourceDescription: "second run").append(to: library)

        let text = try String(contentsOf: library.reportURL, encoding: .utf8)
        #expect(text.contains("first run"))
        #expect(text.contains("second run"))
    }

    /// A record that reads differently on another Mac is a worse record.
    @Test("dates and durations are formatted without the user's locale")
    func fixedFormats() {
        #expect(ImportReport.timestamp(Date(timeIntervalSince1970: 0)).count == 19)
        #expect(ImportReport.duration(45) == "45 s")
        #expect(ImportReport.duration(125) == "2 min 5 s")
        #expect(ByteCount.format(1_500_000) == "1.4 MB")
        #expect(ByteCount.format(512) == "512 B")
    }
}

/// A second import into the same library, which is what a resumed Calibre
/// import is. Nothing had ever imported twice into one library before Sprint 3,
/// and it turned out the planner could not say where a book it already knew
/// about lived.
@Suite("Importing into a library that already holds books")
struct SecondImportTests {
    private func candidate(
        id: UUID = UUID(), title: String, author: String = "Ursula K. Le Guin",
        format: BookFileFormat = .epub, isbn: String? = nil, digest: String = UUID().uuidString
    ) -> ImportCandidate {
        var identifiers: [String: String] = [:]
        if let isbn { identifiers["isbn"] = isbn }
        return ImportCandidate(
            source: URL(fileURLWithPath: "/source/\(title).\(format.rawValue)"),
            byteSize: 1_000, format: format, sha256: digest,
            book: Book(id: id, title: title, authors: [author], identifiers: identifiers))
    }

    /// ADR 0002 decision 8: a new format joins the book it belongs to, **in the
    /// folder it already has**. Before `foldersByBook` the planner handed the
    /// runner an empty folder here and the runner refused, which is the right
    /// refusal for the wrong reason: it would otherwise have written into the
    /// library's root.
    @Test("a new format for a book the library has goes into that book's folder")
    func addsFormatIntoTheExistingFolder() {
        let existing = UUID()
        let plan = ImportPlanner.plan(
            candidates: [candidate(title: "The Dispossessed", format: .azw3, isbn: "9780061054884")],
            knowledge: ImportKnowledge(
                isbns: ["9780061054884": existing],
                formatsByBook: [existing: [.epub]],
                foldersByBook: [existing: "Le Guin, Ursula K./The Dispossessed (12)"]))
        guard case .addFormat(let add) = plan.operations.first else {
            Issue.record("expected one addFormat, got \(plan.operations)")
            return
        }
        #expect(add.bookID == existing)
        #expect(add.folder == "Le Guin, Ursula K./The Dispossessed (12)")
    }

    /// Calibre's UUID is the book's identity (CONCEPT §5.3), so a resumed
    /// import rejoins its own books instead of making second copies of them.
    @Test("a book the library knows by its UUID is the same book, not a new one")
    func uuidIsIdentity() {
        let id = UUID()
        let plan = ImportPlanner.plan(
            candidates: [candidate(id: id, title: "A Wizard of Earthsea", format: .azw3)],
            knowledge: ImportKnowledge(
                formatsByBook: [id: [.epub]], foldersByBook: [id: "Le Guin, Ursula K./Earthsea (3)"]))
        guard case .addFormat(let add) = plan.operations.first else {
            Issue.record("expected one addFormat, got \(plan.operations)")
            return
        }
        #expect(add.bookID == id)
        #expect(add.folder == "Le Guin, Ursula K./Earthsea (3)")
        #expect(plan.newBookCount == 0)
    }

    @Test("the same book in the same format is skipped, and the reason says so")
    func sameBookSameFormat() {
        let id = UUID()
        let plan = ImportPlanner.plan(
            candidates: [candidate(id: id, title: "A Wizard of Earthsea")],
            knowledge: ImportKnowledge(
                formatsByBook: [id: [.epub]], foldersByBook: [id: "Le Guin, Ursula K./Earthsea (3)"]))
        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.sameBook])
    }

    /// The UUID is a match a *folder* import can never make, and must not: two
    /// unrelated files must not become one book because a UUID was minted twice.
    /// A minted one is new every time, so this case simply never fires there.
    @Test("a freshly minted UUID matches nothing")
    func mintedUUIDsDoNotMatch() {
        let inTheLibrary = UUID()
        let plan = ImportPlanner.plan(
            candidates: [candidate(title: "Something Else")],
            knowledge: ImportKnowledge(
                formatsByBook: [inTheLibrary: [.epub]], foldersByBook: [inTheLibrary: "Somewhere/Else (1)"]))
        #expect(plan.newBookCount == 1)
    }
}
