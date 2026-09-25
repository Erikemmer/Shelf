import Foundation
import Testing

@testable import ShelfCore

/// "Write into the Book File", the core half — the plan a sheet would show,
/// and what `run` does with it once confirmed. The window itself
/// (`WriteIntoBookSheet`) is not reachable from `ShelfCoreTests`; this is
/// what it stands on.
@Suite("Write into the Book File — the plan and the run")
struct EPUBWriteTests {

    // MARK: The plan

    @Test("a plan lists every field, old beside new, and marks what cannot be written")
    func planComputesChangesAndFlagsUnwritten() throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub",
            data: Self.book(title: "Old Title", author: "Old Author"))

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(
                id: bookID, title: "New Title", authors: ["Old Author"], publisher: "New Publisher",
                description: "A new description"),
            number: 1, folder: "Author/Book (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }

        #expect(plan.entryID == bookID)
        #expect(plan.fileName == "book.epub")
        // Title changed and is written; the fixture has no publisher or
        // description, so those two are *created* (Sprint 10 part 2,
        // extended) rather than left off the list.
        let title = try #require(plan.changes.first { $0.field == .title })
        #expect(title.before == "Old Title")
        #expect(title.after == "New Title")
        #expect(title.changed)
        #expect(title.willBeWritten)

        let publisher = try #require(plan.changes.first { $0.field == .publisher })
        #expect(publisher.before == "")
        #expect(publisher.after == "New Publisher")
        #expect(publisher.willBeWritten)

        let authors = try #require(plan.changes.first { $0.field == .authors })
        #expect(!authors.changed)

        #expect(plan.unwritten.isEmpty)
    }

    @Test("a title the file does not have shows as not set, never guessed from the file name")
    func planShowsAMissingTitleAsNotSetRatherThanGuessed() throws {
        // The file's own name and Shelf's own title are the *same* guess on
        // purpose — the one real case that hid this bug: a book imported
        // from a title-less EPUB gets its title guessed from the file name,
        // and re-reading the file with that same guess as a fallback made
        // "before" and "after" agree by coincidence, not because the file
        // actually holds a title.
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Nameless (1)/Nameless.epub", data: Self.bookWithNoTitle(author: "Some Author"))

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "Nameless.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "Nameless", authors: ["Some Author"]), number: 1,
            folder: "Author/Nameless (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }

        let title = try #require(plan.changes.first { $0.field == .title })
        #expect(title.before == "")
        #expect(!title.willBeWritten)
    }

    @Test("an author the file does not have shows as not set, never guessed from the file name")
    func planShowsAMissingAuthorAsNotSetRatherThanGuessed() throws {
        // The title bug's own twin: `EPUBMetadata.read` guesses an author
        // from the file name exactly the same way it guesses a title, a few
        // lines below it. Shelf's own author list has to be empty too here
        // — a non-empty one the file's zero `dc:creator` elements cannot
        // match is `EPUBOPFPatch.Failure.authorCountMismatch`, refused
        // before a plan exists at all, so it is this exact shape (Shelf
        // agrees there are no authors) that is the one still reachable.
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Nameless (1)/Nameless - Some Author.epub",
            data: Self.bookWithNoTitleAndNoAuthor())

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "Nameless - Some Author.epub", byteSize: 1, sha256: "old",
            modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "Nameless", authors: []), number: 1,
            folder: "Author/Nameless (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }

        let authors = try #require(plan.changes.first { $0.field == .authors })
        #expect(authors.before == "")
    }

    @Test("a book where every field is already the same or unwritable has no real change")
    func planWithNothingToWriteHasNoChange() throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Nameless (1)/Nameless.epub", data: Self.bookWithNoTitle(author: "Some Author"))

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "Nameless.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        // Shelf agrees with the file on everything it can compare, and the
        // one field that differs (title) is the one field the file has no
        // element for — so nothing this plan lists would actually be
        // written if it ran.
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "Nameless", authors: ["Some Author"]), number: 1,
            folder: "Author/Nameless (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }

        #expect(!plan.hasChange)
    }

    @Test("a book with a real change has one")
    func planWithARealChangeHasChange() throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub",
            data: Self.book(title: "Old Title", author: "Old Author"))

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "New Title", authors: ["Old Author"]), number: 1,
            folder: "Author/Book (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }

        #expect(plan.hasChange)
    }

    @Test("a selection of several books, none of which would change, has no book with a real change")
    func planForSeveralUnchangedBooksHasNoneWithChange() throws {
        // The count the sheet's "Nothing to write" / "%lld books would not
        // get a new EPUB file." sentences read — `changingCount` in
        // `WriteIntoBookSheet` — is `plan.books.filter(\.hasChange).count`.
        // This proves that count stays zero across a *selection*, not just
        // for one book in isolation.
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/A/One (1)/book.epub", data: Self.book(title: "One", author: "Author One"))
        _ = try folder.write(
            "library/B/Two (1)/book.epub", data: Self.book(title: "Two", author: "Author Two"))

        let library = Library(root: libraryRoot)
        let idOne = UUID()
        let idTwo = UUID()
        let formatOne = BookFormat(
            bookID: idOne, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "one", modifiedAt: Date())
        let formatTwo = BookFormat(
            bookID: idTwo, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "two", modifiedAt: Date())
        // Shelf agrees with each file on every field — neither book was
        // ever edited, the same shape an unedited import leaves behind.
        let entryOne = LibraryEntry(
            book: Book(id: idOne, title: "One", authors: ["Author One"]), number: 1, folder: "A/One (1)",
            formats: [formatOne])
        let entryTwo = LibraryEntry(
            book: Book(id: idTwo, title: "Two", authors: ["Author Two"]), number: 1, folder: "B/Two (1)",
            formats: [formatTwo])

        let plan = EPUBWrite.plan(for: [entryOne, entryTwo], library: library)

        #expect(plan.books.count == 2)
        #expect(plan.books.filter(\.hasChange).isEmpty)
    }

    @Test("a book with no EPUB has no plan")
    func planRefusesWhenThereIsNoEPUB() throws {
        let folder = try TemporaryFolder()
        let library = Library(root: try folder.folder("library"))
        let bookID = UUID()
        let pdf = BookFormat(
            bookID: bookID, format: .pdf, fileName: "book.pdf", byteSize: 1, sha256: "x", modifiedAt: Date())
        let entry = LibraryEntry(book: Book(id: bookID, title: "A Book"), number: 1, folder: "x", formats: [pdf])

        guard case .failure(let failure) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure == .noEPUB)
    }

    @Test("a DRM-protected book is refused, same as EPUBFileReplacement's own preflight")
    func planRefusesDRM() throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub", data: Self.book(title: "A Book", author: "Someone", drm: true))

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "x", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "A Book", authors: ["Someone"]), number: 1, folder: "Author/Book (1)",
            formats: [format])

        guard case .failure(let failure) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure == .refused(.drmProtected))
    }

    @Test("a changed number of authors is refused, never guessed at")
    func planRefusesAuthorCountMismatch() throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub", data: Self.book(title: "A Book", author: "One Author"))

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "x", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "A Book", authors: ["One Author", "A Second Author"]), number: 1,
            folder: "Author/Book (1)", formats: [format])

        guard case .failure(let failure) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure == .authorCountMismatch(existing: 1, new: 2))
    }

    @Test("only a book with an EPUB and no DRM is offered the command")
    func eligibility() {
        let bookID = UUID()
        let epub = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "x", modifiedAt: Date())
        let epubDRM = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "x", modifiedAt: Date(),
            drm: .adobeADEPT)
        let pdf = BookFormat(
            bookID: bookID, format: .pdf, fileName: "book.pdf", byteSize: 1, sha256: "x", modifiedAt: Date())

        let ok = LibraryEntry(book: Book(id: bookID, title: "A"), number: 1, folder: "x", formats: [epub])
        let drm = LibraryEntry(book: Book(id: bookID, title: "A"), number: 1, folder: "x", formats: [epubDRM])
        let none = LibraryEntry(book: Book(id: bookID, title: "A"), number: 1, folder: "x", formats: [pdf])

        #expect(EPUBWrite.isEligible(ok))
        #expect(!EPUBWrite.isEligible(drm))
        #expect(!EPUBWrite.isEligible(none))
    }

    // MARK: The cover, in the plan (Sprint 11, Schritt 3)

    @Test("a cover on disk that differs from the book's own is planned, written, and shows as a change")
    func planWritesADifferentCover() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub",
            data: Self.bookWithCover(title: "A Book", author: "An Author", coverBytes: Self.jpegA))
        _ = try folder.write("library/Author/Book (1)/cover.jpg", data: Self.jpegB)

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "A Book", authors: ["An Author"]), number: 1,
            folder: "Author/Book (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.cover.beforeBytes == Self.jpegA)
        #expect(plan.cover.afterBytes == Self.jpegB)
        #expect(plan.cover.changed)
        // No field changed — title and author already match — so the cover
        // alone is what makes this plan worth confirming.
        #expect(plan.changes.allSatisfy { !$0.changed })
        #expect(plan.hasChange)

        let bin = try Bin(in: folder.url)
        let index = try LibraryIndex(inMemory: "epub-write-cover-test")
        try await index.save(entry)
        let report = await EPUBWrite.run(
            [plan], entries: [bookID: entry], library: library, index: index, disposal: bin.disposal)
        #expect(report.succeeded == 1)

        let written = try Data(contentsOf: libraryRoot.appendingPathComponent("Author/Book (1)/book.epub"))
        let read = EPUBMetadata.read(try ZipReader(data: written), fallbackTitle: "ignored")
        #expect(read.cover == Self.jpegB)
    }

    @Test("a cover on disk identical to the book's own is not a change")
    func identicalCoverOnDiskIsNoChange() throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub",
            data: Self.bookWithCover(title: "A Book", author: "An Author", coverBytes: Self.jpegA))
        _ = try folder.write("library/Author/Book (1)/cover.jpg", data: Self.jpegA)

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "A Book", authors: ["An Author"]), number: 1,
            folder: "Author/Book (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.cover.beforeBytes == Self.jpegA)
        #expect(plan.cover.afterBytes == Self.jpegA)
        #expect(!plan.cover.changed)
        #expect(!plan.hasChange)
    }

    @Test("no cover file beside the book means nothing to offer, and no change from the cover")
    func noCoverFileBesideTheBookIsNothingToOffer() throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub",
            data: Self.bookWithCover(title: "A Book", author: "An Author", coverBytes: Self.jpegA))
        // No cover.jpg written beside the book — Shelf has nothing of its
        // own to offer, whatever the book's own file already carries.

        let library = Library(root: libraryRoot)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "A Book", authors: ["An Author"]), number: 1,
            folder: "Author/Book (1)", formats: [format])

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.cover.beforeBytes == Self.jpegA)
        #expect(plan.cover.afterBytes == nil)
        #expect(!plan.cover.changed)
        #expect(!plan.hasChange)
    }

    // MARK: Running the plan

    @Test("several books are written one at a time, and the index follows")
    func runWritesSequentiallyAndUpdatesTheIndex() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/A/One (1)/book.epub", data: Self.book(title: "Old One", author: "Author One"))
        _ = try folder.write(
            "library/B/Two (1)/book.epub", data: Self.book(title: "Old Two", author: "Author Two"))

        let library = Library(root: libraryRoot)
        let index = try LibraryIndex(inMemory: "epub-write-test")
        let bin = try Bin(in: folder.url)

        let idOne = UUID()
        let idTwo = UUID()
        let formatOne = BookFormat(
            bookID: idOne, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old-one", modifiedAt: Date())
        let formatTwo = BookFormat(
            bookID: idTwo, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old-two", modifiedAt: Date())
        let entryOne = LibraryEntry(
            book: Book(id: idOne, title: "New One", authors: ["Author One"]), number: 1, folder: "A/One (1)",
            formats: [formatOne])
        let entryTwo = LibraryEntry(
            book: Book(id: idTwo, title: "New Two", authors: ["Author Two"]), number: 1, folder: "B/Two (1)",
            formats: [formatTwo])
        try await index.save(entryOne)
        try await index.save(entryTwo)

        guard case .success(let planOne) = EPUBWrite.plan(for: entryOne, library: library),
            case .success(let planTwo) = EPUBWrite.plan(for: entryTwo, library: library)
        else {
            Issue.record("expected both to plan")
            return
        }

        let progressLog = ProgressLog()
        let report = await EPUBWrite.run(
            [planOne, planTwo], entries: [idOne: entryOne, idTwo: entryTwo], library: library, index: index,
            disposal: bin.disposal,
            progress: { progressLog.record($0) })

        #expect(report.succeeded == 2)
        // One progress call per book plus the final "done" call, in order —
        // never both books reported "in flight" at once, which is what a
        // `TaskGroup` could otherwise produce.
        #expect(progressLog.calls.map(\.currentTitle) == ["New One", "New Two", ""])
        #expect(progressLog.calls.map(\.done) == [0, 1, 2])

        let reloadedOne = try await index.entries(ids: [idOne]).first
        let reloadedTwo = try await index.entries(ids: [idTwo]).first
        #expect(reloadedOne?.formats.first?.sha256 != "old-one")
        #expect(reloadedTwo?.formats.first?.sha256 != "old-two")
        // Both originals reached the (fake) Trash.
        #expect(bin.taken.count == 2)
    }

    @Test("run never touches a book with no real change — no Trash, no index update")
    func runLeavesANoChangeBookAlone() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Nameless (1)/Nameless.epub", data: Self.bookWithNoTitle(author: "Some Author"))

        let library = Library(root: libraryRoot)
        let index = try LibraryIndex(inMemory: "epub-write-no-change-test")
        let bin = try Bin(in: folder.url)

        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "Nameless.epub", byteSize: 1, sha256: "unchanged",
            modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "Nameless", authors: ["Some Author"]), number: 1,
            folder: "Author/Nameless (1)", formats: [format])
        try await index.save(entry)

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }
        #expect(!plan.hasChange)

        let report = await EPUBWrite.run(
            [plan], entries: [bookID: entry], library: library, index: index, disposal: bin.disposal)

        #expect(report.succeeded == 0)
        #expect(report.outcomes == [EPUBWrite.BookOutcome(entryID: bookID, title: "Nameless", result: .noChange)])
        #expect(bin.taken.isEmpty)
        let reloaded = try await index.entries(ids: [bookID]).first
        #expect(reloaded?.formats.first?.sha256 == "unchanged")
    }

    // MARK: Halting, resuming, and the manifest (Sprint 23, Teil B)

    @Test("a book that is written appends one manifest line naming the way back")
    func writingABookAppendsAManifestLine() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Book (1)/book.epub", data: Self.book(title: "Old Title", author: "Author"))

        let library = Library(root: libraryRoot)
        let index = try LibraryIndex(inMemory: "epub-write-manifest-test")
        let bin = try Bin(in: folder.url)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old", modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "New Title", authors: ["Author"]), number: 1, folder: "Author/Book (1)",
            formats: [format])
        try await index.save(entry)

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }
        _ = await EPUBWrite.run(
            [plan], entries: [bookID: entry], library: library, index: index, disposal: bin.disposal)

        let manifestText = try String(contentsOf: EPUBWriteManifest.url(in: library), encoding: .utf8)
        let lines = manifestText.split(separator: "\n")
        #expect(lines.count == 1)
        let columns = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
        #expect(columns.count == 5)
        #expect(columns[1] == "New Title")
        #expect(columns[2] == "old")
        #expect(columns[3] != "old")
        #expect(columns[4].hasPrefix("Trash:"))
    }

    @Test("a book that has nothing to write, and one that is never attempted, leave no manifest line")
    func onlyAWrittenBookGetsAManifestLine() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/Author/Nameless (1)/Nameless.epub", data: Self.bookWithNoTitle(author: "Some Author"))

        let library = Library(root: libraryRoot)
        let index = try LibraryIndex(inMemory: "epub-write-manifest-nochange-test")
        let bin = try Bin(in: folder.url)
        let bookID = UUID()
        let format = BookFormat(
            bookID: bookID, format: .epub, fileName: "Nameless.epub", byteSize: 1, sha256: "unchanged",
            modifiedAt: Date())
        let entry = LibraryEntry(
            book: Book(id: bookID, title: "Nameless", authors: ["Some Author"]), number: 1,
            folder: "Author/Nameless (1)", formats: [format])
        try await index.save(entry)

        guard case .success(let plan) = EPUBWrite.plan(for: entry, library: library) else {
            Issue.record("expected a plan")
            return
        }
        _ = await EPUBWrite.run(
            [plan], entries: [bookID: entry], library: library, index: index, disposal: bin.disposal)

        #expect(!FileManager.default.fileExists(atPath: EPUBWriteManifest.url(in: library).path))
    }

    @Test("the first failure halts the run — the books after it are never attempted, and are left alone")
    func firstFailureHaltsTheRun() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        // Book "One" has a plan (from a real file) but the entry handed to
        // `run` is for a book ID nothing in `entries` answers to — the same
        // shape "no longer in the library" already covers — so it fails
        // without ever touching a real file.
        _ = try folder.write(
            "library/A/One (1)/book.epub", data: Self.book(title: "Old One", author: "Author One"))
        let originalTwoBytes = Self.book(title: "Old Two", author: "Author Two")
        _ = try folder.write("library/B/Two (1)/book.epub", data: originalTwoBytes)

        let library = Library(root: libraryRoot)
        let index = try LibraryIndex(inMemory: "epub-write-halt-test")
        let bin = try Bin(in: folder.url)

        let idOne = UUID()
        let idTwo = UUID()
        let formatOne = BookFormat(
            bookID: idOne, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old-one", modifiedAt: Date())
        let formatTwo = BookFormat(
            bookID: idTwo, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old-two", modifiedAt: Date())
        let entryOne = LibraryEntry(
            book: Book(id: idOne, title: "New One", authors: ["Author One"]), number: 1, folder: "A/One (1)",
            formats: [formatOne])
        let entryTwo = LibraryEntry(
            book: Book(id: idTwo, title: "New Two", authors: ["Author Two"]), number: 1, folder: "B/Two (1)",
            formats: [formatTwo])
        try await index.save(entryOne)
        try await index.save(entryTwo)

        guard case .success(let planOne) = EPUBWrite.plan(for: entryOne, library: library),
            case .success(let planTwo) = EPUBWrite.plan(for: entryTwo, library: library)
        else {
            Issue.record("expected both to plan")
            return
        }

        // `entries` deliberately omits `idOne` — the exact "vanished from
        // the library mid-run" case `run` already treats as a failure —
        // so the first book fails and the second must never be attempted.
        let report = await EPUBWrite.run(
            [planOne, planTwo], entries: [idTwo: entryTwo], library: library, index: index, disposal: bin.disposal)

        #expect(report.failed == 1)
        #expect(report.notAttempted == 1)
        #expect(report.succeeded == 0)
        guard case .notAttempted = report.outcomes[1].result else {
            Issue.record("expected the second book to be notAttempted, got \(report.outcomes[1].result)")
            return
        }
        // Book Two's file is untouched — never opened, never trashed.
        #expect(bin.taken.isEmpty)
        let untouchedTwo = try Data(contentsOf: libraryRoot.appendingPathComponent("B/Two (1)/book.epub"))
        #expect(untouchedTwo == originalTwoBytes)
        let reloadedTwo = try await index.entries(ids: [idTwo]).first
        #expect(reloadedTwo?.formats.first?.sha256 == "old-two")
    }

    @Test("stopping after this book — book one still writes, book two is left alone and named not attempted")
    func stoppingAfterOneBookLeavesTheNextUntouched() async throws {
        let folder = try TemporaryFolder()
        let libraryRoot = try folder.folder("library")
        _ = try folder.write(
            "library/A/One (1)/book.epub", data: Self.book(title: "Old One", author: "Author One"))
        let originalTwoBytes = Self.book(title: "Old Two", author: "Author Two")
        _ = try folder.write("library/B/Two (1)/book.epub", data: originalTwoBytes)

        let library = Library(root: libraryRoot)
        let index = try LibraryIndex(inMemory: "epub-write-cancel-test")
        let bin = try Bin(in: folder.url)

        let idOne = UUID()
        let idTwo = UUID()
        let formatOne = BookFormat(
            bookID: idOne, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old-one", modifiedAt: Date())
        let formatTwo = BookFormat(
            bookID: idTwo, format: .epub, fileName: "book.epub", byteSize: 1, sha256: "old-two", modifiedAt: Date())
        let entryOne = LibraryEntry(
            book: Book(id: idOne, title: "New One", authors: ["Author One"]), number: 1, folder: "A/One (1)",
            formats: [formatOne])
        let entryTwo = LibraryEntry(
            book: Book(id: idTwo, title: "New Two", authors: ["Author Two"]), number: 1, folder: "B/Two (1)",
            formats: [formatTwo])
        try await index.save(entryOne)
        try await index.save(entryTwo)

        guard case .success(let planOne) = EPUBWrite.plan(for: entryOne, library: library),
            case .success(let planTwo) = EPUBWrite.plan(for: entryTwo, library: library)
        else {
            Issue.record("expected both to plan")
            return
        }

        // A deterministic stand-in for "Nach diesem Buch anhalten" pressed
        // right after book one starts — no real `Task` and no race: `run`
        // asks this closure once per book, and it starts saying yes the
        // moment book one's own progress call has fired.
        let requested = RequestedAfterFirstProgress()
        let report = await EPUBWrite.run(
            [planOne, planTwo], entries: [idOne: entryOne, idTwo: entryTwo], library: library, index: index,
            disposal: bin.disposal, isCancelled: requested.value,
            progress: { _ in requested.noteProgress() })

        #expect(report.succeeded == 1)
        #expect(report.notAttempted == 1)
        guard case .notAttempted = report.outcomes[1].result else {
            Issue.record("expected book two to be notAttempted, got \(report.outcomes[1].result)")
            return
        }
        // Book two's file is untouched — never opened, never trashed.
        let untouchedTwo = try Data(contentsOf: libraryRoot.appendingPathComponent("B/Two (1)/book.epub"))
        #expect(untouchedTwo == originalTwoBytes)
        #expect(bin.taken.count == 1)
    }

    /// `true` from the second call onward — the same shape a "stop after
    /// this book" flag flipped inside book one's own progress callback
    /// would have, without needing a real, racy `Task` to prove it.
    private final class RequestedAfterFirstProgress: @unchecked Sendable {
        private var progressCalls = 0
        func noteProgress() { progressCalls += 1 }
        func value() -> Bool { progressCalls >= 1 }
    }

    // MARK: Fixtures

    /// Collects `run`'s progress callbacks, in the order they arrive — a
    /// class rather than a captured `var`, since the callback is
    /// `@Sendable` and a plain array capture cannot cross that boundary.
    private final class ProgressLog: @unchecked Sendable {
        private(set) var calls: [EPUBWrite.Progress] = []
        func record(_ progress: EPUBWrite.Progress) { calls.append(progress) }
    }

    /// The same disposal double `EPUBFileReplacementTests` uses, so this
    /// suite does not depend on the real Trash either.
    private final class Bin: @unchecked Sendable {
        let folder: URL
        private(set) var taken: [String] = []

        init(in parent: URL) throws {
            folder = parent.appendingPathComponent("write-bin", isDirectory: true)
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

    /// A minimal, valid EPUB with an optional publisher, built through
    /// `EPUBArchiveWriter` itself — the production writer, not a second
    /// implementation. No publisher, language, date or description, on
    /// purpose: those are the four fields Sprint 10 part 2 made insertable,
    /// and this suite's whole point is proving the plan shows that.
    static func book(title: String, author: String, drm: Bool = false) -> Data {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" \
            version="2.0" unique-identifier="id">
              <metadata>
                <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:creator opf:role="aut">\(author)</dc:creator>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        var entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(
                path: "META-INF/container.xml",
                text: """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>\(title)</p></body></html>"),
        ]
        if drm {
            entries.append(.raw(path: "META-INF/encryption.xml", text: "<encryption/>"))
        }
        return (try? EPUBArchiveWriter.archive(entries)) ?? Data()
    }

    /// Two distinct, minimal JPEGs — the same magic-number-plus-padding
    /// shape `EPUBCoverPatchTests` uses, so `CoverFile.fileExtension` reads
    /// both as JPEG and no media-type correction is ever triggered by
    /// these tests by accident.
    static let jpegA = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(0xA0), count: 16))
    static let jpegB = Data([0xFF, 0xD8, 0xFF, 0xE1] + Array(repeating: UInt8(0xB0), count: 24))

    /// A minimal, valid EPUB with a manifest cover — the same declaration
    /// shape `EPUBCoverPatch`'s own case a expects (an EPUB 2 `<meta
    /// name="cover">` alongside the `<item>` it names) — for Sprint 11,
    /// Schritt 3's cover-in-the-plan tests.
    static func bookWithCover(title: String, author: String, coverBytes: Data) -> Data {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" \
            version="2.0" unique-identifier="id">
              <metadata>
                <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:creator opf:role="aut">\(author)</dc:creator>
                <meta name="cover" content="cover-image"/>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(
                path: "META-INF/container.xml",
                text: """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>\(title)</p></body></html>"),
            .raw(path: "OEBPS/cover.jpg", data: coverBytes),
        ]
        return (try? EPUBArchiveWriter.archive(entries)) ?? Data()
    }

    /// A minimal, valid EPUB with a `dc:creator` but no `dc:title` element at
    /// all — `shelf-tool`'s own `noTitleEPUB`, built by hand for the same
    /// reason: `SyntheticEPUB` always writes a title, so the one real case
    /// `EPUBOPFPatch` never invents a title for needs its own fixture.
    static func bookWithNoTitle(author: String) throws -> Data {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" \
            version="2.0" unique-identifier="id">
              <metadata>
                <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:creator opf:role="aut">\(author)</dc:creator>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(
                path: "META-INF/container.xml",
                text: """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>A nameless book.</p></body></html>"),
        ]
        return try EPUBArchiveWriter.archive(entries)
    }

    /// A minimal, valid EPUB whose OPF has neither `<dc:title>` nor
    /// `<dc:creator>` — the file name alone ("Author - Title.epub", the
    /// pattern `FileNameMetadata` reads) is the only thing either could be
    /// guessed from. Built by hand, like `bookWithNoTitle`: `SyntheticEPUB`
    /// always writes both.
    static func bookWithNoTitleAndNoAuthor() throws -> Data {
        let opf = """
            <?xml version='1.0' encoding='utf-8'?>
            <package xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf" \
            version="2.0" unique-identifier="id">
              <metadata>
                <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
              </metadata>
              <manifest>
                <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="text"/></spine>
            </package>
            """
        let entries: [ZipArchiveWriter.Entry] = [
            .raw(path: "mimetype", text: "application/epub+zip"),
            .raw(
                path: "META-INF/container.xml",
                text: """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                      <rootfiles>
                        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                      </rootfiles>
                    </container>
                    """),
            .raw(path: "OEBPS/content.opf", text: opf),
            .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>A nameless, authorless book.</p></body></html>"),
        ]
        return try EPUBArchiveWriter.archive(entries)
    }
}
