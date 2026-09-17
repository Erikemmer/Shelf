import Foundation
import Testing

@testable import ShelfCore

/// Folder and file names. A wrong name here is a book that cannot be found
/// again, and the index is rebuilt from these paths – so every rule has a test.
@Suite("Folder and file names")
struct BookFolderNameTests {

    @Test("the layout is Calibre's: author folder, title folder with a number")
    func layout() {
        let book = Book(title: "Pride and Prejudice", authors: ["Jane Austen"])
        #expect(BookFolderName.authorComponent(for: book) == "Austen, Jane")
        #expect(BookFolderName.titleComponent(for: book, number: 17) == "Pride and Prejudice (17)")
        #expect(BookFolderName.relativePath(for: book, number: 17) == "Austen, Jane/Pride and Prejudice (17)")
    }

    @Test("a book with no author is filed under Calibre's own word for it")
    func noAuthor() {
        let book = Book(title: "Beowulf")
        #expect(BookFolderName.authorComponent(for: book) == Book.unknownAuthor)
        #expect(BookFolderName.fileName(for: book, format: .epub) == "Beowulf - Unknown.epub")
    }

    @Test("the file is named the way Calibre names it")
    func fileName() {
        let book = Book(title: "Emma", authors: ["Jane Austen"])
        #expect(BookFolderName.fileName(for: book, format: .epub) == "Emma - Jane Austen.epub")
        #expect(BookFolderName.fileName(for: book, format: .azw3) == "Emma - Jane Austen.azw3")
    }

    // MARK: Characters that cannot be in a name
    //
    // The union of three file systems' rules, because one name has to survive
    // all of them: APFS, HFS, and the FAT32 every e-reader is formatted with.

    @Test("forbidden characters become a single space")
    func forbiddenCharacters() {
        // The colon goes too: the Finder shows it as a slash, and HFS treats it
        // as the separator, so "Vol. 1/2: A Book" loses both.
        #expect(BookFolderName.sanitised("Vol. 1/2: A Book", fallback: "x") == "Vol. 1 2 A Book")
        #expect(BookFolderName.sanitised("What? <Really>", fallback: "x") == "What Really")
        #expect(BookFolderName.sanitised("a\\b*c|d\"e", fallback: "x") == "a b c d e")
    }

    /// FAT silently drops trailing dots and spaces, so "Vol. 2 ." and "Vol. 2"
    /// would be the same folder and one book would land on top of the other.
    @Test("trailing dots and spaces are removed, because FAT drops them silently")
    func trailingDots() {
        #expect(BookFolderName.sanitised("Vol. 2 .", fallback: "x") == "Vol. 2")
        #expect(BookFolderName.sanitised("Book   ", fallback: "x") == "Book")
        #expect(BookFolderName.sanitised("Book...", fallback: "x") == "Book")
    }

    @Test("a leading dot is removed, so a book is not a hidden folder")
    func leadingDot() {
        #expect(BookFolderName.sanitised(".hidden", fallback: "x") == "hidden")
    }

    @Test("control characters and newlines go")
    func controlCharacters() {
        #expect(BookFolderName.sanitised("A\nB\tC", fallback: "x") == "A B C")
        #expect(BookFolderName.sanitised("A\u{0}B", fallback: "x") == "A B")
    }

    @Test("runs of whitespace collapse to one space")
    func whitespaceRuns() {
        #expect(BookFolderName.sanitised("A     B", fallback: "x") == "A B")
    }

    @Test("a name that sanitises to nothing falls back rather than vanishing")
    func emptyAfterSanitising() {
        #expect(BookFolderName.sanitised("///", fallback: "Untitled") == "Untitled")
        #expect(BookFolderName.sanitised("   ", fallback: "Untitled") == "Untitled")
        #expect(BookFolderName.sanitised("", fallback: "Untitled") == "Untitled")
    }

    @Test("a name Windows reserves gets an underscore rather than being unopenable")
    func reservedNames() {
        #expect(BookFolderName.sanitised("CON", fallback: "x") == "CON_")
        #expect(BookFolderName.sanitised("nul", fallback: "x") == "nul_")
        #expect(BookFolderName.sanitised("COM4", fallback: "x") == "COM4_")
        #expect(BookFolderName.sanitised("Console", fallback: "x") == "Console")
    }

    // MARK: Length
    //
    // 255 *bytes*, not characters: the limit is bytes on ext4 and HFS+, and a
    // German title in NFD or a title with emoji is longer than its character
    // count suggests.

