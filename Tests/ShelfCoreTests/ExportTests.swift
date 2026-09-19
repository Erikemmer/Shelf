import Foundation
import Testing

@testable import ShelfCore

/// Writing a library out as an ordinary folder of files, and reading it back.
///
/// The point of the whole feature is the *Leitlinie*'s third principle — no
/// lock-in — so the test that matters most is the round trip: what goes out
/// has to come back whole. The rest of these exist because the round trip's
/// failures were all silent until something compared the two halves.
@Suite("Exporting a library, and reading it back")
struct ExportTests {

    private func entry(
        _ title: String, author: String = "Jane Austen", number: Int = 1, tags: [String] = [],
        shelves: [String] = [], isRead: Bool = false, rating: Int = 0
    ) -> LibraryEntry {
        let book = Book(
            title: title, authors: author.isEmpty ? [] : [author], rating: rating, isRead: isRead,
            tags: tags, shelves: shelves)
        let format = BookFormat(
            bookID: book.id, format: .epub, fileName: "\(title).epub", byteSize: 100,
            sha256: "digest-\(title)")
        return LibraryEntry(
            book: book, number: number, folder: "Austen, Jane/\(title) (\(number))",
            formats: [format])
    }

    private let root = URL(fileURLWithPath: "/library")

    // MARK: The name pattern

