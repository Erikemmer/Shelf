import Foundation
import ShelfCore

/// Command-line proof that the library, the EPUB reader and the importer agree
/// with the file system – before there is any window to click.
///
/// It is not a product; it is how a claim gets checked. `synthesise` builds the
/// library the performance run measures against, `import` really imports it
/// with SHA-256 verification, and `rebuild` throws the index away and rebuilds
/// it from the folders, which is the proof behind ADR 0001.
///
/// It uses `PortableSHA256Hasher`, so it runs on Linux too and its digests can
/// be compared with `/usr/bin/shasum` – a tool that knows nothing about this
/// code.

let usage = """
    shelf-tool – proof runs for ShelfCore

      synthesise <folder> [count]   write <count> synthetic EPUBs with real covers
      import <source> <library>     import a folder into a library, verified
      rebuild <library>             erase the index and rebuild it from the folders
      digest <file>                 SHA-256 of one file, to compare with shasum

    Test material belongs under ~/Library/Caches/Shelf, never under ~/Documents.
    """

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "synthesise": try Commands.synthesise(Array(arguments.dropFirst()))
case "import": try await Commands.importFolder(Array(arguments.dropFirst()))
case "rebuild": try await Commands.rebuild(Array(arguments.dropFirst()))
case "digest": try Commands.digest(Array(arguments.dropFirst()))
default:
    print(usage)
    exit(2)
}

/// The commands, in a type rather than as top-level functions: top-level code
/// runs in order, and a function used before its declaration is a rule nobody
/// should have to remember while reading this file.
enum Commands {

    // MARK: synthesise

    /// Writes `count` EPUBs into `folder`.
    ///
    /// Deliberately varied rather than uniform, because the things that break
    /// at 5 000 books are the odd ones: names that need sanitising, missing
    /// authors, series with half indexes, very long titles, repeated ISBNs and
    /// a few books with no cover at all.
    static func synthesise(_ arguments: [String]) throws {
        guard let folder = arguments.first else {
            print("usage: shelf-tool synthesise <folder> [count]")
            exit(2)
        }
        let count = arguments.count > 1 ? Int(arguments[1]) ?? 5_000 : 5_000
        let root = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A fixed seed, so two runs of the proof produce the same library and
        // two measurements are comparable.
        var random = SeededGenerator(seed: 20_260_916)
        let started = Date()
        var bytes: Int64 = 0

        for index in 0..<count {
            let book = SyntheticBooks.make(index: index, using: &random)
            let cover = SyntheticBooks.cover(index: index, using: &random)
            let epub = SyntheticEPUB(book: book, cover: cover).data()
            let stem =
                "\(BookFolderName.sanitised(book.title, fallback: "Untitled")) - "
                + "\(BookFolderName.sanitised(book.primaryAuthor, fallback: Book.unknownAuthor))"
            let name = "\(BookFolderName.truncated(stem, toBytes: 240)).epub"
            try epub.write(to: root.appendingPathComponent(name))
            bytes += Int64(epub.count)
            if (index + 1) % 500 == 0 {
                print("  \(index + 1) / \(count) · \(ByteCount.format(bytes))")
            }
        }
        print(
            "synthesised \(count) EPUBs · \(ByteCount.format(bytes)) · "
                + "\(ImportReport.duration(Date().timeIntervalSince(started))) · \(root.path)")
    }

    // MARK: import