    @Test("a long name is cut to 255 bytes, never in the middle of a character")
    func truncation() {
        let long = String(repeating: "ä", count: 400)  // two bytes each in UTF-8
        let cut = BookFolderName.truncated(long, toBytes: 255)
        #expect(cut.utf8.count <= 255)
        // Nothing broken in half: the result is still valid text of the same
        // character, which a byte-wise cut would not guarantee.
        #expect(cut.allSatisfy { $0 == "ä" })
    }

    @Test("the folder name leaves room for its number")
    func titleComponentLength() {
        let book = Book(title: String(repeating: "A", count: 400), authors: ["X"])
        let component = BookFolderName.titleComponent(for: book, number: 12_345)
        #expect(component.utf8.count <= BookFolderName.maxComponentBytes)
        #expect(component.hasSuffix(" (12345)"))
    }

    @Test("the file name leaves room for its extension")
    func fileNameLength() {
        let book = Book(title: String(repeating: "A", count: 400), authors: ["Jane Austen"])
        let name = BookFolderName.fileName(for: book, format: .epub)
        #expect(name.utf8.count <= BookFolderName.maxComponentBytes)
        #expect(name.hasSuffix(".epub"))
    }

    @Test("a cut never leaves a trailing space, which FAT would drop anyway")
    func truncationTrailingSpace() {
        #expect(!BookFolderName.truncated("AAAA BBBB", toBytes: 5).hasSuffix(" "))
        #expect(BookFolderName.truncated("anything", toBytes: 0).isEmpty)
    }
}

@Suite("How titles and names sort")
struct SortingTests {

    /// A library that puts "The Hobbit" under T is a library nobody can find
    /// anything in.
    @Test("a leading article moves to the end")
    func titleSort() {
        #expect(TitleSort.of("The Hobbit") == "Hobbit, The")
        #expect(TitleSort.of("A Memory Called Empire") == "Memory Called Empire, A")
        #expect(TitleSort.of("An Unkindness of Ghosts") == "Unkindness of Ghosts, An")
    }

    @Test("German, French, Spanish, Italian and Dutch articles move too")
    func titleSortOtherLanguages() {
        #expect(TitleSort.of("Der Prozess") == "Prozess, Der")
        #expect(TitleSort.of("Die Verwandlung") == "Verwandlung, Die")
        #expect(TitleSort.of("Le Petit Prince") == "Petit Prince, Le")
        #expect(TitleSort.of("El Aleph") == "Aleph, El")
        #expect(TitleSort.of("Il Gattopardo") == "Gattopardo, Il")
        #expect(TitleSort.of("Het Achterhuis") == "Achterhuis, Het")
    }

    @Test("a title that is only an article keeps it, or nothing would be left")
    func titleThatIsJustAnArticle() {
        #expect(TitleSort.of("The") == "The")
        #expect(TitleSort.of("The ") == "The")
    }

    @Test("a title with no article is unchanged")
    func noArticle() {
        #expect(TitleSort.of("Piranesi") == "Piranesi")
        #expect(TitleSort.of("Thermonuclear Astrophysics") == "Thermonuclear Astrophysics")
    }

    @Test("authors are filed by surname, like a catalogue")
    func authorSort() {
        #expect(AuthorSort.of("Jane Austen") == "Austen, Jane")
        #expect(AuthorSort.of("Ursula K. Le Guin") == "Guin, Ursula K. Le")
        #expect(AuthorSort.of("Homer") == "Homer")
    }

    /// "Martin Luther King Jr." sorts under King, not under Jr.
    @Test("a generational suffix is part of the name, not the surname")
    func authorSortSuffixes() {
        #expect(AuthorSort.of("Martin Luther King Jr.") == "King, Martin Luther Jr.")
        #expect(AuthorSort.of("John Smith III") == "Smith, John III")
    }

    /// Found by importing seventeen real books: shop EPUBs write `dc:creator`
    /// both ways, and sorting an already-sorted name turned "McFadden, Freida"
    /// into "Freida, McFadden," – and with it the folder the book lives in.
    @Test("a name that already has a comma is already sorted, and is left alone")
    func authorSortAlreadySorted() {
        #expect(AuthorSort.of("McFadden, Freida") == "McFadden, Freida")
        #expect(AuthorSort.of("Austen, Jane") == "Austen, Jane")
        #expect(AuthorSort.of("King, Martin Luther Jr.") == "King, Martin Luther Jr.")
        // Whitespace is still tidied, so two spellings of one name are one name.
        #expect(AuthorSort.of("  McFadden,   Freida  ") == "McFadden, Freida")
    }

