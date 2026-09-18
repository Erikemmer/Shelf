import Foundation
import ShelfCore

// `statfs`, and the only thing in this tool that is not portable. The tool is a
// target of the same package as `ShelfCore`, so `swift build` on Linux builds it
// too, and an unconditional `import Darwin` breaks that build. It did break it,
// from Sprint 5 until a container was used to notice: the CI job that exists to
// catch exactly this has not been able to start since Sprint 4, because GitHub
// Actions is blocked on the account's billing.
#if canImport(Darwin)
    import Darwin
#endif

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
      synthesise-mixed <folder> [count per format]
                                    write <count> each of EPUB, MOBI, AZW3, PDF
                                    and CBZ, plus DRM-marked and deliberately
                                    broken files. No CBR: nothing here can write
                                    a RAR
      import <source> <library>     import a folder into a library, verified
      calibre-synthesise <folder> [count]
                                    write a synthetic Calibre library – the
                                    folder layout and metadata.db Calibre has
      calibre-dry <calibre folder> [destination]
                                    read a Calibre library and print the
                                    counting protocol – nothing is written
      calibre-import <calibre folder> <library>
                                    import a Calibre library, verified. The
                                    Calibre folder is only ever read
      orphans <library>             list the folders no book points at – what a
                                    killed import leaves behind. Reads only
      duplicates <library>          list what the Duplicates collection shows,
                                    and which of the three rules found each
                                    one. Reads only
      rebuild <library>             erase the index and rebuild it from the folders
      shelve <library> <path> <count> [offset]
                                    put <count> books on the shelf at <path>,
                                    making the shelf if it is not there, and
                                    print how long one assignment takes
      unshelve <library>            remove every shelf and take every book off
                                    it – writes each metadata.opf, never a book
      edit <library> <title> <stars> <read>
                                    set one book's rating (0–5) and read status
                                    (yes/no) – writes metadata.opf, never the book
      show <library> <title>        print what the index holds about one book
      digest <file>                 SHA-256 of one file, to compare with shasum
      online-read <file>…           read stored answers from Open Library or
                                    Google Books the way the app does, and print
                                    the candidates with their match scores.
                                    Reads files, never the network — the network
                                    belongs to Scripts/online-proof.sh

    Devices (Sprint 5). Everything here works on a mounted volume, which in the
    proof run is a disk image made by `Scripts/device-images.sh` – so the whole
    of it can be measured without four e-readers on the desk.

      devices                       every mounted volume and which device
                                    profile, if any, it matches. Reads only
      device-contents <volume> [library]
                                    the book files on the volume, matched to the
                                    library's books where one is given
      send <library> <volume> [count]
                                    send the first <count> books to the volume:
                                    the plan, then the copy with SHA-256 read
                                    back off the device, then the report
      device-delete <volume> <path>…
                                    print the confirmation that names every file
                                    and, only with SHELF_CONFIRM_DELETE=yes,
                                    carry it out
      kobo-synthesise <volume> [count]
                                    write a synthetic KoboReader.sqlite naming
                                    the books already on the volume
      kobo-read <volume>            reading positions, shelves and read status,
                                    through a copy. Never writes

    The Sprint 2b proof run (Scripts/proof-run.sh section 7) uses these four.
    They all address "the first <count> books by book number", which is a stable
    order: the number is in the folder name and no edit changes it, where title
    order moves the moment a title is edited.

      bulk-tag-undo <library> <count> <tag>
                                    add a tag to <count> books as one undo
                                    group, undo it, and check that every OPF is
                                    byte for byte what it was and every EPUB
                                    untouched
      bulk-edit <library> <count>   change the title, tags and description of
                                    <count> books, one write each, and print how
                                    long a change takes including the search index
      epub-digests <library> <count>
                                    SHA-256 of each of those books' EPUBs
      search-time <library> <query> [rounds]
                                    how long a search takes over the whole library
      verify-edits <library> <count>
                                    whether every one of those changes is still
                                    there – run it after a rebuild

    SHELF_EXIT_AFTER=<n> makes `import` and `send` leave the process after n
    files, the way a crash does – it is how the proof run produces an
    interrupted import and an interrupted transfer.

    Test material belongs under ~/Library/Caches/Shelf, never under ~/Documents.
    """

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "synthesise": try Commands.synthesise(Array(arguments.dropFirst()))
case "synthesise-mixed": try Commands.synthesiseMixed(Array(arguments.dropFirst()))
case "import": try await Commands.importFolder(Array(arguments.dropFirst()))
case "calibre-synthesise": try Commands.calibreSynthesise(Array(arguments.dropFirst()))
case "calibre-dry": try Commands.calibreDry(Array(arguments.dropFirst()))
case "calibre-import": try await Commands.calibreImport(Array(arguments.dropFirst()))
case "orphans": try await Commands.orphans(Array(arguments.dropFirst()))
case "duplicates": try await Commands.duplicates(Array(arguments.dropFirst()))
case "rebuild": try await Commands.rebuild(Array(arguments.dropFirst()))
case "unshelve": try await Commands.unshelve(Array(arguments.dropFirst()))
case "shelve": try await Commands.shelve(Array(arguments.dropFirst()))
case "edit": try await Commands.edit(Array(arguments.dropFirst()))
case "show": try await Commands.show(Array(arguments.dropFirst()))
case "digest": try Commands.digest(Array(arguments.dropFirst()))
case "online-read": try Commands.onlineRead(Array(arguments.dropFirst()))
case "devices": Commands.devices()
case "device-contents": try await Commands.deviceContents(Array(arguments.dropFirst()))
case "send": try await Commands.send(Array(arguments.dropFirst()))
case "device-delete": Commands.deviceDelete(Array(arguments.dropFirst()))
case "kobo-synthesise": try Commands.koboSynthesise(Array(arguments.dropFirst()))
case "kobo-read": try Commands.koboRead(Array(arguments.dropFirst()))
case "bulk-edit": try await Commands.bulkEdit(Array(arguments.dropFirst()))
case "bulk-tag-undo": try await Commands.bulkTagUndo(Array(arguments.dropFirst()))
case "epub-digests": try await Commands.epubDigests(Array(arguments.dropFirst()))
case "search-time": try await Commands.searchTime(Array(arguments.dropFirst()))
case "verify-edits": try await Commands.verifyEdits(Array(arguments.dropFirst()))
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

    // MARK: synthesise-mixed

    /// Writes a folder holding every format Shelf reads, for the Sprint 4
    /// proof run.
    ///
    /// `count` of each of EPUB, MOBI, AZW3, PDF and CBZ, and on top of those, of
    /// each format, three files announcing DRM and three that are deliberately
    /// broken — truncated, or the right name over the wrong bytes. The broken
    /// ones are the point as much as the good ones: CONCEPT §13 says a bad file
    /// must never stop an import, and a run that only ever sees good files
    /// cannot show that.
    ///
    /// **CBR is not written**, and that is not an oversight. A RAR is a
    /// proprietary compressed format and this Mac has no tool that can make
    /// one; writing a fake would test the fallback rather than the reader. The
    /// command says so on its way past, so nobody reads a proof run and assumes
    /// CBR was covered.
    static func synthesiseMixed(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool synthesise-mixed <folder> [count per format]")
            exit(2)
        }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let count = arguments.count > 1 ? (Int(arguments[1]) ?? 500) : 500
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The same fixed seed the plain generator uses, so two runs produce the
        // same library and two measurements can be compared.
        var random = SeededGenerator(seed: 20_260_918)
        let started = Date()
        var written: [String: Int] = [:]
        var bytes: Int64 = 0

        func write(_ name: String, _ data: Data, as kind: String) throws {
            try data.write(to: root.appendingPathComponent(name))
            written[kind, default: 0] += 1
            bytes += Int64(data.count)
        }

        func stem(_ book: Book) -> String {
            let raw =
                "\(BookFolderName.sanitised(book.title, fallback: "Untitled")) - "
                + "\(BookFolderName.sanitised(book.primaryAuthor, fallback: Book.unknownAuthor))"
            return BookFolderName.truncated(raw, toBytes: 200)
        }

        for index in 0..<count {
            let book = SyntheticBooks.make(index: index, using: &random)
            let cover = SyntheticBooks.cover(index: index, using: &random)
            let name = stem(book)

            // One stem, four extensions — what a folder of downloads actually
            // looks like, and what the planner's sibling rule is for. The
            // ` M` and ` A` the first version put on the MOBI and the AZW3
            // were not needed (the extensions already differ) and they made
            // the fixture unlike the case being measured.
            try write("\(name).epub", SyntheticEPUB(book: book, cover: cover).data(), as: "epub")
            try write("\(name).mobi", SyntheticMobi(book: book, cover: cover).data(), as: "mobi")
            try write("\(name).azw3", SyntheticMobi(book: book, cover: cover, isAZW3: true).data(), as: "azw3")
            try write("\(name).pdf", SyntheticPDF(book: book).data(), as: "pdf")
            // A comic is named the way a comic is named — the file name is the
            // only metadata most of them have.
            //
            // The issue number lands after a title that already ends with
            // `#index`, so the name carries the number twice. That is kept on
            // purpose: it is exactly the shape that made the Sprint 4
            // screenshot show "A Desolation #164 164" beside
            // "A Desolation #164", and a proof run over it is what shows the
            // rule in `ComicFileName.title(series:number:)` working.
            //
            // The issue number is the index and **not** `index % 300`, which is
            // what it was first: that made two different books into the same
            // `Series 032`, the importer rightly called 308 of them duplicates
            // of each other, and the run measured the duplicate check instead of
            // the comic reader. A fixture that collides with itself measures the
            // wrong thing.
            let comicName =
                "\(BookFolderName.sanitised(book.title, fallback: "Comic")) \(String(format: "%03d", index)) (20\(10 + index % 15))"
            try write(
                "\(BookFolderName.truncated(comicName, toBytes: 200)).cbz",
                SyntheticComic(
                    seed: UInt8(index % 200), pageWidth: 8 + index % 37, pageHeight: 12 + index % 41
                ).data(), as: "cbz")

            if (index + 1) % 100 == 0 {
                print("  \(index + 1) / \(count) of each · \(ByteCount.format(bytes))")
            }
        }

        // ── Three protected files per format that can carry the announcement ──
        //
        // Announced, not encrypted. Shelf's whole claim about DRM is that it
        // reads the flag and stops, so a fixture that were really encrypted
        // would test nothing further — and would be a thing this repository
        // should not hold (ADR 0012).
        for index in 0..<3 {
            // A person, not a publisher. The first version called this author
            // "A Publisher", and the Sprint 4 screenshot then showed a
            // publisher standing in the sidebar's *Authors* list — a picture
            // of the fixture rather than of the app. The publisher goes where
            // a publisher goes.
            var book = Book(title: "Protected Book \(index)", authors: ["Ada Mercer"])
            book.publisher = "Head of Zeus"
            let name = stem(book)
            try write("\(name).mobi", SyntheticMobi(book: book, withKindleDRM: true).data(), as: "mobi (DRM)")
            try write(
                "\(name).azw3", SyntheticMobi(book: book, isAZW3: true, withKindleDRM: true).data(),
                as: "azw3 (DRM)")
            try write(
                "\(name).epub", SyntheticEPUB.withAdobeDRM(book: book).data(), as: "epub (DRM)")
        }

        // ── Three broken files per format ────────────────────────────────────
        //
        // Two kinds, because they fail differently: a truncated file stops
        // part-way through a structure the reader is walking, and the right
        // name over the wrong bytes fails at the first check. Both have to end
        // as a book named after its file, with a line in the report.
        for index in 0..<3 {
            let book = Book(title: "Broken Book \(index)", authors: ["Nobody"])
            let name = stem(book)
            let good = SyntheticEPUB(book: book).data()

            // Each one carries its own index in its bytes. Without that the
            // three "wrong bytes" files were byte-for-byte identical, the
            // importer skipped two of them as duplicates of the first — which
            // is correct and which meant only one of the three ever reached the
            // reader.
            let marker = Data("broken fixture \(index)\n".utf8)

            try write("\(name) truncated.epub", good.prefix(good.count / 3) + marker, as: "broken")
            try write("\(name) wrong bytes.mobi", Data("this is not a MOBI at all".utf8) + marker, as: "broken")
            try write(
                "\(name) truncated.azw3", SyntheticMobi(book: book, isAZW3: true).data().prefix(50) + marker,
                as: "broken")
            try write("\(name) nearly empty.pdf", marker, as: "broken")
            try write("\(name) wrong bytes.cbz", Data("not a zip".utf8) + marker, as: "broken")
            // A KFX, which nothing can read and which must still be carried.
            try write(
                "\(name).kfx", Data("CONT".utf8) + marker + Data([UInt8](repeating: 0, count: 64)), as: "kfx")
        }

        print("")
        for kind in written.keys.sorted() {
            print("  \(kind): \(written[kind] ?? 0)")
        }
        print(
            "synthesised \(written.values.reduce(0, +)) files · \(ByteCount.format(bytes)) · "
                + "\(ImportReport.duration(Date().timeIntervalSince(started))) · \(root.path)")
        print("")
        print("NOT written: CBR. A RAR is a proprietary compressed format and this Mac has no")
        print("tool that can make one, so no genuine .cbr was generated and none was measured.")
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

        // MARK: Take back what a killed run left
        //
        // The same step `ImportModel.reclaimOrphans` does, and here for the
        // same reason: without it a run that died between two index writes
        // leaves folders nothing points at, and this run plans those books
        // again and copies them into second folders.
        let known = Set(try await index.allEntries().map(\.folder))
        let orphans = OrphanedFolders.find(in: library, knownFolders: known)
        var reclaimed: [String] = []
        var leftOver: [OrphanedFolder] = []
        if !orphans.isEmpty {
            let claimed = OrphanedFolders.claimable(orphans, importing: Set(candidates.map(\.book.id)))
            let adopted = OrphanedFolders.adopt(claimed, in: library, makeHasher: PortableSHA256Hasher.factory)
            try await index.save(adopted)
            let taken = Set(adopted.map(\.folder))
            reclaimed = adopted.map(\.folder).sorted()
            leftOver = orphans.filter { !taken.contains($0.path) }
            print(
                "orphaned folders found: \(orphans.count) – "
                    + "\(reclaimed.count) taken back, \(leftOver.count) left for the user")
        }

        // MARK: Plan
        let knowledge = ImportKnowledge(
            digests: try await index.allFormatDigests(),
            isbns: try await index.allISBNs(),
            titleKeys: try await index.allTitleKeys(),
            formatsByBook: try await formatsByBook(index),
            foldersByBook: try await foldersByBook(index))
        // The stored counter, or the highest number already on the disk if a
        // killed run got further than the descriptor did. It never goes
        // backwards, so a deleted book's number is still not reused.
        let plainStart = max(descriptor.nextBookNumber, try await index.highestBookNumber() + 1)
        let plan = ImportPlanner.plan(
            candidates: candidates, knowledge: knowledge, startingNumber: plainStart,
            existingFolders: existingFolders(library))
        print("plan: \(plan.summary())")

        // What the library already holds for each book a format is being
        // added to. Without it the runner writes an entry holding only the new
        // file and the index forgets the ones already there.
        var collectedKnownentries: [UUID: LibraryEntry] = [:]
        for operation in plan.operations {
            guard case .addFormat(let add) = operation, collectedKnownentries[add.bookID] == nil else { continue }
            collectedKnownentries[add.bookID] = try await index.entry(id: add.bookID)
        }

        // `let`, so the runner's `@Sendable` closure captures a value rather
        // than a variable it could race with.
        let knownEntries = collectedKnownentries

        // MARK: Run
        let runner = ImportRunner(makeHasher: PortableSHA256Hasher.factory)
        let copyStarted = Date()
        // In batches, and *while the run goes on*: one transaction for 5 000
        // books holds a lot of memory, one per book would be 5 000 fsyncs, and
        // an index written only at the end leaves an interrupted run's files
        // invisible to the next one.
        let outcome = try await runner.run(
            ImportRunner.Options(library: library, plan: plan, sourceDescription: source.path),
            progress: { progress in
                if progress.filesDone > 0, progress.filesDone % 1_000 == 0 {
                    print("  copied \(progress.filesDone) / \(progress.filesTotal)")
                }
                // For the proof run: die in the middle, the way a crash or a
                // SIGKILL does. `exit` and not `cancel`, on purpose —
                // cancelling is the *tidy* path and still writes the short last
                // batch, so it leaves no orphans and would prove nothing. This
                // is the untidy one, which is the case that produced 23 folders
                // nothing pointed at.
                if let after = ProcessInfo.processInfo.environment["SHELF_EXIT_AFTER"].flatMap(Int.init),
                    progress.filesDone >= after
                {
                    print("SHELF_EXIT_AFTER=\(after) – leaving the process now, mid-run")
                    exit(9)
                }
            },
            saveBatch: { try await index.save($0) },
            existingEntry: { knownEntries[$0] })
        print("copied, verified and indexed in \(ImportReport.duration(Date().timeIntervalSince(copyStarted)))")

        descriptor.nextBookNumber = outcome.nextBookNumber
        try library.write(descriptor)
        var report = outcome.report
        report.reclaimedFolders = reclaimed
        report.orphanedFolders = leftOver.map(\.path)
        try report.append(to: library)

        print("")
        print(report.rendered())
        print("index holds \(try await index.count()) books")
        if !outcome.report.everythingVerified { exit(1) }
    }

    /// Lists the folders in a library that no book points at. Reads only.
    ///
    /// The command line half of `Library ▸ Find Orphaned Folders…`, and it
    /// stops at listing: moving anything to the Trash needs a person looking at
    /// a list of file names, which is a window's job.
    static func orphans(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool orphans <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, _) = try Library.open(libraryURL)
        let index = try LibraryIndex(library: library)
        let known = Set(try await index.allEntries().map(\.folder))
        let found = OrphanedFolders.find(in: library, knownFolders: known)

        print("books in the index: \(known.count)")
        print("orphaned folders: \(found.count)")
        for folder in found {
            print("  \(folder.path)")
            print("    \(folder.summary)")
            for file in folder.files { print("      \(file)") }
        }
        if found.isEmpty { print("  (every folder in the library belongs to a book)") }
    }

    /// What the *Duplicates* collection holds, from the command line.
    ///
    /// The sidebar shows a number and the inspector shows one line; this prints
    /// the whole list with the rule that found each book, which is what a proof
    /// run needs and what the Sprint 4 screenshot had no way of showing.
    static func duplicates(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool duplicates <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, _) = try Library.open(libraryURL)
        let index = try LibraryIndex(library: library)
        let found = try await index.duplicates()
        let groups = DuplicateGroups(reasons: found)
        let entries = try await index.allEntries()

        // The two numbers the sidebar shows, said apart: a byte-for-byte match
        // and a shared title are not the same claim, and a single total made
        // the second one drown the first.
        print(
            "books: \(entries.count) · duplicates: \(groups.certain.count)"
                + " · possible duplicates: \(groups.possible.count)")
        for (heading, ids) in [("Duplicates", groups.certain), ("Possible duplicates", groups.possible)] {
            print("\(heading): \(ids.count)")
            for entry in entries.sorted(by: { $0.book.title < $1.book.title }) where ids.contains(entry.id) {
                guard let reasons = found[entry.id], let strongest = DuplicateReason.strongest(of: reasons) else {
                    continue
                }
                print(
                    "  \(strongest.label): \(entry.book.title) — \(entry.book.primaryAuthor)"
                        + " [\(entry.formatLine)]")
            }
            if ids.isEmpty { print("  (none)") }
        }
    }

    /// What ShelfCore makes of the answers the two services gave.
    ///
    /// The proof run (`Scripts/online-proof.sh`) fetches them and reports what
    /// `jq` sees. This reports what *Shelf* sees, which is the thing that
    /// matters and the thing a reviewer cannot otherwise check without the
    /// window. Nothing here touches the network: the service is told by the
    /// file's name, and the question by its name too.
    static func onlineRead(_ arguments: [String]) throws {
        guard !arguments.isEmpty else {
            print("usage: shelf-tool online-read <stored answer>…")
            exit(2)
        }
        for path in arguments {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let name = url.lastPathComponent
            let data = try Data(contentsOf: url)
            let query = onlineQuery(from: name)

            print("\(name) — \(query?.description ?? "no question in the file name")")
            do {
                let found =
                    name.hasPrefix("googlebooks")
                    ? try GoogleBooksReader.candidates(from: data)
                    : try OpenLibraryReader.candidates(from: data, answering: query ?? .isbn(""))
                if found.isEmpty { print("  (no candidate)") }
                // A file whose name does not say what was asked — the stored
                // 429 and the reconstructed volume — is listed without a score
                // rather than with a meaningless one.
                let ranked =
                    query.map { MetadataScore.ranked(found, for: $0) }
                    ?? found.map { (candidate: $0, score: -1) }
                for (candidate, score) in ranked {
                    print("  \(score < 0 ? "  —" : String(format: "%3d", score))  \(candidate.title)")
                    print("        \(candidate.subtitle)")
                    print(
                        "        \(candidate.source.name) · \(candidate.subjects.count) subjects · "
                            + "description: \(candidate.summary == nil ? "no" : "yes") · "
                            + "cover: \(candidate.coverURL == nil ? "no" : "yes")")
                }
            } catch let failure as MetadataReadFailure {
                print("  \(failure.message)")
            } catch {
                print("  unreadable: \(error.localizedDescription)")
            }
        }
    }

    /// The question a stored answer was the answer to, taken from its file
    /// name. `openlibrary-isbn-9780441013593.json` was an ISBN question.
    private static func onlineQuery(from name: String) -> MetadataQuery? {
        let stem = name.replacingOccurrences(of: ".json", with: "")
        let parts = stem.split(separator: "-").map(String.init)
        guard parts.count >= 3 else { return nil }
        switch parts[1] {
        case "isbn": return .isbn(parts[2])
        case "title": return .titleAuthor(title: parts.dropFirst(2).joined(separator: " "), author: nil)
        default: return nil
        }
    }

    // MARK: devices

    /// Where a volume is, and what it is.
    ///
    /// The tool has no `NSWorkspace`, so it takes what is under `/Volumes`
    /// rather than the workspace's list. That is the same set for the proof
    /// run's disk images, and it is the one thing here the app does
    /// differently — said out loud so nobody reads a green proof run as
    /// evidence that the *notification* path works. That one needs hardware,
    /// and it is in `docs/BACKLOG.md`.
    static func mountedVolumes() -> [MountedVolume] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return names.sorted().compactMap { name in
            let url = URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { return nil }
            let values = try? url.resourceValues(forKeys: [
                .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsRemovableKey,
                .volumeIsEjectableKey, .volumeIsInternalKey,
            ])
            // A disk image mounted by `Scripts/device-images.sh` is ejectable,
            // which is what makes it stand in for a reader here.
            let removable =
                ((values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false))
                && !(values?.volumeIsInternal ?? false)
            return MountedVolume(
                url: url, name: name,
                freeBytes: values?.volumeAvailableCapacity.map(Int64.init),
                totalBytes: values?.volumeTotalCapacity.map(Int64.init),
                isRemovable: removable,
                fileSystem: fileSystemName(of: url))
        }
    }

    /// `msdos`, `exfat`, `hfs`, `apfs` — from `statfs`, never from a localized
    /// description string.
    ///
    /// macOS only. On Linux the answer is "unknown", which every caller already
    /// handles: the file system decides the 4 GB limit and the name rules, and a
    /// device proof run happens on the Mac the reader is plugged into. The
    /// alternative — a second implementation over `/proc/mounts` that nothing
    /// would ever exercise — would be code that is wrong and unnoticed.
    static func fileSystemName(of url: URL) -> String? {
        #if canImport(Darwin)
            var buffer = statfs()
            guard statfs(url.path, &buffer) == 0 else { return nil }
            return withUnsafeBytes(of: &buffer.f_fstypename) { raw in
                guard let base = raw.baseAddress else { return nil }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
        #else
            return nil
        #endif
    }

    static func connectedDevice(at path: String) -> ConnectedDevice? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let volume =
            mountedVolumes().first { $0.url.path == url.path }
            ?? MountedVolume(
                url: url, name: url.lastPathComponent, freeBytes: nil, totalBytes: nil,
                fileSystem: fileSystemName(of: url))
        guard
            let profile = DeviceDetection.profile(
                forVolumeAt: volume.url, name: volume.name, isRemovable: volume.isRemovable)
        else { return nil }
        return ConnectedDevice(volume: volume, profile: profile)
    }

    static func devices() {
        let volumes = mountedVolumes()
        print("mounted volumes: \(volumes.count)")
        for volume in volumes {
            let profile = DeviceDetection.profile(
                forVolumeAt: volume.url, name: volume.name, isRemovable: volume.isRemovable)
            let free = volume.freeBytes.map(ByteCount.format) ?? "unknown"
            print("  \(volume.url.path)")
            print(
                "    name: \(volume.name) · file system: \(volume.fileSystem ?? "unknown") · free: \(free)"
                    + (volume.hasFAT32FileSizeLimit ? " · 4 GB file limit" : ""))
            if let profile {
                print(
                    "    device: \(profile.name) (\(profile.id)) · books in: \(profile.booksFolder.isEmpty ? "the volume root" : profile.booksFolder)"
                )
                print("    takes: \(profile.preferredFormats.map(\.label).joined(separator: " > "))")
            } else {
                print("    device: no profile matches — not a reader")
            }
        }
    }

    // MARK: device-contents

    static func deviceContents(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool device-contents <volume> [library]")
            exit(2)
        }
        guard let device = connectedDevice(at: path) else {
            print("no device profile matches \(path)")
            exit(1)
        }
        var entries: [LibraryEntry] = []
        if arguments.count > 1 {
            let (library, _) = try Library.open(
                URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true))
            entries = try await LibraryIndex(library: library).allEntries()
        }
        let manifest = DeviceManifest.read(fromVolume: device.volume.url, deviceID: device.profile.id)
        let files = DeviceContents.matched(
            DeviceContents.list(on: device), to: entries, manifest: manifest, profile: device.profile)

        print("\(device.profile.name) at \(device.volume.url.path)")
        print("files: \(files.count) · matched to a book: \(files.count { $0.bookID != nil })")
        let titles = Dictionary(entries.map { ($0.id, $0.book.title) }, uniquingKeysWith: { first, _ in first })
        for file in files {
            let book = file.bookID.flatMap { titles[$0] }
            print(
                "  \(file.path)  \(ByteCount.format(file.byteSize))"
                    + (book.map { "  —  \($0) (\(file.matchedBy?.label ?? ""))" } ?? "  —  not in the library"))
        }
    }

    // MARK: send

    static func send(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool send <library> <volume> [count]")
            exit(2)
        }
        let (library, _) = try Library.open(
            URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true))
        guard let device = connectedDevice(at: arguments[1]) else {
            print("no device profile matches \(arguments[1])")
            exit(1)
        }
        let limit = arguments.count > 2 ? Int(arguments[2]) : nil
        let index = try LibraryIndex(library: library)
        // By book number, which is stable: a title changes when it is edited
        // and the same run would then send a different set.
        var entries = try await index.allEntries().sorted { $0.number < $1.number }
        if let limit { entries = Array(entries.prefix(limit)) }

        let manifest = DeviceManifest.read(fromVolume: device.volume.url, deviceID: device.profile.id)
        let candidates = entries.map {
            TransferCandidate(
                entry: $0, folder: library.root.appendingPathComponent($0.folder, isDirectory: true))
        }
        let planStarted = Date()
        let plan = TransferPlanner.plan(candidates: candidates, device: device, manifest: manifest)
        print("\(device.profile.name) at \(device.volume.url.path)")
        print("plan: \(plan.summary()) · \(ImportReport.duration(Date().timeIntervalSince(planStarted)))")
        for reason in SkippedTransfer.Reason.allCases {
            let group = plan.skipped(for: reason)
            guard !group.isEmpty else { continue }
            print("  \(reason.label): \(group.count)")
            for skipped in group.prefix(10) { print("    \(skipped.title)") }
            if group.count > 10 { print("    … and \(group.count - 10) more") }
        }
        guard !plan.isEmpty else {
            print("nothing to send")
            return
        }
        guard plan.fits(freeBytes: device.volume.freeBytes) else {
            print(
                "NOT ENOUGH ROOM: \(ByteCount.format(plan.requiredBytes)) needed, "
                    + "\(ByteCount.format(device.volume.freeBytes ?? 0)) free. Nothing was copied.")
            exit(3)
        }

        let started = Date()
        let outcome = try await TransferRunner(makeHasher: PortableSHA256Hasher.factory).run(
            .init(device: device, plan: plan, manifest: manifest),
            progress: { progress in
                if progress.filesDone > 0, progress.filesDone % 50 == 0 {
                    print("  \(progress.filesDone) / \(progress.filesTotal)")
                }
                // The untidy exit, exactly as `import` has one: this is how the
                // proof run produces a transfer that was cut off mid-copy.
                if let after = ProcessInfo.processInfo.environment["SHELF_EXIT_AFTER"].flatMap(Int.init),
                    progress.filesDone >= after
                {
                    print("SHELF_EXIT_AFTER=\(after) – leaving the process now, mid-transfer")
                    exit(9)
                }
            })
        try? outcome.report.append(toVolume: device.volume.url)
        print(outcome.report.headline)
        print("took \(ImportReport.duration(Date().timeIntervalSince(started)))")
        for failure in outcome.report.failures { print("  FAILED \(failure.title): \(failure.message)") }
        print("manifest on the device: \(outcome.manifest.entries.count) files")
    }

    // MARK: device-delete

    static func deviceDelete(_ arguments: [String]) {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool device-delete <volume> <path on the volume>…")
            exit(2)
        }
        guard let device = connectedDevice(at: arguments[0]) else {
            print("no device profile matches \(arguments[0])")
            exit(1)
        }
        let wanted = Set(arguments.dropFirst())
        let files = DeviceContents.list(on: device).filter { wanted.contains($0.path) }
        guard !files.isEmpty else {
            print("none of those paths is a book file on \(device.volume.url.path)")
            exit(1)
        }

        var manifest = DeviceManifest.read(fromVolume: device.volume.url, deviceID: device.profile.id)
        let titles = Dictionary(
            manifest.entries.map { ($0.bookID, $0.title) }, uniquingKeysWith: { first, _ in first })
        let confirmation = DeviceDeletion.Confirmation(
            deviceName: device.name, files: files, titles: titles)

        // The confirmation, in full, before anything happens — the same text
        // the sheet shows, from the same place (ADR 0014).
        print(confirmation.question)
        print(confirmation.explanation)
        for line in confirmation.lines { print("  \(line)") }

        guard ProcessInfo.processInfo.environment["SHELF_CONFIRM_DELETE"] == "yes" else {
            print("")
            print("Nothing was deleted. Set SHELF_CONFIRM_DELETE=yes to carry this out.")
            return
        }
        let outcome = DeviceDeletion.delete(files, fromVolume: device.volume.url, manifest: &manifest)
        try? manifest.write(toVolume: device.volume.url)
        print("")
        print(outcome.summary)
        for (path, reason) in outcome.failed.sorted(by: { $0.key < $1.key }) {
            print("  FAILED \(path): \(reason)")
        }
    }

    // MARK: kobo

    /// Writes a synthetic `KoboReader.sqlite` describing the books that are
    /// already on the volume.
    ///
    /// Synthetic, because a borrowed one would carry somebody's reading history
    /// into this repository — and because the point being measured is that
    /// Shelf reads the file and never writes it, which a fixture can show.
    static func koboSynthesise(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool kobo-synthesise <volume> [count]")
            exit(2)
        }
        let volume = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let profile = DeviceProfiles.profile(id: "kobo") ?? DeviceProfiles.all[0]
        let device = ConnectedDevice(
            volume: MountedVolume(url: volume, name: volume.lastPathComponent), profile: profile)
        let files = DeviceContents.list(on: device)
        let count = arguments.count > 1 ? (Int(arguments[1]) ?? files.count) : files.count

        var random = SeededGenerator(seed: 20_260_918)
        let shelfNames = ["On the train", "Holiday", "Book club"]
        let entries = files.prefix(count).enumerated().map { offset, file -> SyntheticKoboDatabase.Entry in
            let percent = Int(random.next() % 101)
            let status: KoboReadingState.ReadStatus = percent == 0 ? .unread : (percent >= 100 ? .finished : .reading)
            return SyntheticKoboDatabase.Entry(
                path: file.path,
                title: (file.name as NSString).deletingPathExtension,
                author: "Synthetic Author",
                percentRead: percent,
                status: status,
                shelves: offset % 3 == 0 ? [shelfNames[offset % shelfNames.count]] : [],
                lastReadAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 3_600))
        }
        let url = volume.appendingPathComponent(KoboReadingState.relativePath)
        try SyntheticKoboDatabase(entries: Array(entries)).write(to: url)
        print("wrote a synthetic \(KoboReadingState.relativePath) with \(entries.count) books")
        print("NOT a real device database: the tables and columns Shelf reads, and nothing else.")
    }

    static func koboRead(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool kobo-read <volume>")
            exit(2)
        }
        let volume = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let database = volume.appendingPathComponent(KoboReadingState.relativePath)
        let before = try FileDigest.sha256(of: database, makeHasher: PortableSHA256Hasher.factory)

        let cache = calibreCacheDirectory
        let reading = try KoboReadingState().read(volume: volume, cacheDirectory: cache)
        let after = try FileDigest.sha256(of: database, makeHasher: PortableSHA256Hasher.factory)

        print("books the device knows: \(reading.books.count)")
        for book in reading.books.prefix(15) {
            let shelves = book.shelves.isEmpty ? "" : " · shelves: \(book.shelves.joined(separator: ", "))"
            print("  \(book.path)  \(book.status.label) \(book.percentRead)%\(shelves)")
        }
        if reading.books.count > 15 { print("  … and \(reading.books.count - 15) more") }
        for warning in reading.warnings { print("  warning: \(warning)") }
        print("")
        print("KoboReader.sqlite before: \(before)")
        print("KoboReader.sqlite after:  \(after)")
        print(before == after ? "UNCHANGED – the device's database was only read" : "CHANGED – this is a defect")
        if before != after { exit(4) }
    }

    // MARK: calibre

    /// Where the copy of `metadata.db` goes. Outside `~/Documents`, which is
    /// synced, and inside the folder this project keeps its test material in.
    static var calibreCacheDirectory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Shelf")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a Calibre library nobody wrote, for the proof run to import.
    ///
    /// The quirks — a listed file that is not there, a book with no cover, an
    /// unreadable OPF, an orphan on disk — are on for a small fixture and off
    /// for a large measuring run, where a thousand of each would be noise
    /// rather than evidence.
    static func calibreSynthesise(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool calibre-synthesise <folder> [count]")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let count = arguments.count > 1 ? (Int(arguments[1]) ?? 5) : 5
        let started = Date()
        let summary = try SyntheticCalibreLibrary.write(
            to: folder, options: .init(count: count, includeQuirks: count <= 100))
        print(
            "wrote \(summary.books) books · \(summary.files) files · "
                + "\(ByteCount.format(summary.totalBytes)) · "
                + "\(ImportReport.duration(Date().timeIntervalSince(started)))")
        print(
            "  missing on disk: \(summary.missingFiles) · orphan on disk: \(summary.orphanFiles) · "
                + "no cover: \(summary.booksWithoutCover) · unreadable OPF: \(summary.unreadableOPFs)")
        print("  \(folder.path)")
    }

    /// The counting protocol, and nothing else. Writes nothing anywhere.
    ///
    /// This is what `ImportSheet` shows before "Import" can be clicked, printed
    /// instead of drawn — the same `CalibreCensus` value, so the window and the
    /// command line cannot disagree about how many books there are.
    static func calibreDry(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool calibre-dry <calibre folder> [destination]")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let destination =
            arguments.count > 1
            ? URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
            : nil

        let started = Date()
        let library = try CalibreReader().read(folder: folder, cacheDirectory: calibreCacheDirectory)
        let census = CalibreCensusTaker().take(of: library, destination: destination)

        print("Calibre library: \(folder.path)")
        print("Schema version:  \(library.schema.userVersion)\(library.schema.isKnown ? "" : "  (unknown)")")
        print("")
        for line in census.lines() { print("  " + line) }
        if !census.missingFiles.isEmpty {
            print("")
            print("  Listed in metadata.db and not on the disk:")
            for path in census.missingFiles.prefix(20) { print("    \(path)") }
            if census.missingFiles.count > 20 { print("    \u{2026} and \(census.missingFiles.count - 20) more") }
        }
        if !census.orphanFiles.isEmpty {
            print("")
            print("  On the disk and not in metadata.db:")
            for path in census.orphanFiles.prefix(20) { print("    \(path)") }
            if census.orphanFiles.count > 20 { print("    \u{2026} and \(census.orphanFiles.count - 20) more") }
        }
        for warning in census.warnings {
            print("")
            print("  ! \(warning)")
        }
        print("")
        print("read in \(ImportReport.duration(Date().timeIntervalSince(started)))")
        print("Nothing was written. The Calibre folder was only read.")
    }

    /// The import itself, through the same planner and runner every other
    /// import uses. The Calibre folder is only ever read.
    static func calibreImport(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool calibre-import <calibre folder> <library folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true)
        let libraryURL = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)

        let readStarted = Date()
        let calibre = try CalibreReader().read(folder: folder, cacheDirectory: calibreCacheDirectory)
        print(
            "read \(calibre.books.count) books from metadata.db in "
                + ImportReport.duration(Date().timeIntervalSince(readStarted)))
        for warning in calibre.warnings { print("  ! \(warning)") }

        let (library, stored) = try openOrCreate(libraryURL)
        var descriptor = stored
        let index = try LibraryIndex(library: library)

        let census = CalibreCensusTaker().take(of: calibre, destination: libraryURL)
        for line in census.lines() { print("  " + line) }
        guard census.hasRoom != false else {
            print("Not enough room at the destination. Nothing was copied.")
            exit(1)
        }

        // The columns' definitions before the books, for the same reason the
        // shelf tree goes before the books (ADR 0008): a value whose column the
        // index has never heard of has nowhere to go.
        descriptor.customColumns = calibre.customColumns
        try library.write(descriptor)
        try await index.saveCustomColumns(calibre.customColumns)

        let hashStarted = Date()
        let source = CalibreImportSource(makeHasher: PortableSHA256Hasher.factory)
        let read = source.read(calibre) { done, total in
            if done > 0, done % 500 == 0 { print("  hashed \(done) / \(total)") }
        }
        print(
            "hashed \(read.candidates.count) files in "
                + ImportReport.duration(Date().timeIntervalSince(hashStarted)))
        for (format, count) in read.skippedFormats.sorted(by: { $0.key < $1.key }) {
            print("  \(count) \(format) file(s) Shelf does not import")
        }
        print("  \(read.missingFiles.count) file(s) listed in metadata.db and not on the disk")

        let knowledge = ImportKnowledge(
            digests: try await index.allFormatDigests(),
            isbns: try await index.allISBNs(),
            titleKeys: try await index.allTitleKeys(),
            formatsByBook: try await formatsByBook(index),
            foldersByBook: try await foldersByBook(index))
        // The stored counter, or the highest number already on the disk if a
        // killed run got further than the descriptor did. It never goes
        // backwards, so a deleted book's number is still not reused.
        let startingNumber = max(descriptor.nextBookNumber, try await index.highestBookNumber() + 1)
        let plan = ImportPlanner.plan(
            candidates: read.candidates, knowledge: knowledge,
            startingNumber: startingNumber, existingFolders: existingFolders(library))
        print("plan: \(plan.summary())")

        let runner = ImportRunner(makeHasher: PortableSHA256Hasher.factory)
        let copyStarted = Date()
        // The index is written *while* the run goes on, so a run that is cut off
        // leaves an index that matches the folder and the next run resumes
        // instead of copying everything again.
        let outcome = try await runner.run(
            ImportRunner.Options(
                library: library, plan: plan, sourceDescription: "Calibre library \(folder.path)"),
            progress: { progress in
                if progress.filesDone > 0, progress.filesDone % 500 == 0 {
                    print("  copied \(progress.filesDone) / \(progress.filesTotal)")
                }
            },
            saveBatch: { try await index.save($0) })
        print("copied and verified in \(ImportReport.duration(Date().timeIntervalSince(copyStarted)))")
        descriptor.nextBookNumber = outcome.nextBookNumber
        try library.write(descriptor)
        try outcome.report.append(to: library)

        print("")
        print(outcome.report.rendered())
        print("index holds \(try await index.count()) books")
        print("Nothing in the Calibre library was changed, moved or deleted.")
        if !outcome.report.everythingVerified { exit(1) }
    }

    // MARK: rebuild

    /// Throws the index away and rebuilds it from the folders.
    ///
    /// The proof behind ADR 0001. It prints the counts before and after,
    /// because "the folder is the truth" is a claim about numbers.
    /// Takes every book off every shelf and removes the shelves themselves.
    ///
    /// What a proof run needs in order to be run twice: the shelves it makes
    /// live in three places (`library.json`, the index, and every book's
    /// `metadata.opf`), and clearing only one of them leaves a library that
    /// disagrees with itself. It writes `metadata.opf` files and nothing else —
    /// a book file is never written (CONCEPT §4).
    static func unshelve(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool unshelve <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, stored) = try Library.open(libraryURL)
        var descriptor = stored
        let index = try LibraryIndex(library: library)
        let editor = MetadataEditor(library: library)

        let shelved = try await index.allEntries().filter { !$0.book.shelves.isEmpty }
        for entry in shelved {
            let change = MetadataChange.make(from: entry.book) { $0.shelves = [] }
            _ = try await editor.apply(change, to: entry, in: index)
        }
        descriptor.shelves = []
        try library.write(descriptor)
        try await index.saveShelves([])
        print("took \(shelved.count) book(s) off their shelves and removed every shelf")
    }

    /// Puts books on a shelf from the command line, making the shelf if need be.
    ///
    /// What the proof run distributes a thousand books with, and what a
    /// screenshot uses to arrange a library before it is photographed. It goes
    /// through the same path the window does — `MetadataChange` into
    /// `MetadataEditor` — so what it measures is what a drop on a shelf costs,
    /// not what a direct write to the index would cost.
    static func shelve(_ arguments: [String]) async throws {
        guard arguments.count >= 3, let count = Int(arguments[2]) else {
            print("usage: shelf-tool shelve <library> <shelf path> <count> [offset]")
            exit(2)
        }
        let path = arguments[1]
        let offset = arguments.count > 3 ? Int(arguments[3]) ?? 0 : 0
        let (library, index) = try openLibrary(arguments[0])
        var descriptor = try library.readDescriptor()
        let editor = MetadataEditor(library: library)

        // The tree first and the books after: the index resolves a book's paths
        // against the shelves it holds and skips what it cannot find.
        var tree = ShelfTree(descriptor.shelves)
        guard tree.ensure(path: path) != nil else {
            print("“\(path)” is not a shelf path")
            exit(2)
        }
        descriptor.shelves = tree.shelves
        try library.write(descriptor)
        try await index.saveShelves(tree.shelves)

        let books = Array(try await firstBooks(offset + count, in: index).dropFirst(offset))
        var milliseconds: [Double] = []
        for entry in books {
            let change = MetadataChange.make(from: entry.book) { book in
                guard !book.shelves.contains(path) else { return }
                book.shelves = (book.shelves + [path]).sorted()
            }
            guard !change.isEmpty else { continue }
            let started = ContinuousClock.now
            _ = try await editor.apply(change, to: entry, in: index)
            let took = ContinuousClock.now - started
            milliseconds.append(
                Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1_000)
        }
        print("put \(milliseconds.count) book(s) on \(path)")
        // CONCEPT §11 asks under 20 ms for one assignment; the proof run checks it.
        printTimings(milliseconds, target: 20)
    }

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
        // The tree before the books, and every path any book named made sure
        // of. The index resolves a book's shelf paths against the shelves it
        // holds and skips what it cannot find, so saving the books first files
        // every one of them nowhere. A path `library.json` has lost — a backup
        // restored without the `.shelf` folder — is created rather than
        // dropped: the book said where it stands, and the folder is the truth.
        var tree = ShelfTree(descriptor.shelves)
        for path in result.shelfPathsSeen.sorted() { _ = tree.ensure(path: path) }
        try await index.saveShelves(tree.shelves)
        // The columns' definitions travel with the tree and for the same
        // reason: `library.json` is the authority for both shapes, and the
        // index is a cache of them. Without this a rebuild leaves every column
        // named after its own label, because a book's OPF carries the values
        // and never the names — which is what a proof run found.
        try await index.saveCustomColumns(descriptor.customColumns)
        descriptor.shelves = tree.shelves

        for batch in result.entries.chunked(into: 500) {
            try await index.save(batch)
        }
        descriptor.nextBookNumber = max(descriptor.nextBookNumber, result.highestNumber + 1)
        try library.write(descriptor)

        let after = try await index.count()
        let shelved = try await index.totals().notOnAnyShelf
        print("")
        print("rebuilt in \(ImportReport.duration(Date().timeIntervalSince(started)))")
        print("  shelves: \(tree.shelves.count); books on one: \(after - shelved)")
        print("  before: \(before) books")
        print("  after:  \(after) books")
        print("  folders with no readable book: \(result.unreadableFolders.count)")
        print("  books whose metadata came from the file rather than an OPF: \(result.withoutOPF.count)")
        for folder in result.unreadableFolders.prefix(10) { print("    \(folder)") }
        // An index that was empty before is not a disagreement: that is what
        // "the index was deleted" looks like, and rebuilding it is the point.
        // Saying MISMATCH there taught the proof run to ignore the word.
        guard before == after || before == 0 else {
            print("MISMATCH – the index and the folders disagree")
            exit(1)
        }
        print("index and folders agree")
    }

    // MARK: edit

    /// Sets one book's rating and read status from the command line.
    ///
    /// The same `MetadataEditor` the window uses, so the proof run can make ten
    /// changes and then ask whether the book file survived them – which is the
    /// Sprint 2 form of "the folder is the truth" (ADR 0001).
    static func edit(_ arguments: [String]) async throws {
        guard arguments.count >= 4, let stars = Int(arguments[2]) else {
            print("usage: shelf-tool edit <library> <title substring> <stars 0-5> <read yes|no>")
            exit(2)
        }
        let (library, index) = try openLibrary(arguments[0])
        let entry = try await findBook(arguments[1], in: index)
        let read = ["yes", "true", "1"].contains(arguments[3].lowercased())

        let change = MetadataChange.make(from: entry.book) {
            $0.stars = stars
            $0.isRead = read
        }
        guard !change.isEmpty else {
            print("nothing to change: “\(entry.book.title)” is already \(stars) stars, read=\(read)")
            return
        }
        let updated = try await MetadataEditor(library: library).apply(change, to: entry, in: index)
        print(
            "“\(updated.book.title)”: \(change.fields.map(\.label).joined(separator: ", ")) "
                + "→ \(updated.book.stars) stars (calibre:rating \(updated.book.rating)), "
                + "read=\(updated.book.isRead)")
    }

    // MARK: show

    /// What the index holds about one book – the other half of the edit proof:
    /// erase the index, rebuild it from the folders, and ask again.
    static func show(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool show <library> <title substring>")
            exit(2)
        }
        let (_, index) = try openLibrary(arguments[0])
        let entry = try await findBook(arguments[1], in: index)
        print("title:    \(entry.book.title)")
        print("authors:  \(entry.book.authors.joined(separator: ", "))")
        print("folder:   \(entry.folder)")
        print("stars:    \(entry.book.stars)")
        print("rating:   \(entry.book.rating)")
        print("read:     \(entry.book.isRead)")
        print("tags:     \(entry.book.tags.joined(separator: ", "))")
        let ids = entry.book.identifiers.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print("ids:      \(ids)")
        print("modified: \(OPFDate.render(entry.book.modifiedAt))")
    }

    private static func openLibrary(_ path: String) throws -> (Library, LibraryIndex) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, _) = try Library.open(url)
        return (library, try LibraryIndex(library: library))
    }

    /// The first book whose title contains `needle`, case-insensitively. Enough
    /// for a proof run and for a person at a prompt; the window searches
    /// properly.
    ///
    /// An empty `needle` means the first book in title order. The proof run
    /// uses that: it has to name the same book twice, before and after a
    /// rebuild, without knowing what is in a freshly generated library.
    private static func findBook(_ needle: String, in index: LibraryIndex) async throws -> LibraryEntry {
        let all = try await index.allEntries()
        if needle.isEmpty, let first = all.first { return first }
        guard let entry = all.first(where: { $0.book.title.localizedCaseInsensitiveContains(needle) }) else {
            print("no book whose title contains “\(needle)” – \(all.count) books in the index")
            exit(1)
        }
        return entry
    }

    // MARK: The Sprint 2b proof run
    //
    // Four commands that between them answer the questions the sprint brief
    // asks about 5 000 books: what a change costs including the search index,
    // whether the book files survived, how long a search takes over the whole
    // library, and whether a rebuilt-from-scratch index still knows every
    // change.
    //
    // They all address "the first <count> books **by book number**". That
    // order is stable and title order is not: the very first thing `bulk-edit`
    // does is change a title, and "the first 200 by title" would then be a
    // different 200 books before and after.

    /// What `bulk-edit` writes, so `verify-edits` can look for it without a
    /// state file between the two runs.
    static let proofTag = "proof-run-2b"
    static let proofTitleSuffix = " [2b]"
    static func proofDescription(for number: Int) -> String {
        "Edited by the Sprint 2b proof run, book number \(number)."
    }

    /// The first `count` books by book number.
    static func firstBooks(_ count: Int, in index: LibraryIndex) async throws -> [LibraryEntry] {
        let all = try await index.allEntries()
        return Array(all.sorted { $0.number < $1.number }.prefix(count))
    }

    // MARK: bulk-edit

    /// Changes the title, the tags and the description of `count` books, one
    /// write each, and says how long a change takes.
    ///
    /// Each round is one `MetadataEditor.apply`, which is one `metadata.opf`
    /// written and one index update – the search row included. That is what the
    /// window does when a field is finished, so the number this prints is the
    /// number a person waits for.
    static func bulkEdit(_ arguments: [String]) async throws {
        guard arguments.count >= 2, let count = Int(arguments[1]) else {
            print("usage: shelf-tool bulk-edit <library> <count>")
            exit(2)
        }
        let (library, index) = try openLibrary(arguments[0])
        let books = try await firstBooks(count, in: index)
        guard !books.isEmpty else {
            print("no books to edit")
            exit(1)
        }
        let editor = MetadataEditor(library: library)

        var milliseconds: [Double] = []
        milliseconds.reserveCapacity(books.count)
        var skipped = 0

        for entry in books {
            // The three fields the brief names, through the same core rules the
            // inspector uses – not by assigning to the model behind their back.
            var edited = entry.book
            switch BookField.title.apply(entry.book.title + proofTitleSuffix, to: edited) {
            case .changed(let next): edited = next
            case .unchanged, .rejected: break
            }
            switch TagEdit.add(proofTag, to: edited) {
            case .changed(let next): edited = next
            case .unchanged, .rejected: break
            }
            switch BookField.description.apply(proofDescription(for: entry.number), to: edited) {
            case .changed(let next): edited = next
            case .unchanged, .rejected: break
            }

            let change = MetadataChange.make(from: entry.book) { $0 = edited }
            guard !change.isEmpty else {
                skipped += 1
                continue
            }

            let started = ContinuousClock.now
            _ = try await editor.apply(change, to: entry, in: index)
            let took = ContinuousClock.now - started
            milliseconds.append(Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1_000)
        }

        print("edited \(milliseconds.count) books, \(skipped) already carried the change")
        printTimings(milliseconds, target: 50)
    }

    /// Median, worst case and how many were over the target. A mean would hide
    /// the one write that took a second, and the worst case is the one a person
    /// actually notices.
    static func printTimings(_ milliseconds: [Double], target: Double) {
        guard !milliseconds.isEmpty else { return }
        let sorted = milliseconds.sorted()
        let median = sorted[sorted.count / 2]
        let worst = sorted[sorted.count - 1]
        let over = sorted.filter { $0 > target }.count
        print(String(format: "  median: %.1f ms", median))
        print(String(format: "  slowest: %.1f ms", worst))
        print(String(format: "  95th percentile: %.1f ms", sorted[min(sorted.count - 1, (sorted.count * 95) / 100)]))
        print("  over the \(Int(target)) ms target: \(over) of \(sorted.count)")
    }

    // MARK: epub-digests

    /// One line per book: the SHA-256 of its EPUB and the path, for a diff
    /// before and after the edits. The whole promise of v1.0 in one file.
    static func epubDigests(_ arguments: [String]) async throws {
        guard arguments.count >= 2, let count = Int(arguments[1]) else {
            print("usage: shelf-tool epub-digests <library> <count>")
            exit(2)
        }
        let (library, index) = try openLibrary(arguments[0])
        for entry in try await firstBooks(count, in: index) {
            for format in entry.formats.sorted(by: { $0.fileName < $1.fileName }) {
                let url = library.root
                    .appendingPathComponent(entry.folder, isDirectory: true)
                    .appendingPathComponent(format.fileName)
                let digest = try FileDigest.sha256(of: url, makeHasher: PortableSHA256Hasher.factory)
                print("\(digest)  \(entry.folder)/\(format.fileName)")
            }
        }
    }

    // MARK: bulk-tag-undo

    /// Tags many books at once and then undoes it, the way ⌘Z does.
    ///
    /// This is the multiple-selection claim tested where it can be checked to
    /// the byte: *one* undo step for however many books, and after it every
    /// `metadata.opf` is exactly the file it was. Undo is built from
    /// `MetadataChange.inverse`, which carries the previous *value* rather than
    /// re-deriving it, so "restores exactly" is something that can be asserted
    /// rather than hoped for — and this is the assertion.
    ///
    /// The EPUB digests are taken as well, because the one rule that is never
    /// negotiable is that a book file is not written (CONCEPT §4). An edit that
    /// restored every OPF and touched one EPUB would pass the interesting half
    /// of this test and fail the important one.
    static func bulkTagUndo(_ arguments: [String]) async throws {
        guard arguments.count >= 2, let count = Int(arguments[1]) else {
            print("usage: shelf-tool bulk-tag-undo <library> <count> [tag]")
            exit(2)
        }
        let tag = arguments.count > 2 ? arguments[2] : proofTag
        let (library, index) = try openLibrary(arguments[0])
        let books = try await firstBooks(count, in: index)
        guard !books.isEmpty else {
            print("no books to tag")
            exit(1)
        }
        let editor = MetadataEditor(library: library)

        func opf(_ entry: LibraryEntry) -> URL {
            library.root
                .appendingPathComponent(entry.folder, isDirectory: true)
                .appendingPathComponent(OPFDocument.fileName)
        }
        func epubDigest(_ entry: LibraryEntry) throws -> [String] {
            try entry.formats.sorted(by: { $0.fileName < $1.fileName }).map { format in
                try FileDigest.sha256(
                    of: library.root
                        .appendingPathComponent(entry.folder, isDirectory: true)
                        .appendingPathComponent(format.fileName),
                    makeHasher: PortableSHA256Hasher.factory)
            }
        }

        var opfBefore: [UUID: Data] = [:]
        var bookBefore: [UUID: [String]] = [:]
        for entry in books {
            opfBefore[entry.id] = (try? Data(contentsOf: opf(entry))) ?? Data()
            bookBefore[entry.id] = try epubDigest(entry)
        }

        // The edit, as one group. Each change keeps its own inverse, which is
        // what an undo group holds.
        var changes: [(entry: LibraryEntry, change: MetadataChange)] = []
        let started = ContinuousClock.now
        for entry in books {
            guard case .changed(let edited) = TagEdit.add(tag, to: entry.book) else { continue }
            let change = MetadataChange.make(from: entry.book) { $0 = edited }
            guard !change.isEmpty else { continue }
            let updated = try await editor.apply(change, to: entry, in: index)
            changes.append((updated, change))
        }
        let tookToTag = ContinuousClock.now - started
        print("tagged \(changes.count) book(s) with “\(tag)” in \(milliseconds(tookToTag)) ms")

        var changedOnDisk = 0
        for (entry, _) in changes where (try? Data(contentsOf: opf(entry))) != opfBefore[entry.id] {
            changedOnDisk += 1
        }
        guard changedOnDisk == changes.count else {
            print("FAILED – only \(changedOnDisk) of \(changes.count) OPFs actually changed")
            exit(1)
        }
        print("  every one of those \(changes.count) metadata.opf files changed on disk")

        // ⌘Z: the same changes, inverted, newest first.
        let undoStarted = ContinuousClock.now
        for (entry, change) in changes.reversed() {
            _ = try await editor.apply(change.inverse, to: entry, in: index)
        }
        print("undid them in \(milliseconds(ContinuousClock.now - undoStarted)) ms")

        var restored = 0
        var untouched = 0
        var wrong: [String] = []
        for (entry, _) in changes {
            let now = (try? Data(contentsOf: opf(entry))) ?? Data()
            if now == opfBefore[entry.id] {
                restored += 1
            } else {
                wrong.append(entry.folder)
            }
            if try epubDigest(entry) == bookBefore[entry.id] { untouched += 1 }
        }
        print("  metadata.opf byte for byte as before: \(restored) of \(changes.count)")
        print("  EPUBs untouched: \(untouched) of \(changes.count)")
        for folder in wrong.prefix(5) { print("    still different: \(folder)") }

        // The tag must also be gone from the index, not only from the files:
        // a search that still finds it would mean the undo stopped half way.
        let stillFound = try await index.search(tag).count
        print("  books the index still finds under “\(tag)”: \(stillFound)")

        guard restored == changes.count, untouched == changes.count, stillFound == 0 else {
            print("FAILED – the undo did not put everything back")
            exit(1)
        }
        print("ok – \(changes.count) books tagged and undone, every file as it was")
    }

    private static func milliseconds(_ duration: Duration) -> String {
        let value =
            Double(duration.components.attoseconds) / 1e15
            + Double(duration.components.seconds) * 1_000
        return String(format: "%.1f", value)
    }

    // MARK: search-time

    /// How long a search takes over the whole library, run several times.
    ///
    /// Several times because the first one warms SQLite's page cache and the
    /// first one is not what a person meets – they have already searched for
    /// something else. Both numbers are printed so the difference is visible.
    static func searchTime(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool search-time <library> <query> [rounds]")
            exit(2)
        }
        let rounds = arguments.count > 2 ? Int(arguments[2]) ?? 20 : 20
        let (_, index) = try openLibrary(arguments[0])
        let query = arguments[1]

        var milliseconds: [Double] = []
        var hits = 0
        for round in 0..<max(1, rounds) {
            let started = ContinuousClock.now
            let found = try await index.search(query)
            let took = ContinuousClock.now - started
            let ms = Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1_000
            if round == 0 {
                print(String(format: "  first search (cold page cache): %.1f ms", ms))
            } else {
                milliseconds.append(ms)
            }
            hits = found.count
        }
        print("  books in the library: \(try await index.count())")
        print("  hits for “\(query)”: \(hits)")
        printTimings(milliseconds, target: 100)
    }

    // MARK: verify-edits

    /// Whether every one of the changes is still there. Run after a rebuild,
    /// which is the point: the index was thrown away and the answer has to come
    /// out of the folders.
    static func verifyEdits(_ arguments: [String]) async throws {
        guard arguments.count >= 2, let count = Int(arguments[1]) else {
            print("usage: shelf-tool verify-edits <library> <count>")
            exit(2)
        }
        let (_, index) = try openLibrary(arguments[0])
        let books = try await firstBooks(count, in: index)

        var missingTitle = 0
        var missingTag = 0
        var missingDescription = 0
        for entry in books {
            if !entry.book.title.hasSuffix(proofTitleSuffix) { missingTitle += 1 }
            if !entry.book.tags.contains(proofTag) { missingTag += 1 }
            if entry.book.description != proofDescription(for: entry.number) { missingDescription += 1 }
        }

        // And the search index, which is rebuilt with the rest: a tag that
        // cannot be found is a tag the FTS row lost.
        let found = try await index.search(proofTag)

        print("checked \(books.count) books")
        print("  titles without the suffix:      \(missingTitle)")
        print("  books without the tag:          \(missingTag)")
        print("  descriptions that do not match: \(missingDescription)")
        print("  found by searching for the tag: \(found.count)")
        let whole = missingTitle == 0 && missingTag == 0 && missingDescription == 0 && found.count >= books.count
        print(whole ? "  every change survived ✓" : "  CHANGES WERE LOST")
        if !whole { exit(1) }
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
        // `FileFacts` follows symlinks; `attributesOfItem` does not, and the
        // difference is a book imported with a size of eighty bytes.
        guard let format = BookFileFormat.of(url), let facts = FileFacts.of(url) else { return nil }
        let digest = try FileDigest.sha256(of: facts.url, makeHasher: PortableSHA256Hasher.factory)

        // One call for every format. This tool has no app layer, so PDF and
        // CBR come back as their file names with a warning saying why — which
        // is honest, and is what `BookFileReader` says of them.
        let read = BookFileReader.read(url: facts.url, format: format)
        return ImportCandidate(
            source: facts.url, byteSize: facts.byteSize, format: format, sha256: digest, book: read.book,
            cover: read.cover, coverName: read.coverName, drm: read.drm, modifiedAt: facts.modifiedAt,
            warnings: read.warnings)
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

    /// Where every book the library already holds lives, so a second import
    /// puts a new format in the folder the book already has rather than being
    /// handed an empty path (ADR 0002, decision 8).
    static func foldersByBook(_ index: LibraryIndex) async throws -> [UUID: String] {
        var result: [UUID: String] = [:]
        for entry in try await index.allEntries() {
            result[entry.id] = entry.folder
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