    static func importFolder(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool import <source folder> <library folder>")
            exit(2)
        }
        let source = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true)
        let libraryURL = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)

        let (library, stored) = try openOrCreate(libraryURL)
        var descriptor = stored
        let index = try LibraryIndex(library: library)

        // MARK: Read the source
        let readStarted = Date()
        let files = try FileManager.default
            .contentsOfDirectory(
                at: source, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
            )
            .filter { BookFileFormat.of($0) != nil }
            .sorted { $0.path < $1.path }
        print("reading \(files.count) files from \(source.path)")

        var candidates: [ImportCandidate] = []
        for (number, url) in files.enumerated() {
            guard let candidate = try readCandidate(url) else { continue }
            candidates.append(candidate)
            if (number + 1) % 1_000 == 0 { print("  read \(number + 1) / \(files.count)") }
        }
        print("read in \(ImportReport.duration(Date().timeIntervalSince(readStarted)))")

        // MARK: Plan
        let knowledge = ImportKnowledge(
            digests: try await index.allFormatDigests(),
            isbns: try await index.allISBNs(),
            titleKeys: try await index.allTitleKeys(),
            formatsByBook: try await formatsByBook(index))
        let plan = ImportPlanner.plan(
            candidates: candidates, knowledge: knowledge, startingNumber: descriptor.nextBookNumber,
            existingFolders: existingFolders(library))
        print("plan: \(plan.summary())")

        // MARK: Run
        let runner = ImportRunner(makeHasher: PortableSHA256Hasher.factory)
        let copyStarted = Date()
        let outcome = try await runner.run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: source.path)
        ) { progress in
            if progress.filesDone > 0, progress.filesDone % 1_000 == 0 {
                print("  copied \(progress.filesDone) / \(progress.filesTotal)")
            }
        }
        print("copied and verified in \(ImportReport.duration(Date().timeIntervalSince(copyStarted)))")

        let indexStarted = Date()
        // In batches: one transaction for 5 000 books holds a lot of memory,
        // and one per book would be 5 000 fsyncs.
        for batch in outcome.entries.chunked(into: 500) {
            try await index.save(batch)
        }
        print("indexed in \(ImportReport.duration(Date().timeIntervalSince(indexStarted)))")

        descriptor.nextBookNumber = outcome.nextBookNumber
        try library.write(descriptor)
        try outcome.report.append(to: library)

        print("")
        print(outcome.report.rendered())
        print("index holds \(try await index.count()) books")
        if !outcome.report.everythingVerified { exit(1) }
    }

    // MARK: rebuild

    /// Throws the index away and rebuilds it from the folders.
    ///
    /// The proof behind ADR 0001. It prints the counts before and after,
    /// because "the folder is the truth" is a claim about numbers.
    static func rebuild(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool rebuild <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, stored) = try Library.open(libraryURL)
        var descriptor = stored
        let index = try LibraryIndex(library: library)

        let before = try await index.count()
        let digests = try await knownDigests(index)
        print("index holds \(before) books; rebuilding from \(library.root.path)")

        let started = Date()
        let rebuilder = IndexRebuilder(makeHasher: PortableSHA256Hasher.factory)
        let result = try rebuilder.rebuild(library, knownDigests: digests) { scanned, folder in
            if scanned % 1_000 == 0 { print("  \(scanned) · \(folder)") }
        }

        try await index.eraseAll()
        for batch in result.entries.chunked(into: 500) {
            try await index.save(batch)
        }
        descriptor.nextBookNumber = max(descriptor.nextBookNumber, result.highestNumber + 1)
        try library.write(descriptor)

        let after = try await index.count()
        print("")
        print("rebuilt in \(ImportReport.duration(Date().timeIntervalSince(started)))")
        print("  before: \(before) books")
        print("  after:  \(after) books")
        print("  folders with no readable book: \(result.unreadableFolders.count)")
        print("  books whose metadata came from the file rather than an OPF: \(result.withoutOPF.count)")
        for folder in result.unreadableFolders.prefix(10) { print("    \(folder)") }
        guard before == after else {
            print("MISMATCH – the index and the folders disagree")
            exit(1)
        }
        print("index and folders agree")
    }

    // MARK: digest

    static func digest(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool digest <file>")
            exit(2)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        print(try FileDigest.sha256(of: url, makeHasher: PortableSHA256Hasher.factory))
    }

    // MARK: Helpers

    /// Reads one file into a candidate: metadata, cover and digest.
    static func readCandidate(_ url: URL) throws -> ImportCandidate? {
        guard let format = BookFileFormat.of(url) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes[.size] as? Int64) ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let digest = try FileDigest.sha256(of: url, makeHasher: PortableSHA256Hasher.factory)

        if format.hasReadableMetadata, let read = try? EPUBMetadata.read(url: url) {
            return ImportCandidate(
                source: url, byteSize: byteSize, format: format, sha256: digest, book: read.book,
                cover: read.cover, coverName: read.coverName, drm: read.drm, modifiedAt: modified,
                warnings: read.warnings)
        }
        // Everything else imports by file name in Sprint 1 (CONCEPT §6).
        let stem = url.deletingPathExtension().lastPathComponent
        let book = Book(title: FileNameMetadata.title(from: stem), authors: FileNameMetadata.authors(from: stem))
        return ImportCandidate(
            source: url, byteSize: byteSize, format: format, sha256: digest, book: book, modifiedAt: modified,
            warnings: ["metadata from the file name – \(format.rawValue.uppercased()) is read in Sprint 4"])
    }

    static func openOrCreate(_ url: URL) throws -> (Library, LibraryDescriptor) {
        if Library.isLibrary(url) { return try Library.open(url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try Library.create(at: url)
    }

    static func existingFolders(_ library: Library) -> Set<String> {
        let manager = FileManager.default
        guard let authors = try? manager.contentsOfDirectory(atPath: library.root.path) else { return [] }
        var result: Set<String> = []
        for author in authors where author != Library.privateFolderName {
            let authorURL = library.root.appendingPathComponent(author)
            guard authorURL.hasDirectoryPath,
                let books = try? manager.contentsOfDirectory(atPath: authorURL.path)
            else { continue }
            for book in books { result.insert("\(author)/\(book)") }
        }
        return result
    }

    static func formatsByBook(_ index: LibraryIndex) async throws -> [UUID: Set<BookFileFormat>] {
        var result: [UUID: Set<BookFileFormat>] = [:]
        for entry in try await index.allEntries() {
            result[entry.id] = Set(entry.formats.map(\.format))
        }
        return result
    }

    static func knownDigests(_ index: LibraryIndex) async throws -> [String: String] {
        var result: [String: String] = [:]
        for entry in try await index.allEntries() {
            for format in entry.formats {
                let key = IndexRebuilder.digestKey(
                    folder: entry.folder, fileName: format.fileName, byteSize: format.byteSize,
                    modifiedAt: format.modifiedAt)
                result[key] = format.sha256
            }
        }
        return result
    }
}

extension Array {
    /// Splits the array into runs of at most `size`, for writing the index in
    /// transactions that are neither one per book nor one for all of them.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// A reproducible pseudo-random generator.
///
/// The system generator would make every synthetic library different, and two
/// performance measurements would then not be comparable. This is xorshift64*,
/// which is not cryptographic and does not need to be – it makes test data.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x2545_F491_4F6C_DD1D : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

/// The synthetic library's content.
enum SyntheticBooks {
    static let firstNames = [
        "Jane", "Ursula", "Iain", "Octavia", "Terry", "Neil", "Margaret", "Kim", "Ann", "Becky",
        "Arkady", "N. K.", "Martha", "Adrian", "Emily", "Tamsyn", "Susanna", "José", "Ólafur", "Étienne",
    ]
    static let lastNames = [
        "Austen", "Le Guin", "Banks", "Butler", "Pratchett", "Gaiman", "Atwood", "Stanley Robinson",
        "Leckie", "Chambers", "Martine", "Jemisin", "Wells", "Tchaikovsky", "St. John Mandel",
        "Muir", "Clarke", "Saramago", "Ólafsdóttir", "Lefèvre",
    ]
    static let titleHeads = [
        "The Left Hand", "A Memory", "The Long Way", "Ancillary", "The Fifth", "The City", "Station",
        "Gideon", "Piranesi", "Children", "The Player", "Use of", "The Dispossessed", "Small",
        "The Handmaid's", "Red", "Blindness", "The Ministry", "Translation", "A Desolation",
    ]
    static let titleTails = [
        "of Darkness", "Called Empire", "to a Small, Angry Planet", "Justice", "Season", "We Became",
        "Eleven", "the Ninth", "", "of Time", "of Games", "Weapons", "", "Gods", "Tale", "Mars",
        "", "for the Future", "State", "Called Peace",
    ]
    static let seriesNames = [
        "Hainish Cycle", "Culture", "Imperial Radch", "Broken Earth", "Teixcalaan", "Wayfarers",
        "Discworld", "Locked Tomb", "Mars Trilogy", "Children of Time",
    ]
    static let tagPool = [
        "science fiction", "fantasy", "literary", "classics", "space opera", "dystopia",
        "translated", "award winner", "to read", "favourites", "book club", "non-fiction",
    ]
    static let publishers = ["Gollancz", "Orbit", "Tor", "Penguin", "Suhrkamp", "Hodder", "Head of Zeus"]

    /// One synthetic book.
    ///
    /// The awkward cases are mixed in by index rather than at random, so a
    /// given index always produces the same awkwardness and a failing case can
    /// be reproduced by number.
    static func make(index: Int, using random: inout SeededGenerator) -> Book {
        let head = titleHeads[Int(random.next() % UInt64(titleHeads.count))]
        let tail = titleTails[Int(random.next() % UInt64(titleTails.count))]
        var title = tail.isEmpty ? head : "\(head) \(tail)"
        // Every hundredth title is absurdly long, and every 250th needs
        // sanitising – both are things a real library contains.
        if index % 100 == 0 { title += " " + String(repeating: "and the Very Long Subtitle ", count: 12) }
        if index % 250 == 0 { title = "Vol. 1/2: \(title) <Special Edition>" }
        title += " #\(index)"

        let author =
            "\(firstNames[Int(random.next() % UInt64(firstNames.count))]) "
            + "\(lastNames[Int(random.next() % UInt64(lastNames.count))])"

        var tags: [String] = []
        for _ in 0..<(1 + Int(random.next() % 3)) {
            let tag = tagPool[Int(random.next() % UInt64(tagPool.count))]
            if !tags.contains(tag) { tags.append(tag) }
        }

        var identifiers: [String: String] = [:]
        // Every third book has an ISBN, and every 500th repeats an earlier one
        // so the duplicate check has something to find.
        if index % 3 == 0 {
            let serial = index % 500 == 0 ? 1_000 : index
            identifiers["isbn"] = "978" + String(format: "%010d", serial)
        }

        let series: SeriesRef? =
            index % 4 == 0
            ? SeriesRef(
                name: seriesNames[Int(random.next() % UInt64(seriesNames.count))],
                // Half indexes, because novellas have them.
                index: Double(1 + index % 9) + (index % 8 == 0 ? 0.5 : 0))
            : nil

        return Book(
            title: title,
            // Every 200th book has no author at all.
            authors: index % 200 == 0 ? [] : [author],
            series: series,
            rating: Int(random.next() % 6),
            isRead: index % 3 == 1,
            publisher: publishers[Int(random.next() % UInt64(publishers.count))],
            published: Date(timeIntervalSince1970: Double(random.next() % 1_700_000_000)),
            language: index % 10 == 0 ? "de" : "en",
            description: "Synthetic book number \(index), for measuring how Shelf behaves with many of them.",
            tags: tags,
            identifiers: identifiers)
    }

    /// A cover that is a real, decodable image of roughly the size a real cover
    /// is – so the app's pipeline does the work it will really do.
    ///
    /// Every fiftieth book has none, which is what the "Missing Cover"
    /// collection is for.
    static func cover(index: Int, using random: inout SeededGenerator) -> Data? {
        guard index % 50 != 0 else { return nil }
        return MinimalPNG.cover(seed: UInt8(random.next() % 200))
    }
}