    @Test("sorting a name twice gives the same answer as sorting it once")
    func authorSortIsIdempotent() {
        for name in ["Jane Austen", "Ursula K. Le Guin", "Homer", "Martin Luther King Jr."] {
            #expect(AuthorSort.of(AuthorSort.of(name)) == AuthorSort.of(name))
        }
    }

    @Test("a series shows its index the way a reader writes it")
    func seriesDisplay() {
        #expect(SeriesRef(name: "Mistborn", index: 3).display == "Mistborn #3")
        #expect(SeriesRef(name: "Mistborn", index: 3.5).display == "Mistborn #3.5")
        #expect(SeriesRef(name: "Mistborn").display == "Mistborn")
    }

    @Test("the author line says who wrote it without becoming a list of six")
    func authorLine() {
        #expect(Book(title: "x", authors: ["A"]).authorLine == "A")
        #expect(Book(title: "x", authors: ["A", "B"]).authorLine == "A & B")
        #expect(Book(title: "x", authors: ["A", "B", "C"]).authorLine == "A et al.")
        #expect(Book(title: "x").authorLine == Book.unknownAuthor)
    }

    @Test("the sort orders the table offers put books without a series last")
    func sqlOrders() {
        // The clause itself is checked by LibraryIndexTests against real rows;
        // this is the part that is easy to get wrong by eye.
        #expect(BookSort.series.sqlOrder(ascending: true).contains("IS NULL"))
        #expect(BookSort.series.sqlOrder(ascending: false).contains("IS NULL"))
        #expect(BookSort.allCases.allSatisfy { !$0.label.isEmpty })
        // Every order ends in the title, so two books that tie keep a fixed
        // order instead of reshuffling on every reload.
        #expect(BookSort.allCases.allSatisfy { $0.sqlOrder(ascending: true).contains("title_sort") })
    }

    /// A field's own preference decides what one click gives; both directions
    /// are always offered.
    @Test("a name sorts A–Z first, a date and a rating the other way")
    func preferredDirections() {
        #expect(BookOrder(.title).ascending)
        #expect(BookOrder(.author).ascending)
        #expect(!BookOrder(.added).ascending)
        #expect(!BookOrder(.rating).ascending)
        #expect(BookOrder(.added).reversed.ascending)
        #expect(BookOrder(.title).label == "Title ↑")
    }
}

@Suite("Formats")
struct BookFileFormatTests {

    @Test("a file's extension names its format, in any case")
    func fromExtension() {
        #expect(BookFileFormat.from(fileExtension: "epub") == .epub)
        #expect(BookFileFormat.from(fileExtension: "EPUB") == .epub)
        #expect(BookFileFormat.from(fileExtension: "azw3") == .azw3)
        #expect(BookFileFormat.from(fileExtension: "txt") == nil)
        #expect(BookFileFormat.of(URL(fileURLWithPath: "/x/Book.CBZ")) == .cbz)
    }

    @Test("EPUB wins when a book has several formats")
    func preference() {
        #expect(BookFileFormat.epub < BookFileFormat.azw3)
        #expect(BookFileFormat.azw3 < BookFileFormat.mobi)
        #expect([BookFileFormat.pdf, .epub, .mobi].min() == .epub)
    }

    /// The one place Sprint 4 was always going to change, and it has: Sprint 1
    /// read EPUB only, and every format but KFX is read now.
    ///
    /// KFX stays false, and not as an omission. Its container is undocumented,
    /// so a parser written against guesses would be wrong in ways nobody could
    /// see — the file is carried by name and size instead, which is the honest
    /// answer (ADR 0011).
    @Test("every format but KFX has readable metadata")
    func readableMetadata() {
        for format in BookFileFormat.allCases where format != .kfx {
            #expect(format.hasReadableMetadata, "\(format.label) should be readable in Sprint 4")
            #expect(format.hasReadableCover, "\(format.label) should give a cover in Sprint 4")
        }
        #expect(!BookFileFormat.kfx.hasReadableMetadata)
        #expect(!BookFileFormat.kfx.hasReadableCover)
        #expect(BookFileFormat.kfx.unreadableNote != nil)
    }

