import Foundation
import ShelfCore
import ShelfFixtures

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
      merge-candidates <library>    list the groups "Merge Books…" would offer
                                    to merge, per B3's own rule (same valid
                                    ISBN, or same normalised title and author
                                    with no conflicting language or ISBN).
                                    Reads only
      similar-spellings <library>   list the groups "Similar Spellings…"
                                    would propose for authors and publishers,
                                    and the winning spelling for each. Reads
                                    only
      standardize-fields <library>  list what "Standardize Fields…" would
                                    change per book (title, language, ISBN,
                                    tags), per C3's own rules. Reads only
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
      epub-roundtrip <folder> <output folder>
                                    every .epub in <folder>, read with
                                    ZipReader, every entry carried forward
                                    through EPUBArchiveWriter unchanged,
                                    written to <output folder>, and read
                                    again: same entry names, same decompressed
                                    bytes, same compression method, and the
                                    size before and after. Never touches
                                    <folder> itself (docs/adr/0021-…)
      epub-metadata-patch <folder> <output folder>
                                    every .epub in <folder>: title, authors
                                    and publisher patched in content.opf
                                    with EPUBOPFPatch, everything else
                                    carried forward unchanged, written to
                                    <output folder>. Prints, per book, the
                                    number of entries that differ from the
                                    original (must be exactly one — the OPF)
                                    and the size of that one entry, before
                                    and after. Never touches <folder> itself
      epub-cover-patch <folder> <output folder>
                                    every .epub in <folder>: a synthetic
                                    cover written in with EPUBCoverPatch —
                                    once in the same format the book's own
                                    cover already has (proving exactly one
                                    entry differs when the manifest already
                                    names a cover), and once in a different
                                    format when it does (proving exactly
                                    two: the image and the OPF, media-type
                                    corrected). Prints, per book, which of
                                    the two cases (a: already has a cover,
                                    b: does not) it fell into, the entry
                                    counts, and the size before and after,
                                    absolute and in percent. Shelf's own
                                    reader (EPUBMetadata) reads the new
                                    cover back from the result. Never
                                    touches <folder> itself (docs/adr/0021-…)
      epub-cover-real-size <cover source.epub> <folder> <output folder>
                                    every .epub in <folder>, patched with the
                                    REAL cover already inside <cover
                                    source.epub> (via EPUBMetadata, never a
                                    synthetic few-hundred-byte one) — so the
                                    size delta is what a real cover
                                    replacement actually costs, not an
                                    artifact of a tiny test image. Prints,
                                    per book, the cover's own byte size and
                                    the book's size before and after,
                                    absolute and in percent, and whether the
                                    cover turned out already identical (case
                                    b of EPUBCoverPatch.Result.changed) — the
                                    source book itself, patched with its own
                                    cover, is expected to land there. Never
                                    touches <folder> or <cover source.epub>
      epub-file-replace-proof <folder> <working folder>
                                    the whole EPUBFileReplacement path
                                    (docs/adr/0021-…) against copies of
                                    every .epub in <folder>, made in
                                    <working folder>: patched, written in
                                    place, read back, rehashed, the original
                                    to the Trash and hashed there too, not
                                    just trusted to have arrived — one book
                                    at a time, never concurrently — and then
                                    the four refusals, each proven to leave
                                    exactly the original file and nothing
                                    else, plus the disposal-failure fact: a
                                    Trash that declines does not undo a
                                    swap that already succeeded.
                                    <folder> itself is only ever read
      epub-write-fixture <library folder>
                                    a small library for
                                    Scripts/write-into-book-shot.sh: three
                                    ordinary EPUBs, one with Adobe DRM, one
                                    with no dc:title at all, and one book
                                    edited in Shelf so its publisher,
                                    language, date and description differ
                                    from its own file. Synthetic only
      epub-cover-write-fixture <library folder> <old.jpg> <new.jpg> <added.jpg>
                                    a small library for
                                    Scripts/write-into-book-cover-shot.sh
                                    (Sprint 11): "The Glass Almanac" has its
                                    own cover.<ext> changed to <new.jpg>
                                    since import (was <old.jpg>) plus a
                                    publisher edit, in the same sheet;
                                    "Cinders and Salt" has no cover in its
                                    EPUB at all but Shelf offers <added.jpg>;
                                    "The Quiet Harbour" is untouched since
                                    import, so its cover already matches.
                                    The three cover files are read from
                                    disk, never generated here — real,
                                    decodable images the caller supplies
                                    (Scripts/write-into-book-cover-shot.sh
                                    makes them from Shelf's own app icon
                                    with sips). Synthetic library only
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

    Ordering the library (Sprint 8). Both of these change the folder tree or
    the metadata that names it, so both print what they would do before they do
    it — `merge` changes metadata only, `organize` moves folders.

      names <library> <kind>        every spelling of author|series|publisher|
                                    tag in the library, with its book count.
                                    Reads only
      merge <library> <kind> <target> <source>…
                                    fold every <source> spelling into <target>,
                                    writing one metadata.opf per book affected.
                                    No folder is moved. With no <source>, prints
                                    what it would do and writes nothing
      organize <library> [--run]    where every book's folder ought to be. The
                                    preview alone unless --run is given: old →
                                    new, how many are already right, every
                                    collision, everything it cannot touch.
                                    With --run it moves them, hashing each
                                    folder before and after, and writes a
                                    manifest it can be undone from
      organize-undo <library>       put every folder the manifest names back
                                    where it came from, verified the same way
      export <library> <destination> [archive|books|calibre] [--flat] [--links]
                                    write the library out as an ordinary folder
                                    of files. `archive` can be imported back
                                    with nothing lost, `books` is the book
                                    files alone, `calibre` adds the shelves and
                                    the read status as Calibre tags. A second
                                    run writes only the differences
      first-titles <library> <count>
                                    the titles of the first <count> books by
                                    book number — a stable order to drive the
                                    proof run from
      set-author <library> <title> <author>
                                    set one book's author, for building the
                                    "one person, three spellings" case
      make-collision <library> exact|case
                                    give two books the same target folder, or
                                    two that differ only in capitals — the
                                    traps the organise preview has to name
      compare <one library> <other library>
                                    whether two libraries hold the same books
                                    with the same ratings, tags, shelves,
                                    series and read status. Reads both

    SHELF_EXIT_AFTER=<n> makes `import`, `send` and `organize` leave the
    process after n files, the way a crash does – it is how the proof run
    produces an interrupted import, an interrupted transfer and an interrupted
    organise.

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
case "merge-candidates": try await Commands.mergeCandidates(Array(arguments.dropFirst()))
case "similar-spellings": try await Commands.similarSpellings(Array(arguments.dropFirst()))
case "standardize-fields": try await Commands.standardizeFields(Array(arguments.dropFirst()))
case "rebuild": try await Commands.rebuild(Array(arguments.dropFirst()))
case "unshelve": try await Commands.unshelve(Array(arguments.dropFirst()))
case "shelve": try await Commands.shelve(Array(arguments.dropFirst()))
case "edit": try await Commands.edit(Array(arguments.dropFirst()))
case "show": try await Commands.show(Array(arguments.dropFirst()))
case "digest": try Commands.digest(Array(arguments.dropFirst()))
case "epub-roundtrip": try Commands.epubRoundtrip(Array(arguments.dropFirst()))
case "epub-metadata-patch": try Commands.epubMetadataPatch(Array(arguments.dropFirst()))
case "epub-cover-patch": try Commands.epubCoverPatch(Array(arguments.dropFirst()))
case "epub-cover-real-size": try Commands.epubCoverRealSize(Array(arguments.dropFirst()))
case "epub-file-replace-proof": try Commands.epubFileReplaceProof(Array(arguments.dropFirst()))
case "epub-write-fixture": try await Commands.epubWriteFixture(Array(arguments.dropFirst()))
case "epub-cover-write-fixture": try await Commands.epubCoverWriteFixture(Array(arguments.dropFirst()))
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
case "names": try await Commands.names(Array(arguments.dropFirst()))
case "merge": try await Commands.merge(Array(arguments.dropFirst()))
case "organize": try await Commands.organize(Array(arguments.dropFirst()))
case "organize-undo": try await Commands.organizeUndo(Array(arguments.dropFirst()))
case "export": try await Commands.export(Array(arguments.dropFirst()))
case "compare": try await Commands.compare(Array(arguments.dropFirst()))
case "first-titles": try await Commands.firstTitles(Array(arguments.dropFirst()))
case "set-author": try await Commands.setAuthor(Array(arguments.dropFirst()))
case "make-collision": try await Commands.makeCollision(Array(arguments.dropFirst()))
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
        // Into sub-folders, like the window's own folder drop: an exported
        // library is `Author/Title/book.epub`, and a one-level listing finds
        // nothing in it at all.
        let files = bookFiles(under: source)
        print("reading \(files.count) files from \(source.path)")

        var candidates: [ImportCandidate] = []
        for (number, url) in files.enumerated() {
            guard let candidate = try readCandidate(url, among: files) else { continue }
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

        // The shelves before the books, always. A book's OPF names its shelves
        // as paths, and the index resolves them against the shelves it has
        // been given and *skips what it cannot find* — so saving the books
        // first files every one of them nowhere, without an error (ADR 0008).
        // An archive export carries shelf paths in its OPFs, which is how a
        // re-import comes to need this at all.
        descriptor = try await registerShelves(
            named: Set(candidates.flatMap { $0.book.shelves }), in: library, descriptor: descriptor,
            index: index)

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

    /// What "Merge Books…" would offer, from the command line. Reads only —
    /// `MergeCandidates.certainGroups` is a pure function over what the index
    /// already holds.
    static func mergeCandidates(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool merge-candidates <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, _) = try Library.open(libraryURL)
        let index = try LibraryIndex(library: library)
        let entries = try await index.allEntries()
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let groups = MergeCandidates.certainGroups(among: entries)

        print("books: \(entries.count) · safe merge groups: \(groups.count)")
        let membersByGroup = groups.map { group in
            group.bookIDs.compactMap { byID[$0] }.sorted { $0.number < $1.number }
        }
        for members in membersByGroup.sorted(by: { ($0.first?.number ?? 0) < ($1.first?.number ?? 0) }) {
            print("  group of \(members.count):")
            for member in members {
                print(
                    "    \(member.number). \(member.book.title) — \(member.book.primaryAuthor)"
                        + " [\(member.formatLine)]")
            }
        }
        if groups.isEmpty { print("  (none)") }
    }

    /// What "Similar Spellings…" would propose, from the command line. Reads
    /// only — nothing here merges anything.
    static func similarSpellings(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool similar-spellings <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, _) = try Library.open(libraryURL)
        let index = try LibraryIndex(library: library)
        let entries = try await index.allEntries()
        let groups = SimilarSpellings.authorGroups(among: entries) + SimilarSpellings.publisherGroups(among: entries)

        print("books: \(entries.count) · proposed groups: \(groups.count)")
        for group in groups {
            print("  \(group.kind.label): \"\(group.winner)\" wins")
            for spelling in group.spellings {
                print("    \(spelling) (\(group.bookCounts[spelling] ?? 0))")
            }
        }
        if groups.isEmpty { print("  (none)") }
    }

    /// What "Standardize Fields…" would change, from the command line. Reads
    /// only — nothing here writes anything (Sprint 18, Teil C3).
    static func standardizeFields(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool standardize-fields <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let (library, _) = try Library.open(libraryURL)
        let index = try LibraryIndex(library: library)
        let entries = try await index.allEntries()
        let plan = FieldStandardization.plan(over: entries)

        print("books: \(entries.count) · would change: \(plan.bookCount)")
        for (entry, change) in plan.changes {
            print("  \(entry.book.title)")
            for field in change.fields {
                switch field {
                case .title: print("    title: \"\(change.before.title)\" → \"\(change.after.title)\"")
                case .language:
                    print(
                        "    language: \(change.before.language ?? "–") → \(change.after.language ?? "–")")
                case .identifiers:
                    let before = change.before.identifiers["isbn"] ?? "–"
                    let after = change.after.identifiers["isbn"] ?? "dropped"
                    print("    isbn: \(before) → \(after)")
                case .tags:
                    print(
                        "    tags: [\(change.before.tags.joined(separator: ", "))] → "
                            + "[\(change.after.tags.joined(separator: ", "))]")
                default: break
                }
            }
        }
        if plan.isEmpty { print("  (none)") }
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
        let plan = TransferPlanner.plan(
            candidates: candidates, device: device, manifest: manifest,
            onDevice: .onVolume(device.volume.url, makeHasher: PortableSHA256Hasher.factory))
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
        descriptor = try await registerShelves(
            named: Set(read.candidates.flatMap { $0.book.shelves }), in: library,
            descriptor: descriptor, index: index)

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
        // After the books, same as the app: an author has no row until a
        // book claims one.
        try await index.applyAuthorSortOverrides(descriptor.authorSortOverrides)
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
    // MARK: Ordering the library (Sprint 8)

    static func names(_ arguments: [String]) async throws {
        guard arguments.count >= 2, let kind = NameKind(rawValue: arguments[1]) else {
            print("usage: shelf-tool names <library> <author|series|publisher|tag>")
            exit(2)
        }
        let (_, index) = try openLibrary(arguments[0])
        let facets: [LibraryIndex.Facet]
        switch kind {
        case .author: facets = try await index.authorFacets()
        case .series: facets = try await index.seriesFacets()
        case .publisher: facets = try await index.publisherFacets()
        case .tag: facets = try await index.tagFacets()
        }
        print("\(facets.count) \(kind.pluralLabel.lowercased())")
        for facet in facets { print("  \(facet.count)\t\(facet.name)") }
    }

    /// Renames or merges names, through exactly the core the window uses.
    ///
    /// With no source spellings it is a dry run: it prints the plan and writes
    /// nothing, which is what the proof run checks before it checks the result.
    static func merge(_ arguments: [String]) async throws {
        guard arguments.count >= 3, let kind = NameKind(rawValue: arguments[1]) else {
            print("usage: shelf-tool merge <library> <author|series|publisher|tag> <target> <source>…")
            exit(2)
        }
        let (library, index) = try openLibrary(arguments[0])
        let merge = NameMerge(
            kind: kind, sources: Array(arguments.dropFirst(3)), target: arguments[2])

        let entries = try await index.allEntries()
        if merge.sources.isEmpty {
            // Nothing to fold: say what carries the target spelling today and
            // stop. A dry run writes nothing at all.
            let carrying = entries.count { kind.names(of: $0.book).contains(merge.trimmedTarget) }
            print("dry run · \(carrying) books already say “\(merge.trimmedTarget)” · nothing written")
            return
        }
        if let refusal = merge.refusal {
            print("refused: \(refusal)")
            exit(1)
        }

        let plan = NameEdit.plan(merge, over: entries)
        print("plan: \(plan.summary())")
        guard !plan.isEmpty else { return }

        let started = Date()
        let editor = MetadataEditor(library: library)
        for (entry, change) in plan.changes {
            _ = try await editor.apply(change, to: entry, in: index)
        }
        print(
            "\(merge.actionName): \(plan.bookCount) books · "
                + ImportReport.duration(Date().timeIntervalSince(started)))
        print("no folder was moved — that is `organize`")
    }

    /// The preview, and only with `--run` the moving.
    static func organize(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool organize <library> [--run]")
            exit(2)
        }
        let (library, index) = try openLibrary(path)
        let entries = try await index.allEntries()
        let root = library.root
        let folds = VolumeCase.folds(at: root)
        let plan = OrganizePlanner.plan(
            entries: entries, foldsCase: folds,
            folderExists: { OrganizeBookProbe.exists($0, under: root) },
            folderIsEmpty: { OrganizeBookProbe.isEmpty($0, under: root) },
            folderHoldsBook: { OrganizeBookProbe.holdsBook(at: $0, id: $1, under: root) })

        print("volume folds case: \(folds ? "yes" : "no")")
        // The cache being wrong about where a book is, is the cache's problem:
        // bring it level before anything else is decided.
        if !plan.relocated.isEmpty {
            try await writeFolders(plan.relocated.map { ($0.bookID, $0.folder) }, to: index)
            print("\(plan.relocated.count) books were already at their new folder — the index says so now")
        }
        print("plan: \(plan.summary())")
        for move in plan.moves.prefix(10) { print("  \(move.from)\n    → \(move.to)") }
        if plan.moves.count > 10 { print("  … \(plan.moves.count - 10) more") }
        for reason in BlockedBook.Reason.allCases {
            let group = plan.blocked(for: reason)
            guard !group.isEmpty else { continue }
            print("  \(reason.label): \(group.count)")
            for one in group.prefix(6) { print("    \(one.title) → \(one.wantedPath)") }
        }

        guard arguments.contains("--run") else {
            print("nothing was moved — add --run")
            return
        }

        let started = Date()
        let outcome = try await OrganizeRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(
                .init(library: library, plan: plan, manifest: OrganizeManifest.read(in: library)),
                progress: { progress in
                    // The untidy exit, exactly as `import` and `send` have one.
                    if let after = ProcessInfo.processInfo.environment["SHELF_EXIT_AFTER"]
                        .flatMap(Int.init), progress.done >= after
                    {
                        print("SHELF_EXIT_AFTER=\(after) – leaving the process now, mid-run")
                        exit(9)
                    }
                })

        // The folder first, the index second — always (ADR 0001).
        try await writeFolders(outcome.moved, to: index)
        try outcome.report.append(in: library)
        print(outcome.report.headline)
        print("took \(ImportReport.duration(Date().timeIntervalSince(started)))")
        for failure in outcome.report.failures { print("  FAILED \(failure.title): \(failure.message)") }
    }

    static func organizeUndo(_ arguments: [String]) async throws {
        guard let path = arguments.first else {
            print("usage: shelf-tool organize-undo <library>")
            exit(2)
        }
        let (library, index) = try openLibrary(path)
        let manifest = OrganizeManifest.read(in: library)
        guard !manifest.isEmpty || manifest.inFlight != nil else {
            print("no organise to undo — there is no manifest in this library")
            return
        }
        let outcome = try await OrganizeRunner(makeHasher: PortableSHA256Hasher.factory)
            .undo(manifest, in: library)
        try await writeFolders(outcome.moved, to: index)
        try outcome.report.append(in: library)
        print(outcome.report.headline)
        for failure in outcome.report.failures { print("  FAILED \(failure.title): \(failure.message)") }
    }

    /// Brings the index level with where the folders now are.
    private static func writeFolders(
        _ moved: [(bookID: UUID, folder: String)], to index: LibraryIndex
    ) async throws {
        for (bookID, folder) in moved {
            guard var entry = try await index.entry(id: bookID) else { continue }
            entry.folder = folder
            try await index.save(entry)
        }
    }

    static func export(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool export <library> <destination> [archive|books|calibre] [--flat] [--links]")
            exit(2)
        }
        let (library, index) = try openLibrary(arguments[0])
        let destination = URL(fileURLWithPath: arguments[1])
        let preset: ExportPreset =
            switch arguments.count > 2 ? arguments[2] : "archive" {
            case "books": .booksOnly
            case "calibre": .forCalibre
            default: .archive
            }
        var options = preset.options
        if arguments.contains("--flat") { options.structure = .flat }
        if arguments.contains("--links") { options.prefersHardLinks = true }
        if let refusal = options.refusal {
            print("refused: \(refusal)")
            exit(1)
        }

        let entries = try await index.allEntries()
        let previous = ExportManifest.read(at: destination)
        let plan = ExportPlanner.plan(
            entries: entries, libraryRoot: library.root, options: options, manifest: previous)
        print("preset: \(preset.label)")
        print("plan: \(plan.summary())")
        if plan.optionsChanged { print("  (the options differ from last time — everything is written again)") }

        let outcome = try await ExportRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(
                .init(destination: destination, plan: plan, libraryName: library.name),
                manifest: previous)
        print(outcome.report.headline)
        print("copied \(ByteCount.format(outcome.report.copiedBytes)) · hard links \(outcome.report.hardLinkCount)")
        for failure in outcome.report.failures { print("  FAILED \(failure.title): \(failure.message)") }
    }

    /// Whether two libraries really hold the same thing — the check the whole
    /// export exists to pass.
    ///
    /// Field by field rather than by a digest of everything: a single
    /// mismatched digest says "something differs" and this has to say *what*,
    /// or a failure is not actionable.
    static func compare(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool compare <one library> <other library>")
            exit(2)
        }
        let (_, one) = try openLibrary(arguments[0])
        let (_, other) = try openLibrary(arguments[1])
        let mine = try await one.allEntries()
        let theirs = try await other.allEntries()

        print("books: \(mine.count) and \(theirs.count)")
        var problems: [String] = []
        if mine.count != theirs.count { problems.append("the two hold a different number of books") }

        // By UUID, because that is the identity (CONCEPT §5.3) and the folder
        // names are exactly what an export is allowed to change.
        let byID = Dictionary(theirs.map { ($0.book.id, $0) }, uniquingKeysWith: { first, _ in first })
        var compared = 0
        for entry in mine {
            guard let match = byID[entry.book.id] else {
                problems.append("missing from the second library: \(entry.book.title)")
                continue
            }
            compared += 1
            let a = entry.book
            let b = match.book
            if a.title != b.title { problems.append("title differs: \(a.title) / \(b.title)") }
            if a.authors != b.authors { problems.append("authors differ: \(a.title)") }
            if a.rating != b.rating { problems.append("rating differs: \(a.title) (\(a.rating) / \(b.rating))") }
            if a.isRead != b.isRead { problems.append("read status differs: \(a.title)") }
            if a.series != b.series { problems.append("series differs: \(a.title)") }
            if a.shelves != b.shelves {
                problems.append("shelves differ: \(a.title) (\(a.shelves) / \(b.shelves))")
            }
            // A "for Calibre" export adds mapped tags on purpose, so the check
            // is that every tag of the original is still there.
            let missing = Set(a.tags).subtracting(Set(b.tags))
            if !missing.isEmpty { problems.append("tags missing: \(a.title) \(missing.sorted())") }
        }

        print("compared by UUID: \(compared)")
        if problems.isEmpty {
            print("the two libraries agree on titles, authors, ratings, read status, series, shelves and tags")
        } else {
            for problem in problems.prefix(30) { print("  \(problem)") }
            if problems.count > 30 { print("  … \(problems.count - 30) more") }
            exit(1)
        }
    }

    static func firstTitles(_ arguments: [String]) async throws {
        guard arguments.count >= 2, let count = Int(arguments[1]) else {
            print("usage: shelf-tool first-titles <library> <count>")
            exit(2)
        }
        let (_, index) = try openLibrary(arguments[0])
        for entry in try await firstBooks(count, in: index) { print(entry.book.title) }
    }

    static func setAuthor(_ arguments: [String]) async throws {
        guard arguments.count >= 3 else {
            print("usage: shelf-tool set-author <library> <title> <author>")
            exit(2)
        }
        let (library, index) = try openLibrary(arguments[0])
        let entry = try await findBook(arguments[1], in: index)
        // Through the field's own rules, not by assigning behind their back.
        guard case .changed(let edited) = BookField.authors.apply(arguments[2], to: entry.book) else {
            print("unchanged")
            return
        }
        let change = MetadataChange.make(from: entry.book) { $0 = edited }
        _ = try await MetadataEditor(library: library).apply(change, to: entry, in: index)
        print("“\(entry.book.title)”: authors → \(edited.authors.joined(separator: " & "))")
    }

    /// Puts something in the way of a book's target folder, so the organise
    /// preview has a real obstacle to name.
    ///
    /// **Why it is built this way, and not by giving two books one path.** A
    /// target path ends in the library's own running number — `Emma (17)` —
    /// and that number is `UNIQUE` in the index. So two *indexed* books can
    /// never want the same folder: the number is exactly what makes the name
    /// unique, which is why it is in the name at all (ADR 0002). The planner's
    /// `collision` and `caseOnlyCollision` guards are therefore defensive, and
    /// they are covered by unit tests that hand the planner the state directly.
    ///
    /// What *can* happen on a real disk, and what this builds, is a folder
    /// already sitting where a book wants to go: left by a killed run, made by
    /// hand in the Finder, or restored from a backup. Two shapes:
    ///
    /// * `exact` — a folder at the target path, with a file in it.
    /// * `case`  — a folder whose name differs from the target only in its
    ///   capitals. On this Mac that *is* the target folder; on a
    ///   case-sensitive volume it is a different folder and no obstacle at
    ///   all, which is the whole reason `VolumeCase` measures instead of
    ///   assuming.
    static func makeCollision(_ arguments: [String]) async throws {
        guard arguments.count >= 2, ["exact", "case"].contains(arguments[1]) else {
            print("usage: shelf-tool make-collision <library> exact|case")
            exit(2)
        }
        let (library, index) = try openLibrary(arguments[0])
        let entries = try await index.allEntries()

        // A book that is actually going to move — one already in the right
        // place would never ask about its destination.
        let folds = VolumeCase.folds(at: library.root)
        guard
            let victim = entries.first(where: {
                let target = OrganizePlanner.target(for: $0)
                return target != $0.folder
                    && !VolumeCase.isCaseOnly(from: $0.folder, to: target, folding: folds)
                    && !OrganizeBookProbe.exists(target, under: library.root)
            })
        else {
            print("no book in this library is due to move — run an edit first")
            exit(1)
        }

        let target = OrganizePlanner.target(for: victim)
        let inTheWay = arguments[1] == "exact" ? target : flippedCase(target)
        let url = library.root.appendingPathComponent(inTheWay, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("something somebody put here\n".utf8)
            .write(to: url.appendingPathComponent("not-a-book.txt"))

        print("\(arguments[1]): “\(victim.book.title)” wants \(target)")
        print("  and something is already at \(inTheWay)")
        if arguments[1] == "case" {
            print(
                "  this volume folds case: \(folds ? "yes — so that is the same folder" : "no — so it is a different one")"
            )
        }
    }

    /// The last path component with its capitals turned over, so the result
    /// differs from the original in nothing else.
    private static func flippedCase(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard let last = parts.popLast() else { return path }
        let flipped = String(
            last.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        return (parts + [flipped]).joined(separator: "/")
    }

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

    // MARK: epub-roundtrip

    /// The strict round trip (`docs/adr/0021-…`) against EPUBs nobody here
    /// wrote: read with `ZipReader`, every entry carried forward through
    /// `EPUBArchiveWriter` unchanged, written out, read again. `<folder>` is
    /// only ever read; the round-tripped copy is the only thing written, and
    /// it goes to `<output folder>`, never back over the original.
    static func epubRoundtrip(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool epub-roundtrip <folder> <output folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true)
        let output = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".epub") }.sorted() ?? []
        guard !names.isEmpty else {
            print("no .epub files in \(folder.path)")
            exit(2)
        }

        var allOK = true
        for name in names {
            let source = folder.appendingPathComponent(name)
            do {
                let before = try Data(contentsOf: source)
                let originalArchive = try ZipReader(data: before)
                let rewritten = try EPUBArchiveWriter.entries(rewriting: originalArchive)
                let after = try EPUBArchiveWriter.archive(rewritten)
                try after.write(to: output.appendingPathComponent(name))
                let roundTripped = try ZipReader(data: after)

                let ok = try Self.verifyRoundtrip(original: originalArchive, roundTripped: roundTripped, name: name)
                let deflated = originalArchive.files.filter { $0.method == .deflate }.count
                print(
                    "\(name): \(before.count) bytes before, \(after.count) bytes after, "
                        + "\(originalArchive.entries.count) entries, \(deflated) deflated, "
                        + "\(ok ? "identical ✓" : "MISMATCH")")
                allOK = allOK && ok
            } catch {
                print("\(name): FAILED – \(error)")
                allOK = false
            }
        }
        if !allOK { exit(1) }
    }

    /// Every entry the same path, the same decompressed bytes, and the same
    /// method – a DEFLATEd entry that came back stored would round-trip
    /// "successfully" by every other measure and still be the bug this
    /// writer exists to not have.
    private static func verifyRoundtrip(original: ZipReader, roundTripped: ZipReader, name: String) throws -> Bool {
        guard original.entries.map(\.path) == roundTripped.entries.map(\.path) else {
            print("  \(name): entry names differ")
            return false
        }
        var ok = true
        for entry in original.files {
            guard let rewrittenEntry = roundTripped.entry(at: entry.path) else { continue }
            if rewrittenEntry.method != entry.method {
                print("  \(name): \(entry.path) changed method (\(entry.method) → \(rewrittenEntry.method))")
                ok = false
            }
            if try original.data(for: entry) != (try roundTripped.data(for: rewrittenEntry)) {
                print("  \(name): \(entry.path) payload differs")
                ok = false
            }
        }
        return ok
    }

    // MARK: epub-metadata-patch

    /// The strict round trip, but with a real metadata change: title,
    /// authors and publisher patched via `EPUBOPFPatch`, proving Sprint
    /// 10's sharper claim — exactly one entry of the archive differs
    /// afterwards, and it reads back as what was written — against real
    /// books, not only synthetic ones.
    static func epubMetadataPatch(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool epub-metadata-patch <folder> <output folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true)
        let output = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".epub") }.sorted() ?? []
        guard !names.isEmpty else {
            print("no .epub files in \(folder.path)")
            exit(2)
        }

        var allOK = true
        for name in names {
            let source = folder.appendingPathComponent(name)
            do {
                let before = try Data(contentsOf: source)
                let originalArchive = try ZipReader(data: before)
                let read = EPUBMetadata.read(originalArchive, fallbackTitle: name)

                let fields = EPUBOPFPatch.Fields(
                    title: "[Shelf] " + read.book.title,
                    authors: read.book.authors.map { "[Shelf] " + $0 },
                    publisher: "[Shelf] " + (read.book.publisher ?? "Publisher"),
                    description: "[Shelf] a description this run added")

                let patched = try EPUBOPFPatch.entries(patching: fields, in: originalArchive, now: Date())
                let after = try EPUBArchiveWriter.archive(patched.entries)
                try after.write(to: output.appendingPathComponent(name))
                let result = try ZipReader(data: after)

                let outcome = try Self.verifyExactlyOneEntryDiffers(original: originalArchive, patched: result)
                let readBack = EPUBMetadata.read(result, fallbackTitle: name)
                let titleOK = readBack.book.title == fields.title
                let sizeDelta = after.count - before.count
                let sign = sizeDelta >= 0 ? "+" : ""
                var line = "\(name): \(before.count) bytes before, \(after.count) bytes after "
                line += "(archive \(sign)\(sizeDelta)), "
                line +=
                    "OPF \(outcome.opfBefore) → \(outcome.opfAfter) bytes (+\(outcome.opfAfter - outcome.opfBefore)), "
                line += "\(outcome.differing.count) entr\(outcome.differing.count == 1 ? "y" : "ies") differ "
                line += "(\(outcome.differing.joined(separator: ", "))), "
                line += "title read back \(titleOK ? "✓" : "✗ (\(readBack.book.title))")"
                if !patched.unwritten.isEmpty {
                    line += ", could not write: \(patched.unwritten.joined(separator: ", "))"
                }
                print(line)
                allOK = allOK && outcome.ok && titleOK
            } catch {
                print("\(name): FAILED – \(error)")
                allOK = false
            }
        }
        if !allOK { exit(1) }
    }

    // MARK: epub-cover-patch

    /// A small, valid-enough JPEG (magic number and an `FFD9` end marker;
    /// nothing here decodes it, so the pixels in between never matter) —
    /// shelf-tool's own synthetic cover, never a borrowed image
    /// (`CLAUDE.md`).
    static let syntheticJPEGCover = Data(
        [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01]
            + Array(repeating: UInt8(0x99), count: 512) + [0xFF, 0xD9])
    static let syntheticPNGCover = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: UInt8(0x33), count: 512))

    /// `EPUBCoverPatch`'s own claim (`docs/adr/0021-…`): a cover change
    /// touches exactly one entry when the manifest already names a cover of
    /// the same format, and exactly two — the image and the OPF — when the
    /// format changes and the media-type has to be corrected. Run twice per
    /// book: once with a cover in the book's own format, once with one in a
    /// different format, against real books nobody here wrote.
    static func epubCoverPatch(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool epub-cover-patch <folder> <output folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true)
        let output = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".epub") }.sorted() ?? []
        guard !names.isEmpty else {
            print("no .epub files in \(folder.path)")
            exit(2)
        }

        var allOK = true
        for name in names {
            let source = folder.appendingPathComponent(name)
            do {
                let before = try Data(contentsOf: source)
                let originalArchive = try ZipReader(data: before)

                let sameFormat = try EPUBCoverPatch.entries(
                    patchingCover: Self.syntheticJPEGCover, in: originalArchive)
                // `EPUBCoverPatch.Result.replacedExisting` is the ground
                // truth for which case a book fell into — not
                // `EPUBMetadata.read(…).cover != nil`, which was used here
                // until Sprint 11's own Fall-b proof against real, stripped
                // books found the two disagree: `EPUBMetadata`'s reader has
                // its own fallback ("no manifest cover → the first image in
                // the archive", for a hand-made EPUB or a comic with no
                // declaration at all), so a book with its cover declaration
                // removed but *some* other image still inside it read back
                // as "already has a cover" here while `EPUBCoverPatch`
                // itself correctly took the case b (add a new one) branch —
                // this command then checked case a's own entry count against
                // a case b result and failed for no real reason.
                let hadCover = sameFormat.replacedExisting

                let after = try EPUBArchiveWriter.archive(sameFormat.entries)
                try after.write(to: output.appendingPathComponent(name))
                let reread = try ZipReader(data: after)
                let differing = Self.differingFilePaths(original: originalArchive, patched: reread)
                let readBack = EPUBMetadata.read(reread, fallbackTitle: name)
                let coverOK = readBack.cover == Self.syntheticJPEGCover
                let entryCountOK =
                    hadCover
                    ? differing.count == 1 : reread.entries.count == originalArchive.entries.count + 1

                var crossFormatNote = ""
                var crossFormatOK = true
                if hadCover {
                    let crossFormat = try EPUBCoverPatch.entries(
                        patchingCover: Self.syntheticPNGCover, in: originalArchive)
                    let crossAfter = try EPUBArchiveWriter.archive(crossFormat.entries)
                    let crossReread = try ZipReader(data: crossAfter)
                    let crossDiffering = Self.differingFilePaths(original: originalArchive, patched: crossReread)
                    crossFormatOK = crossDiffering.count == 2 && crossFormat.mediaTypeCorrected != nil
                    let correction = crossFormat.mediaTypeCorrected.map { " (\($0.from) → \($0.to))" } ?? ""
                    crossFormatNote =
                        ", a different-format cover touches \(crossDiffering.count) entries\(correction)"
                }

                let sizeDelta = after.count - before.count
                let sign = sizeDelta >= 0 ? "+" : ""
                let percent = before.isEmpty ? 0 : Double(sizeDelta) / Double(before.count) * 100
                var line =
                    "\(name): case \(hadCover ? "a" : "b") (\(hadCover ? "already has a cover" : "no cover yet")), "
                line += "\(before.count) bytes before, \(after.count) bytes after (\(sign)\(sizeDelta), "
                line += String(format: "%+.2f%%), ", percent)
                line +=
                    "\(differing.count) entr\(differing.count == 1 ? "y" : "ies") differ (\(differing.joined(separator: ", ")))"
                line += crossFormatNote
                line += ", cover read back \(coverOK ? "✓" : "✗")"
                print(line)
                allOK = allOK && entryCountOK && coverOK && crossFormatOK
            } catch {
                print("\(name): FAILED – \(error)")
                allOK = false
            }
        }
        if !allOK { exit(1) }
    }

    // MARK: epub-cover-real-size

    /// Sprint 11's own follow-up to `epubCoverPatch` above: that command's
    /// own numbers are all measured against `syntheticJPEGCover`, 530-odd
    /// bytes — so every one of the six real books *shrank*, a number nobody
    /// would ever see in practice, since a real cover a person actually
    /// wants written is rarely smaller than what is already there. This
    /// command patches every book in `<folder>` with a REAL cover — read
    /// straight out of `<cover source.epub>` with `EPUBMetadata`, the same
    /// reader everything else in this project trusts — so the size delta
    /// printed is what a real cover replacement actually costs.
    static func epubCoverRealSize(_ arguments: [String]) throws {
        guard arguments.count >= 3 else {
            print("usage: shelf-tool epub-cover-real-size <cover source.epub> <folder> <output folder>")
            exit(2)
        }
        let coverSource = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath)
        let folder = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)
        let output = URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        guard let coverSourceData = try? Data(contentsOf: coverSource),
            let coverSourceArchive = try? ZipReader(data: coverSourceData),
            let realCover = EPUBMetadata.read(coverSourceArchive, fallbackTitle: coverSource.lastPathComponent).cover
        else {
            print("\(coverSource.path): no cover could be read from it")
            exit(2)
        }
        print("real cover: \(realCover.count) bytes, from \(coverSource.lastPathComponent)")

        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".epub") }.sorted() ?? []
        guard !names.isEmpty else {
            print("no .epub files in \(folder.path)")
            exit(2)
        }

        var allOK = true
        for name in names {
            let source = folder.appendingPathComponent(name)
            do {
                let before = try Data(contentsOf: source)
                let originalArchive = try ZipReader(data: before)
                let patched = try EPUBCoverPatch.entries(patchingCover: realCover, in: originalArchive)
                let after = try EPUBArchiveWriter.archive(patched.entries)
                try after.write(to: output.appendingPathComponent(name))
                let reread = try ZipReader(data: after)
                let readBack = EPUBMetadata.read(reread, fallbackTitle: name)
                let coverOK = !patched.changed || readBack.cover == realCover

                let sizeDelta = after.count - before.count
                let sign = sizeDelta >= 0 ? "+" : ""
                let percent = before.isEmpty ? 0 : Double(sizeDelta) / Double(before.count) * 100
                var line = "\(name): "
                if patched.changed {
                    line += "\(before.count) bytes before, \(after.count) bytes after (\(sign)\(sizeDelta), "
                    line += String(format: "%+.2f%%)", percent)
                } else {
                    line += "already had this exact cover — no change, nothing written (\(before.count) bytes)"
                }
                line += ", cover read back \(coverOK ? "✓" : "✗")"
                print(line)
                allOK = allOK && coverOK
            } catch {
                print("\(name): FAILED – \(error)")
                allOK = false
            }
        }
        if !allOK { exit(1) }
    }

    /// Every file entry present in both archives whose compressed bytes,
    /// method, CRC or uncompressed size differ — sorted, so two runs of
    /// this tool print the same order.
    private static func differingFilePaths(original: ZipReader, patched: ZipReader) -> [String] {
        var differing: [String] = []
        for entry in original.files {
            guard let patchedEntry = patched.entry(at: entry.path) else { continue }
            let originalPayload = try? original.compressedData(for: entry)
            let patchedPayload = try? patched.compressedData(for: patchedEntry)
            let same =
                entry.method == patchedEntry.method && entry.crc32 == patchedEntry.crc32
                && entry.uncompressedSize == patchedEntry.uncompressedSize && originalPayload == patchedPayload
            if !same { differing.append(entry.path) }
        }
        return differing.sorted()
    }

    // MARK: epub-file-replace-proof

    /// `EPUBFileReplacement`'s whole path, against copies of every real
    /// `.epub` in `<folder>` — never `<folder>` itself (`CLAUDE.md`: a
    /// Calibre-style source folder is only ever read). Two parts:
    ///
    /// 1. The whole path, once per book, **sequentially** — the same
    ///    requirement `EPUBFileReplacement`'s own doc comment states: a
    ///    caller replacing several books' files does them one at a time,
    ///    so the peak memory this run costs is one book's, not all six's.
    /// 2. Each of the four refusals, once, against a fresh copy of a real
    ///    book — and a check, after each, that exactly the original file
    ///    is what that refusal's own folder still holds. Plus the case
    ///    Korrektur 1 turned from a refusal into a fact: the Trash itself
    ///    declining, after the swap already put the book right.
    ///
    /// Uses the real `.trash` disposal throughout: this is the CLI process,
    /// not the `swift test` runner, and `FolderDisposal.trash` is reliable
    /// here (the runner-only `trashItem` failure this sprint found is
    /// documented in `CHANGELOG.md` and worked around in
    /// `EPUBFileReplacementTests` with a `Bin`, never here).
    static func epubFileReplaceProof(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            print("usage: shelf-tool epub-file-replace-proof <folder> <working folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true)
        let working = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath, isDirectory: true)

        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.lowercased().hasSuffix(".epub") }.sorted() ?? []
        guard !names.isEmpty else {
            print("no .epub files in \(folder.path)")
            exit(2)
        }

        var allOK = true
        print("— the whole path, \(names.count) real books, one at a time —")
        allOK = Self.wholeReplacePathProof(names: names, source: folder, working: working) && allOK
        print("")
        print("— the four refusals, plus the disposal-failure fact, each against a fresh copy —")
        allOK = Self.refusalProofs(sample: names[0], source: folder, working: working) && allOK
        if !allOK { exit(1) }
    }

    /// Section 1: `EPUBFileReplacement.replace` against a copy of each real
    /// book, one after another — never a `TaskGroup`, never `async let`,
    /// so nothing about this loop lets two books' archives be in memory
    /// at once.
    private static func wholeReplacePathProof(names: [String], source: URL, working: URL) -> Bool {
        let runFolder = working.appendingPathComponent("whole-path", isDirectory: true)
        try? FileManager.default.removeItem(at: runFolder)
        guard (try? FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)) != nil
        else {
            print("could not create \(runFolder.path)")
            return false
        }

        var allOK = true
        var verifiedInTrash = 0
        for name in names {
            let copy = runFolder.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: copy)
                let before = try Data(contentsOf: copy)
                let beforeDigest = FileDigest.sha256(of: before, makeHasher: PortableSHA256Hasher.factory)
                let originalArchive = try ZipReader(data: before)
                let read = EPUBMetadata.read(originalArchive, fallbackTitle: name)

                let fields = EPUBOPFPatch.Fields(
                    title: "[Shelf] " + read.book.title,
                    authors: read.book.authors.map { "[Shelf] " + $0 },
                    publisher: "[Shelf] " + (read.book.publisher ?? "Publisher"),
                    description: "[Shelf] written into the book by epub-file-replace-proof")
                let patched = try EPUBOPFPatch.entries(patching: fields, in: originalArchive, now: Date())
                let newContent = try EPUBArchiveWriter.archive(patched.entries)

                let result = try EPUBFileReplacement.replace(with: newContent, at: copy, bookID: UUID())
                let readBack = try EPUBMetadata.read(url: copy)
                let titleOK = readBack.book.title == fields.title

                // Korrektur 2: don't take "the Trash accepted it" on faith
                // — hash what actually landed there and check it against
                // what the folder held before, the same "copy, verify,
                // then trust" ADR 0002 asks of every other copy.
                var trashOK = true
                let trashLine: String
                switch result.originalDisposal {
                case .trashed(let trashedAt):
                    if let trashedAt, let trashedData = try? Data(contentsOf: trashedAt),
                        FileDigest.sha256(of: trashedData, makeHasher: PortableSHA256Hasher.factory) == beforeDigest
                    {
                        verifiedInTrash += 1
                        trashLine = "original in the Trash, hashed there and confirmed bit-identical ✓"
                    } else {
                        trashOK = false
                        trashLine = "✗ original said to be in the Trash but its hash there does not match"
                    }
                case .leftAsDebris(let debrisName, let reason):
                    // The book is still correct; this is the disposal
                    // itself declining, reported as a fact, not this run
                    // failing (Korrektur 1).
                    trashLine = "the Trash refused (\(reason)) — the old bytes are left as \(debrisName)"
                }

                print(
                    "\(name): \(before.count) → \(newContent.count) bytes, "
                        + "hash \(String(beforeDigest.prefix(10)))… → \(String(result.format.sha256.prefix(10)))…, "
                        + "read back \(titleOK ? "✓" : "✗ (\(readBack.book.title))"), \(trashLine)")
                allOK = allOK && titleOK && trashOK
            } catch {
                print("\(name): FAILED – \(error)")
                allOK = false
            }
        }
        print("original verified bit-identical in the Trash for \(verifiedInTrash) of \(names.count) books")
        return allOK
    }

    /// Section 2: the four refusals, each demonstrated once against a
    /// fresh copy of `sample` — a real book, not a synthetic fixture — and
    /// each followed by a check that the refusal's own folder holds
    /// exactly the original file afterwards: no `.part`, no half-result.
    /// Plus the one case that Korrektur 1 turned from a refusal into a
    /// fact: the Trash itself declining the old bytes, once the swap has
    /// already put the book right.
    private static func refusalProofs(sample: String, source: URL, working: URL) -> Bool {
        let runFolder = working.appendingPathComponent("refusals", isDirectory: true)
        try? FileManager.default.removeItem(at: runFolder)
        guard (try? FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)) != nil
        else {
            print("could not create \(runFolder.path)")
            return false
        }
        let original = source.appendingPathComponent(sample)

        var allOK = true
        allOK = Self.proveNotAnEPUBRefused(sample: original, in: runFolder) && allOK
        allOK = Self.proveDRMRefused(sample: original, in: runFolder) && allOK
        allOK = Self.proveReadOnlyRefused(sample: original, in: runFolder) && allOK
        allOK = Self.proveDisposalFailureIsAFact(sample: original, in: runFolder) && allOK
        allOK = Self.proveReadBackFailedRefused(sample: original, in: runFolder) && allOK
        return allOK
    }

    /// One book's copy, alone in its own numbered subfolder of `parent`, so
    /// "exactly the original file and nothing else" can be checked with a
    /// plain directory listing rather than having to name every sibling.
    private static func aloneCopy(of sample: URL, named name: String, in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(sample.lastPathComponent)
        try FileManager.default.copyItem(at: sample, to: copy)
        return copy
    }

    /// After a refusal, `folder` must hold exactly the one file the copy
    /// started as – the same bytes, and nothing named after
    /// `EPUBFileReplacement.partialPrefix` left behind.
    private static func onlyOriginalRemains(in folder: URL, name: String, unchangedFrom before: Data) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard names == [name] else {
            print("  ✗ \(folder.lastPathComponent): expected only \(name), found \(names)")
            return false
        }
        let after = try? Data(contentsOf: folder.appendingPathComponent(name))
        guard after == before else {
            print("  ✗ \(folder.lastPathComponent): \(name) changed")
            return false
        }
        return true
    }

    private static func proveNotAnEPUBRefused(sample: URL, in parent: URL) -> Bool {
        do {
            let copy = try Self.aloneCopy(of: sample, named: "not-an-epub", in: parent)
            // Truncated to a handful of bytes: still named `.epub`, no
            // longer a readable ZIP at all.
            try Data([0x50, 0x4B, 0x03, 0x04]).write(to: copy, options: .atomic)
            let before = try Data(contentsOf: copy)
            do {
                try EPUBFileReplacement.replace(with: Data(), at: copy, bookID: UUID())
                print("not-an-epub: ✗ did not refuse")
                return false
            } catch EPUBFileReplacement.Refusal.notAnEPUB {
                let ok = Self.onlyOriginalRemains(
                    in: copy.deletingLastPathComponent(), name: copy.lastPathComponent, unchangedFrom: before)
                print("not-an-epub: refused ✓, original intact \(ok ? "✓" : "✗")")
                return ok
            }
        } catch {
            print("not-an-epub: FAILED to set up – \(error)")
            return false
        }
    }

    private static func proveDRMRefused(sample: URL, in parent: URL) -> Bool {
        do {
            let copy = try Self.aloneCopy(of: sample, named: "drm-protected", in: parent)
            let archive = try ZipReader(url: copy)
            var entries = try EPUBArchiveWriter.entries(rewriting: archive)
            entries.append(.raw(path: "META-INF/encryption.xml", text: "<encryption/>"))
            try EPUBArchiveWriter.archive(entries).write(to: copy, options: .atomic)
            let before = try Data(contentsOf: copy)
            do {
                try EPUBFileReplacement.replace(with: Data(), at: copy, bookID: UUID())
                print("drm-protected: ✗ did not refuse")
                return false
            } catch EPUBFileReplacement.Refusal.drmProtected {
                let ok = Self.onlyOriginalRemains(
                    in: copy.deletingLastPathComponent(), name: copy.lastPathComponent, unchangedFrom: before)
                print("drm-protected: refused ✓, original intact \(ok ? "✓" : "✗")")
                return ok
            }
        } catch {
            print("drm-protected: FAILED to set up – \(error)")
            return false
        }
    }

    private static func proveReadOnlyRefused(sample: URL, in parent: URL) -> Bool {
        do {
            let copy = try Self.aloneCopy(of: sample, named: "read-only", in: parent)
            let folder = copy.deletingLastPathComponent()
            let before = try Data(contentsOf: copy)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

            guard !FileManager.default.isWritableFile(atPath: folder.path) else {
                print("read-only: skipped – this process can write through the permission bits (root?)")
                return true
            }
            do {
                try EPUBFileReplacement.replace(with: Data(), at: copy, bookID: UUID())
                print("read-only: ✗ did not refuse")
                return false
            } catch EPUBFileReplacement.Refusal.readOnlyVolume(let volume) {
                let ok = Self.onlyOriginalRemains(in: folder, name: copy.lastPathComponent, unchangedFrom: before)
                print("read-only: refused ✓ (“\(volume)”), original intact \(ok ? "✓" : "✗")")
                return ok
            }
        } catch {
            print("read-only: FAILED to set up – \(error)")
            return false
        }
    }

    /// Not a refusal any more (Korrektur 1): the swap has already put the
    /// book right by the time disposal is even attempted, so a Trash that
    /// declines the old bytes does not undo it. Proves the book is correct,
    /// and that the old bytes are still findable — under
    /// `EPUBFileReplacement.partialPrefix`, not silently gone — for the
    /// next call in that folder to sweep.
    private static func proveDisposalFailureIsAFact(sample: URL, in parent: URL) -> Bool {
        do {
            let copy = try Self.aloneCopy(of: sample, named: "disposal-fails", in: parent)
            let before = try Data(contentsOf: copy)
            let archive = try ZipReader(data: before)
            let read = EPUBMetadata.read(archive, fallbackTitle: copy.lastPathComponent)
            let fields = EPUBOPFPatch.Fields(title: "[Shelf] " + read.book.title)
            let patched = try EPUBOPFPatch.entries(patching: fields, in: archive, now: Date())
            let newContent = try EPUBArchiveWriter.archive(patched.entries)

            let result = try EPUBFileReplacement.replace(with: newContent, at: copy, bookID: UUID(), disposal: .none)
            guard case .leftAsDebris(let debrisName, let reason) = result.originalDisposal else {
                print("disposal-fails: ✗ expected .leftAsDebris, got \(result.originalDisposal)")
                return false
            }
            let bookOK = (try? Data(contentsOf: copy)) == newContent
            let folder = copy.deletingLastPathComponent()
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            let debrisIntact =
                names == [copy.lastPathComponent, debrisName]
                && (try? Data(contentsOf: folder.appendingPathComponent(debrisName))) == before
            print(
                "disposal-fails: not a refusal ✓ — book correct \(bookOK ? "✓" : "✗"), "
                    + "old bytes left as \(debrisName) (\(reason)), intact and alone \(debrisIntact ? "✓" : "✗")")
            return bookOK && debrisIntact
        } catch {
            print("disposal-fails: FAILED to set up – \(error)")
            return false
        }
    }

    private static func proveReadBackFailedRefused(sample: URL, in parent: URL) -> Bool {
        do {
            let copy = try Self.aloneCopy(of: sample, named: "read-back-fails", in: parent)
            let before = try Data(contentsOf: copy)
            // A "new" file that is a readable EPUB but a different, much
            // smaller book – the original's title and author do not come
            // back, so the read-back step has to catch it.
            let bareOPF = """
                <?xml version='1.0' encoding='utf-8'?>
                <package xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0" unique-identifier="id">
                  <metadata>
                    <dc:identifier id="id">urn:uuid:\(UUID().uuidString)</dc:identifier>
                  </metadata>
                  <manifest>
                    <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine><itemref idref="text"/></spine>
                </package>
                """
            let bareEntries: [ZipArchiveWriter.Entry] = [
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
                .raw(path: "OEBPS/content.opf", text: bareOPF),
                .raw(path: "OEBPS/text.xhtml", text: "<html><body><p>empty</p></body></html>"),
            ]
            let newContent = try EPUBArchiveWriter.archive(bareEntries)
            do {
                try EPUBFileReplacement.replace(with: newContent, at: copy, bookID: UUID())
                print("read-back-fails: ✗ did not refuse")
                return false
            } catch EPUBFileReplacement.Refusal.readBackFailed {
                let ok = Self.onlyOriginalRemains(
                    in: copy.deletingLastPathComponent(), name: copy.lastPathComponent, unchangedFrom: before)
                print("read-back-fails: refused ✓, original intact \(ok ? "✓" : "✗")")
                return ok
            }
        } catch {
            print("read-back-fails: FAILED to set up – \(error)")
            return false
        }
    }

    // MARK: epub-write-fixture

    /// Builds the small library `Scripts/write-into-book-shot.sh` screenshots
    /// "Write into the Book File" against: three ordinary EPUBs, one
    /// protected by Adobe DRM (refused before anything is written), and one
    /// with no `<dc:title>` element at all — the one real case
    /// `EPUBOPFPatch` never invents a title for, and the reason the sheet's
    /// "cannot be written" marker exists. One ordinary book is then edited
    /// in Shelf — publisher, language, published date, description — so it
    /// carries fields the book's own file does not yet, which is what the
    /// sheet's old→new list has something to show. Synthetic only
    /// (`CLAUDE.md`); nothing here is a borrowed book.
    static func epubWriteFixture(_ arguments: [String]) async throws {
        guard let folder = arguments.first else {
            print("usage: shelf-tool epub-write-fixture <library folder>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        let source = libraryURL.deletingLastPathComponent()
            .appendingPathComponent("epub-write-fixture-source", isDirectory: true)
        try? FileManager.default.removeItem(at: source)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        // Plain, short, hand-picked books — a screenshot needs titles a
        // reader can take in at a glance, not `SyntheticBooks`' own
        // edge-case ones (a title long enough to trip a file-name limit is
        // exactly what that generator is for).
        let ordinary = [
            Book(title: "The Glass Almanac", authors: ["Rosa Feldmann"]),
            Book(title: "Cinders and Salt", authors: ["Tomas Okafor"]),
            Book(title: "The Quiet Harbour", authors: ["Ingrid Solberg"]),
        ]
        var editedTitle = ""
        for book in ordinary {
            let epub = SyntheticEPUB(book: book).data()
            try epub.write(to: source.appendingPathComponent("\(book.title).epub"))
            if editedTitle.isEmpty { editedTitle = book.title }
        }

        let drmBook = Book(title: "A Protected Book", authors: ["Someone Protected"])
        try SyntheticEPUB.withAdobeDRM(book: drmBook).data()
            .write(to: source.appendingPathComponent("A Protected Book.epub"))

        try Self.noTitleEPUB(author: "A Nameless Author")
            .write(to: source.appendingPathComponent("Nameless.epub"))

        try await Self.importFolder([source.path, libraryURL.path])
        try? FileManager.default.removeItem(at: source)

        let (library, index) = try Self.openLibrary(libraryURL.path)
        let entry = try await Self.findBook(editedTitle, in: index)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let published = calendar.date(from: DateComponents(year: 2024, month: 3, day: 7))
        let change = MetadataChange.make(from: entry.book) {
            $0.publisher = "Erik & Erik Press"
            $0.language = "en"
            $0.published = published
            $0.description = "Added in Shelf, not yet in the book's own file."
        }
        let updated = try await MetadataEditor(library: library).apply(change, to: entry, in: index)

        // "The Quiet Harbour" is the book the DRM screenshot pairs with "A
        // Protected Book" — it needs one real difference of its own, or a
        // mixed selection has nothing left to write at all once a plan with
        // no actual change is correctly left alone (Sprint 10, Schritt E2
        // fix): a DRM refusal beside a book that would not change either is
        // not a mixed selection any screenshot can show as one.
        let harbourEntry = try await Self.findBook("The Quiet Harbour", in: index)
        let harbourChange = MetadataChange.make(from: harbourEntry.book) {
            $0.publisher = "Harbour House"
        }
        let updatedHarbour = try await MetadataEditor(library: library)
            .apply(harbourChange, to: harbourEntry, in: index)

        let noTitleEntry = try await Self.findBook("Nameless", in: index)
        print("epub-write-fixture: \(libraryURL.path)")
        print("  edited book, publisher/language/date/description now differ: “\(updated.book.title)”")
        print("  edited book, publisher now differs: “\(updatedHarbour.book.title)”")
        print("  DRM book, refused before anything is written: “A Protected Book”")
        print("  no-title book, title cannot be written: “\(noTitleEntry.book.title)”")
    }

    /// A small library for Sprint 11's own cover screenshots
    /// (`Scripts/write-into-book-cover-shot.sh`) — the three cover states
    /// "Write into the Book File" has to show: a cover Shelf would replace,
    /// a book with none of its own that Shelf could add one to, and a
    /// cover that already matches.
    static func epubCoverWriteFixture(_ arguments: [String]) async throws {
        guard arguments.count >= 4 else {
            print(
                "usage: shelf-tool epub-cover-write-fixture <library folder> <old.jpg> <new.jpg> <added.jpg>")
            exit(2)
        }
        let libraryURL = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath, isDirectory: true)
        let coverOld = try Data(contentsOf: URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath))
        let coverNew = try Data(contentsOf: URL(fileURLWithPath: (arguments[2] as NSString).expandingTildeInPath))
        let coverAdded = try Data(
            contentsOf: URL(fileURLWithPath: (arguments[3] as NSString).expandingTildeInPath))

        let source = libraryURL.deletingLastPathComponent()
            .appendingPathComponent("epub-cover-write-fixture-source", isDirectory: true)
        try? FileManager.default.removeItem(at: source)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let almanac = Book(title: "The Glass Almanac", authors: ["Rosa Feldmann"])
        try SyntheticEPUB(book: almanac, cover: coverOld).data()
            .write(to: source.appendingPathComponent("The Glass Almanac.epub"))

        // No cover at all in this one's own file.
        let cinders = Book(title: "Cinders and Salt", authors: ["Tomas Okafor"])
        try SyntheticEPUB(book: cinders).data()
            .write(to: source.appendingPathComponent("Cinders and Salt.epub"))

        let harbour = Book(title: "The Quiet Harbour", authors: ["Ingrid Solberg"])
        try SyntheticEPUB(book: harbour, cover: coverOld).data()
            .write(to: source.appendingPathComponent("The Quiet Harbour.epub"))

        try await Self.importFolder([source.path, libraryURL.path])
        try? FileManager.default.removeItem(at: source)

        let (library, index) = try Self.openLibrary(libraryURL.path)

        // "The Glass Almanac": a publisher edit, and its own cover.<ext> is
        // swapped for a different image after import — exactly what
        // `Replace Cover…` (ADR 0020) would leave behind, never written
        // into the book's own file until this command exists to ask for
        // it. The sheet's cover row and its publisher row show old → new
        // side by side, in the one sheet.
        let almanacEntry = try await Self.findBook("The Glass Almanac", in: index)
        let almanacChange = MetadataChange.make(from: almanacEntry.book) {
            $0.publisher = "Erik & Erik Press"
        }
        _ = try await MetadataEditor(library: library).apply(almanacChange, to: almanacEntry, in: index)
        let almanacFolder = library.root.appendingPathComponent(almanacEntry.folder, isDirectory: true)
        for existing in CoverFile.urls(in: almanacFolder) {
            try? FileManager.default.removeItem(at: existing)
        }
        try coverNew.write(to: almanacFolder.appendingPathComponent(CoverFile.name(for: coverNew)))

        // "Cinders and Salt": no cover in the book, but Shelf has one to
        // offer — added beside it exactly as `Download Cover…` would leave
        // one, never written into the book itself (Sprint 9's own rule).
        let cindersEntry = try await Self.findBook("Cinders and Salt", in: index)
        let cindersFolder = library.root.appendingPathComponent(cindersEntry.folder, isDirectory: true)
        try coverAdded.write(to: cindersFolder.appendingPathComponent(CoverFile.name(for: coverAdded)))

        // "The Quiet Harbour": untouched since import — its own cover.<ext>
        // is exactly what import extracted from the book, so the sheet's
        // cover row reads "already the same", and nothing else about this
        // book changed either.

        print("epub-cover-write-fixture: \(libraryURL.path)")
        print("  cover changed, alongside a field: “The Glass Almanac”")
        print("  no cover in the book, Shelf has one to offer: “Cinders and Salt”")
        print("  cover already the same, nothing else changed: “The Quiet Harbour”")
    }

    /// A minimal, valid EPUB with a `dc:creator` but no `dc:title` at all —
    /// built with `EPUBArchiveWriter` itself, not a second implementation.
    /// `SyntheticEPUB` always writes a title, on purpose (every fixture
    /// elsewhere needs one), so this one case is built by hand.
    private static func noTitleEPUB(author: String) throws -> Data {
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

    private static func verifyExactlyOneEntryDiffers(
        original: ZipReader, patched: ZipReader
    ) throws -> (
        ok: Bool, differing: [String], opfBefore: Int, opfAfter: Int
    ) {
        guard original.entries.map(\.path) == patched.entries.map(\.path) else {
            return (false, ["(entry list differs)"], 0, 0)
        }
        var differing: [String] = []
        var opfBefore = 0
        var opfAfter = 0
        for entry in original.files {
            guard let patchedEntry = patched.entry(at: entry.path) else { continue }
            let originalPayload = try original.compressedData(for: entry)
            let patchedPayload = try patched.compressedData(for: patchedEntry)
            let same =
                entry.method == patchedEntry.method && entry.crc32 == patchedEntry.crc32
                && entry.uncompressedSize == patchedEntry.uncompressedSize && originalPayload == patchedPayload
            if !same {
                differing.append(entry.path)
                opfBefore = originalPayload.count
                opfAfter = patchedPayload.count
            }
        }
        return (differing.count == 1, differing, opfBefore, opfAfter)
    }

    // MARK: Helpers

    /// Reads one file into a candidate: metadata, cover and digest.
    static func readCandidate(_ url: URL, among all: [URL] = []) throws -> ImportCandidate? {
        // `FileFacts` follows symlinks; `attributesOfItem` does not, and the
        // difference is a book imported with a size of eighty bytes.
        guard let format = BookFileFormat.of(url), let facts = FileFacts.of(url) else { return nil }
        let digest = try FileDigest.sha256(of: facts.url, makeHasher: PortableSHA256Hasher.factory)

        // One call for every format. This tool has no app layer, so PDF and
        // CBR come back as their file names with a warning saying why — which
        // is honest, and is what `BookFileReader` says of them.
        let read = BookFileReader.read(url: facts.url, format: format)

        // A `metadata.opf` beside the book outranks the book's own metadata:
        // it is the library's record, where the rating, the read status, the
        // tags and the shelves live (`SidecarMetadata`).
        let folder = url.deletingLastPathComponent()
        let siblings = all.filter { $0.deletingLastPathComponent() == folder }
        var book = read.book
        if let sidecar = SidecarMetadata.url(for: url, in: folder, siblings: siblings),
            let parsed = SidecarMetadata.read(at: sidecar)
        {
            book = SidecarMetadata.merged(parsed, over: read.book)
        }

        return ImportCandidate(
            source: facts.url, byteSize: facts.byteSize, format: format, sha256: digest, book: book,
            cover: read.cover, coverName: read.coverName, drm: read.drm, drmExamined: read.drmExamined,
            modifiedAt: facts.modifiedAt, warnings: read.warnings)
    }

    /// Every book file under a folder, however deep.
    ///
    /// Its own function, not a loop at the call site: `FileDirectoryEnumerator`
    /// cannot be iterated from an `async` context, and `nextObject()` in a
    /// plain function is the way round it that does not spawn anything.
    static func bookFiles(under source: URL) -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: source, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        while let next = walker.nextObject() as? URL {
            guard BookFileFormat.of(next) != nil else { continue }
            files.append(next)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Makes sure every shelf path the incoming books name exists, in
    /// `library.json` and in the index, **before** a book is saved.
    ///
    /// The shape of the shelves lives in `library.json` and membership lives
    /// in each book (ADR 0008), so a library receiving books that remember
    /// shelves it has never heard of has to be told about them first. The
    /// rebuild does exactly this, for exactly this reason.
    static func registerShelves(
        named paths: Set<String>, in library: Library, descriptor: LibraryDescriptor,
        index: LibraryIndex
    ) async throws -> LibraryDescriptor {
        guard !paths.isEmpty else { return descriptor }
        var tree = descriptor.shelfTree
        for path in paths.sorted() { _ = tree.ensure(path: path) }
        var updated = descriptor
        updated.shelves = tree.shelves
        try library.write(updated)
        try await index.saveShelves(updated.shelves)
        print("shelves registered before the books: \(updated.shelves.count)")
        return updated
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