    /// The defect the round trip found: a token that comes out empty left its
    /// separator behind, and a file with no `metadata.opf` beside it is read
    /// from its *name* — where a leading or doubled separator is exactly what
    /// a name parser trips over.
    @Test("an empty token does not leave its separator behind")
    func emptyTokenLeavesNoSeparator() {
        // A book in no series, with the series in the pattern.
        let loose = entry("Emma")
        #expect(
            NamePattern.name(for: loose, pattern: "{series} - {title}", extension: "epub")
                == "Emma.epub")
        #expect(
            NamePattern.name(for: loose, pattern: "{author} - {series} - {title}", extension: "epub")
                == "Jane Austen - Emma.epub")
        #expect(
            NamePattern.name(for: loose, pattern: "{author} - {title}", extension: "epub")
                == "Jane Austen - Emma.epub")
        #expect(NamePattern.tidied("A -  - B") == "A - B")
        #expect(NamePattern.tidied(" - Emma") == "Emma")

        // A book with no author is still named, because a file name cannot be
        // blank — the same answer a device file name gives.
        let anonymous = entry("Emma", author: "")
        #expect(
            NamePattern.name(for: anonymous, pattern: "{author} - {title}", extension: "epub")
                == "Unknown - Emma.epub")
    }

    @Test("a name is sanitised and cut to the byte limit, like every other name here")
    func namesAreLegal() {
        let long = entry(String(repeating: "📚", count: 300), author: "a/b:c")
        let name = NamePattern.name(for: long, pattern: "{author} - {title}", extension: "epub")
        #expect(name.utf8.count <= BookFolderName.maxComponentBytes)
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test("a pattern with no tokens at all is refused, because every book would share a name")
    func emptyPatternRefused() {
        var options = ExportOptions(namePattern: "book")
        #expect(options.refusal != nil)
        options.namePattern = "{title}"
        #expect(options.refusal == nil)
        // An empty set of formats is not the same as "all".
        #expect(ExportOptions(formats: []).refusal != nil)
        #expect(ExportOptions(formats: nil).refusal == nil)
    }

    // MARK: The presets

    @Test("the three presets differ in exactly what they promise")
    func presets() {
        #expect(ExportPreset.archive.options.includesOPF)
        #expect(ExportPreset.archive.options.includesCover)
        #expect(!ExportPreset.archive.options.mapsShelvesToTags)

        // The one whose dialogue has to say what stays behind.
        #expect(!ExportPreset.booksOnly.options.includesOPF)
        #expect(ExportPreset.booksOnly.explanation.contains("shelves"))

        #expect(ExportPreset.forCalibre.options.mapsShelvesToTags)
        #expect(ExportPreset.forCalibre.options.includesOPF)
        // And each is recognisable again, so the sheet can keep it lit.
        for preset in ExportPreset.allCases {
            #expect(ExportPreset.matching(preset.options) == preset)
        }
    }

    // MARK: The Calibre mapping

    @Test("shelves and the read status become Calibre tags, beside Shelf's own fields")
    func calibreMapping() {
        let book = entry(
            "Emma", tags: ["classic"], shelves: ["Fiction/Sci-Fi", "Work"], isRead: true
        ).book
        let mapped = CalibreTagMapping.mapped(book)
        #expect(mapped.tags == ["Read", "Shelf/Fiction/Sci-Fi", "Shelf/Work", "classic"])
        // Added, never instead of: the book's own tag is still there.
        #expect(mapped.tags.contains("classic"))
        // And the real fields are untouched, so a re-import into Shelf loses
        // nothing and this stays a mapping rather than a substitution.
        #expect(mapped.shelves == book.shelves)
        #expect(mapped.isRead)
        #expect(CalibreTagMapping.isMapped("Shelf/Fiction"))
        #expect(CalibreTagMapping.isMapped("read"))
        #expect(!CalibreTagMapping.isMapped("Shelfie"))
    }

    @Test("an unread book on no shelf gains no tags at all")
    func nothingToMap() {
        let book = entry("Emma", tags: ["classic"]).book
        #expect(CalibreTagMapping.mapped(book).tags == ["classic"])
    }

    // MARK: The plan

    @Test("a second run over an unchanged library writes nothing")
    func incremental() {
        let entries = [entry("Emma", number: 1), entry("Persuasion", number: 2)]
        let options = ExportPreset.archive.options
        let first = ExportPlanner.plan(
            entries: entries, libraryRoot: root, options: options, fileExists: { _ in true },
            coverFile: { _ in nil })
        #expect(first.count(of: .new) == 4)  // two books, two OPFs

        var manifest = ExportManifest(options: options)
        for operation in first.operations {
            manifest.record(
                .init(
                    path: operation.destinationPath, bookID: operation.bookID,
                    sha256: operation.sha256, byteSize: operation.byteSize))
        }

        let second = ExportPlanner.plan(
            entries: entries, libraryRoot: root, options: options, manifest: manifest,
            fileExists: { _ in true }, coverFile: { _ in nil })
        #expect(second.count(of: .unchanged) == 4)
        #expect(second.isEmpty)
        #expect(second.stale.isEmpty)
    }

    /// The second defect the round trip found: a book whose title has changed
    /// has a new file name, and the old file stays at the destination — where
    /// it sorts first, is read first, and wins. A re-import came back with
    /// titles the library had changed weeks before.
    @Test("a file the last run wrote and this one does not want is named as stale")
    func staleFilesAreFound() {
        let options = ExportPreset.archive.options
        let before = ExportPlanner.plan(
            entries: [entry("Ancilary Justice", number: 1)], libraryRoot: root, options: options,
            fileExists: { _ in true }, coverFile: { _ in nil })
        var manifest = ExportManifest(options: options)
        for operation in before.operations {
            manifest.record(
                .init(
                    path: operation.destinationPath, bookID: operation.bookID,
                    sha256: operation.sha256, byteSize: operation.byteSize))
        }

        // The typo is corrected, so both the folder and the file are renamed.
        let after = ExportPlanner.plan(
            entries: [entry("Ancillary Justice", number: 1)], libraryRoot: root, options: options,
            manifest: manifest, fileExists: { _ in true }, coverFile: { _ in nil })
        #expect(after.count(of: .new) == 2)
        #expect(after.stale.count == 2)
        #expect(after.stale.allSatisfy { $0.path.contains("Ancilary") })
    }

    @Test("a manifest written with other options is not believed")
    func optionsChanged() {
        var manifest = ExportManifest(options: ExportPreset.archive.options)
        manifest.record(.init(path: "x", bookID: UUID(), sha256: "a", byteSize: 1))
        let plan = ExportPlanner.plan(
            entries: [entry("Emma")], libraryRoot: root, options: ExportPreset.booksOnly.options,
            manifest: manifest, fileExists: { _ in true }, coverFile: { _ in nil })
        #expect(plan.optionsChanged)
        #expect(plan.count(of: .unchanged) == 0)
    }

    @Test("a flat export keeps two books of one name apart")
    func flatCollision() {
        var options = ExportPreset.archive.options
        options.structure = .flat
        let plan = ExportPlanner.plan(
            entries: [entry("Emma", number: 1), entry("Emma", number: 2)], libraryRoot: root,
            options: options, fileExists: { _ in true }, coverFile: { _ in nil })
        let epubs = plan.operations.filter { $0.kind == .bookFile }.map(\.destinationPath)
        #expect(Set(epubs).count == 2)
        #expect(epubs.contains("Jane Austen - Emma.epub"))
        #expect(epubs.contains("Jane Austen - Emma (2).epub"))
    }

    @Test("a book with none of the chosen formats is left out and named")
    func noChosenFormat() {
        var options = ExportPreset.archive.options
        options.formats = [.pdf]
        let plan = ExportPlanner.plan(
            entries: [entry("Emma")], libraryRoot: root, options: options,
            fileExists: { _ in true }, coverFile: { _ in nil })
        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.first?.reason == .noChosenFormat)
    }

    // MARK: The sidecar

    /// Without this an export is a one-way door: the rating, the read status,
    /// the tags and the shelves live only in the OPF, never in the book file.
    @Test("a metadata.opf beside a book outranks the book's own metadata")
    func sidecarWins() throws {
        let book = Book(
            title: "Emma", authors: ["Jane Austen"], rating: 8, isRead: true,
            tags: ["classic"], shelves: ["Fiction"])
        let parsed = try #require(
            try? OPFDocument.read(Data(OPFDocument.render(book).utf8), fallbackTitle: ""))
        let fromFile = Book(title: "EMMA", authors: ["Somebody Else"])
        let merged = SidecarMetadata.merged(parsed, over: fromFile)

        #expect(merged.id == book.id)
        #expect(merged.title == "Emma")
        #expect(merged.authors == ["Jane Austen"])
        #expect(merged.rating == 8)
        #expect(merged.isRead)
        #expect(merged.shelves == ["Fiction"])
    }

    /// And the defect that came of *not* doing it outright: an empty field in
    /// a record is a statement, not a silence.
    @Test("a book the OPF says has no author does not get one from the file name")
    func emptyIsAStatement() throws {
        let book = Book(title: "Emma", authors: [])
        let parsed = try #require(
            try? OPFDocument.read(Data(OPFDocument.render(book).utf8), fallbackTitle: ""))
        // What a file-name reader would have made of "Emma.epub".
        let guessed = Book(title: "Emma", authors: ["Emma"])
        #expect(SidecarMetadata.merged(parsed, over: guessed).authors.isEmpty)
    }

    /// One `metadata.opf` can speak for two *formats* of one book and must not
    /// speak for a pile of different books, or fifty books would be folded
    /// into one with fifty formats.
    @Test("a shared metadata.opf is believed for one book's formats and not for a pile")
    func sharedOPFIsBelievedCarefully() {
        let oneBook = [URL(fileURLWithPath: "/f/Emma.epub"), URL(fileURLWithPath: "/f/Emma.azw3")]
        #expect(SidecarMetadata.describesTheFolder(oneBook))

        let aPile = [URL(fileURLWithPath: "/f/A.epub"), URL(fileURLWithPath: "/f/B.epub")]
        #expect(!SidecarMetadata.describesTheFolder(aPile))
        #expect(!SidecarMetadata.describesTheFolder([]))
    }

    // MARK: The run

    @Test("the OPF that is written is the very text that was hashed")
    func opfTextIsCarried() throws {
        let plan = ExportPlanner.plan(
            entries: [entry("Emma", shelves: ["Fiction"], isRead: true)], libraryRoot: root,
            options: ExportPreset.forCalibre.options, fileExists: { _ in true },
            coverFile: { _ in nil })
        let opf = try #require(plan.operations.first { $0.kind == .opf })
        let text = try #require(opf.renderedText)
        #expect(text.contains("Shelf/Fiction"))
        #expect(text.contains("<dc:subject>Read</dc:subject>"))
        // The digest recorded is of that string and of nothing else.
        #expect(
            opf.sha256
                == FileDigest.sha256(of: Data(text.utf8), makeHasher: PortableSHA256Hasher.factory))
    }

    @Test("a real export writes the files, verifies them, and can be read back")
    func writesAndVerifies() async throws {
        let temporary = try TemporaryFolder()
        let library = Library(root: try temporary.folder("library"))
        try library.write(LibraryDescriptor(name: "Test"))
        let folder = try temporary.folder("library/Austen, Jane/Emma (1)")
        let payload = Data("a synthetic book".utf8)
        try payload.write(to: folder.appendingPathComponent("Emma.epub"))
        let digest = try FileDigest.sha256(
            of: folder.appendingPathComponent("Emma.epub"), makeHasher: PortableSHA256Hasher.factory)

        let book = Book(title: "Emma", authors: ["Jane Austen"], rating: 8, isRead: true)
        let format = BookFormat(
            bookID: book.id, format: .epub, fileName: "Emma.epub",
            byteSize: Int64(payload.count), sha256: digest)
        let entry = LibraryEntry(
            book: book, number: 1, folder: "Austen, Jane/Emma (1)", formats: [format])

        let destination = try temporary.folder("out")
        let plan = ExportPlanner.plan(
            entries: [entry], libraryRoot: library.root, options: ExportPreset.archive.options,
            coverFile: { _ in nil })
        let outcome = try await ExportRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(destination: destination, plan: plan, libraryName: "Test"))

        #expect(outcome.report.failures.isEmpty)
        #expect(temporary.exists("out/Austen, Jane/Emma (1)/Jane Austen - Emma.epub"))
        #expect(temporary.exists("out/Austen, Jane/Emma (1)/metadata.opf"))
        // The bytes arrived.
        let written = try Data(
            contentsOf: destination.appendingPathComponent(
                "Austen, Jane/Emma (1)/Jane Austen - Emma.epub"))
        #expect(written == payload)
        // The report is at the destination and says what was left out.
        #expect(temporary.exists("out/\(ExportReport.fileName)"))
        // And the manifest is there, so the next run knows.
        #expect(!ExportManifest.read(at: destination).isEmpty)
    }

    @Test("the books-only report says in as many words what is not in the folder")
    func theHonestSentence() {
        let report = ExportReport(
            libraryName: "L", destination: URL(fileURLWithPath: "/x"), startedAt: Date(),
            duration: 1, written: [], unchanged: 0, skipped: [], failures: [], copiedBytes: 0,
            hardLinkCount: 0, options: ExportPreset.booksOnly.options)
        let text = report.rendered()
        #expect(text.contains("NOT in this export"))
        #expect(text.contains("the rating, the read status, the tags and the shelves"))
    }
}