    /// The table that says which half of the program reads a format, and it is
    /// a real claim: the core has to build and pass on Linux, so anything
    /// needing PDFKit or libarchive is the app's.
    @Test("PDF and CBR are read in the app layer, everything else in the core")
    func readerLayers() {
        #expect(BookFileFormat.epub.readerLayer == .core)
        #expect(BookFileFormat.kepub.readerLayer == .core)
        #expect(BookFileFormat.mobi.readerLayer == .core)
        #expect(BookFileFormat.azw3.readerLayer == .core)
        #expect(BookFileFormat.cbz.readerLayer == .core)
        #expect(BookFileFormat.pdf.readerLayer == .app)
        #expect(BookFileFormat.cbr.readerLayer == .app)
        #expect(BookFileFormat.kfx.readerLayer == .none)

        // And the two tables agree: nothing is readable with no reader, and
        // nothing has a reader while claiming to be unreadable.
        for format in BookFileFormat.allCases {
            #expect(
                format.hasReadableMetadata == (format.readerLayer != .none),
                "\(format.label): hasReadableMetadata and readerLayer disagree")
        }
    }

    @Test("KFX is listed rather than left out, so a file is named and not lost")
    func kfx() {
        #expect(BookFileFormat.from(fileExtension: "kfx") == .kfx)
        #expect(!BookFileFormat.importable.contains(.kfx))
    }

    /// One window wrote "epub" in the sidebar and "EPUB" in the inspector,
    /// because both call sites spelled the format themselves. There is one
    /// spelling now and every case has it.
    @Test("a format is written in capitals wherever a person reads it")
    func label() {
        #expect(BookFileFormat.epub.label == "EPUB")
        #expect(BookFileFormat.azw3.label == "AZW3")
        #expect(BookFileFormat.kepub.label == "KEPUB")
        for format in BookFileFormat.allCases {
            #expect(format.label == format.label.uppercased())
            #expect(!format.label.isEmpty)
        }
    }
}

@Suite("The cover next to a book")
struct CoverFileTests {

    @Test("the extension comes from the bytes, not from what the EPUB claimed")
    func sniffing() {
        #expect(
            CoverFile.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 12)))
                == "jpg")
        #expect(CoverFile.fileExtension(for: MinimalPNG.cover(width: 4, height: 4, seed: 1)) == "png")
        #expect(CoverFile.fileExtension(for: Data("GIF89a".utf8) + Data(repeating: 0, count: 12)) == "gif")
        #expect(
            CoverFile.fileExtension(for: Data("RIFF".utf8) + Data([1, 2, 3, 4]) + Data("WEBP".utf8)) == "webp")
    }

    @Test("unknown content is still kept, under the name ImageIO tries first")
    func unknownContent() {
        #expect(CoverFile.fileExtension(for: Data(repeating: 0x42, count: 32)) == nil)
        #expect(CoverFile.name(for: Data(repeating: 0x42, count: 32)) == "cover.jpg")
    }

    @Test("data too short to have a magic number is not guessed at")
    func tooShort() {
        #expect(CoverFile.fileExtension(for: Data([0xFF, 0xD8])) == nil)
        #expect(CoverFile.fileExtension(for: Data()) == nil)
    }

    @Test("the cover in a folder is found whatever its extension")
    func findingIt() throws {
        let folder = try TemporaryFolder()
        let bookFolder = try folder.folder("book")
        #expect(CoverFile.url(in: bookFolder) == nil)
        try folder.write("book/cover.png", data: Data([1]))
        #expect(CoverFile.url(in: bookFolder)?.lastPathComponent == "cover.png")
    }

    @Test("a cover file is not mistaken for part of the book")
    func isCover() {
        #expect(CoverFile.isCover("cover.jpg"))
        #expect(CoverFile.isCover("COVER.PNG"))
        #expect(!CoverFile.isCover("cover.epub"))
        #expect(!CoverFile.isCover("front.jpg"))
    }
}

@Suite("Shelves")
struct ShelfTreeTests {

    /// Hierarchical, decided in CONCEPT §15: a shelf may sit inside another,
    /// the way a bookcase works.
    @Test("a shelf knows its children and its path")
    func hierarchy() {
        let fiction = Shelf(name: "Fiction")
        let scifi = Shelf(name: "Science Fiction", parentID: fiction.id)
        let opera = Shelf(name: "Space Opera", parentID: scifi.id)
        let tree = ShelfTree([opera, scifi, fiction])

        #expect(tree.children(of: nil).map(\.name) == ["Fiction"])
        #expect(tree.children(of: fiction.id).map(\.name) == ["Science Fiction"])
        #expect(tree.path(of: opera.id) == "Fiction ▸ Science Fiction ▸ Space Opera")
        #expect(Set(tree.subtree(of: fiction.id)) == Set([fiction.id, scifi.id, opera.id]))
    }

    @Test("siblings keep their hand-given order")
    func ordering() {
        let a = Shelf(name: "Zebra", position: 0)
        let b = Shelf(name: "Aardvark", position: 1)
        #expect(ShelfTree([b, a]).children(of: nil).map(\.name) == ["Zebra", "Aardvark"])
    }

    /// A loop would make a tree the sidebar could not draw and the subtree walk
    /// could not finish.
    @Test("a shelf cannot be moved inside itself or inside its own child")
    func noCycles() {
        let fiction = Shelf(name: "Fiction")
        let scifi = Shelf(name: "Science Fiction", parentID: fiction.id)
        let tree = ShelfTree([fiction, scifi])

        #expect(!tree.canMove(fiction.id, under: fiction.id))
        #expect(!tree.canMove(fiction.id, under: scifi.id))
        #expect(tree.canMove(scifi.id, under: nil))
    }

    /// A tree that already has a loop – from a corrupt file – must not hang the
    /// app while it is being reported.
    @Test("a tree that already contains a loop still terminates")
    func existingCycleTerminates() {
        let a = UUID()
        let b = UUID()
        let tree = ShelfTree([
            Shelf(id: a, name: "A", parentID: b),
            Shelf(id: b, name: "B", parentID: a),
        ])
        #expect(!tree.path(of: a).isEmpty)
        // Each shelf once, not once per lap.
        #expect(tree.subtree(of: a).count == 2)
    }
}

@Suite("Smart collections and filters")
struct SmartCollectionTests {

    private func entry(read: Bool = false, added: Date = Date(), tags: [String] = []) -> LibraryEntry {
        LibraryEntry(
            book: Book(title: "A Book", authors: ["An Author"], isRead: read, tags: tags, addedAt: added),
            number: 1, folder: "An Author/A Book (1)",
            formats: [
                BookFormat(bookID: UUID(), format: .epub, fileName: "a.epub", byteSize: 1, sha256: "x")
            ])
    }

    @Test("Unread is the books not marked read")
    func unread() {
        #expect(SmartCollection.unread.contains(entry(read: false)))
        #expect(!SmartCollection.unread.contains(entry(read: true)))
    }

    @Test("Recently Added reaches back thirty days")
    func recentlyAdded() {
        let now = Date()
        #expect(SmartCollection.recentlyAdded.contains(entry(added: now), now: now))
        let old = now.addingTimeInterval(-40 * 86_400)
        #expect(!SmartCollection.recentlyAdded.contains(entry(added: old), now: now))
    }

    /// Whether a cover file exists is a fact about the disk, so it is passed
    /// in – a column holding it would be a second copy that can go stale.
    @Test("Missing Cover is answered from what is on disk")
    func missingCover() {
        let book = entry()
        #expect(SmartCollection.missingCover.contains(book, coversOnDisk: []))
        #expect(!SmartCollection.missingCover.contains(book, coversOnDisk: [book.id]))
    }

    @Test("a filter narrows the collection by tag, author, series and format")
    func filtering() {
        let book = entry(tags: ["science fiction"])
        #expect(LibraryFilter.everything.matches(book))
        #expect(LibraryFilter(tag: "science fiction").matches(book))
        #expect(!LibraryFilter(tag: "romance").matches(book))
        #expect(LibraryFilter(author: "An Author").matches(book))
        #expect(!LibraryFilter(author: "Someone Else").matches(book))
        #expect(LibraryFilter(format: .epub).matches(book))
        #expect(!LibraryFilter(format: .pdf).matches(book))
    }

    @Test("the filter says whether it is narrowing, for the status bar")
    func isNarrowed() {
        #expect(!LibraryFilter.everything.isNarrowed)
        #expect(LibraryFilter(tag: "x").isNarrowed)
        #expect(LibraryFilter(searchText: "dune").isNarrowed)
        #expect(!LibraryFilter(searchText: "   ").isNarrowed)
    }

    @Test("the filter names what is being shown")
    func title() {
        #expect(LibraryFilter.everything.title == "All Books")
        #expect(LibraryFilter(tag: "science fiction").title == "science fiction")
        #expect(LibraryFilter(collection: .unread).title == "Unread")
    }

    @Test("every collection has a name and an icon, so none can be drawn blank")
    func allHaveLabels() {
        for collection in SmartCollection.allCases {
            #expect(!collection.title.isEmpty)
            #expect(!collection.icon.isEmpty)
        }
        #expect(SmartCollection.allCases.count == 6)
    }
}
