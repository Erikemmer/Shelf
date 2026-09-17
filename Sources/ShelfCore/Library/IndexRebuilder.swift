import Foundation

/// Rebuilds the index by walking the library folder.
///
/// This type is the proof behind ADR 0001: if it works, the index can be
/// deleted at any time and nothing is lost, which is what lets the index be a
/// cache – opened in WAL mode, erased after a crash, vacuumed, replaced by a
/// newer schema – rather than the user's data.
///
/// It reads `metadata.opf` for each book and falls back to the book file and
/// then to the file name. It never writes a book file, and it never deletes
/// anything: a folder it cannot make sense of is reported, not tidied away.
public struct IndexRebuilder: Sendable {
    /// What one walk of the folders found.
    public struct Result: Sendable {
        public var entries: [LibraryEntry]
        /// Folders that hold no readable book – reported so the user can look,
        /// never removed.
        public var unreadableFolders: [String]
        /// Books whose OPF was missing or unreadable, so their metadata came
        /// from the file instead.
        public var withoutOPF: [String]
        /// Every shelf path any book named, so the caller can make sure the
        /// tree in `library.json` holds them before the entries are saved.
        ///
        /// The *membership* is not here: it is in each book (`Book.shelves`),
        /// read back out of its `metadata.opf` like every other field. This is
        /// only the list of names a rebuild has to be able to file them under —
        /// a library restored without its `.shelf` folder has books that
        /// remember their shelves and a `library.json` that does not.
        public var shelfPathsSeen: Set<String>
        /// The highest folder number found, so the library's counter can be
        /// repaired if `library.json` was lost.
        public var highestNumber: Int

        public init(
            entries: [LibraryEntry] = [], unreadableFolders: [String] = [], withoutOPF: [String] = [],
            shelfPathsSeen: Set<String> = [], highestNumber: Int = 0
        ) {
            self.entries = entries
            self.unreadableFolders = unreadableFolders
            self.withoutOPF = withoutOPF
            self.shelfPathsSeen = shelfPathsSeen
            self.highestNumber = highestNumber
        }
    }

    private let makeHasher: HasherFactory

    public init(makeHasher: @escaping HasherFactory) {
        self.makeHasher = makeHasher
    }

    /// Walks `Author/Title (n)/` two levels deep and reads what is there.
    ///
    /// Exactly two levels, because that is the layout (CONCEPT §5.1). A
    /// recursive walk would also find the books inside a folder somebody
    /// dropped into the library by hand, and then two runs would disagree about
    /// where a book lives.
    ///
    /// `rehash` is off by default: hashing 8 000 files is minutes of disk, and
    /// on a rebuild the size and modification date are enough to tell whether a
    /// stored digest still applies. The import, where the digest decides
    /// whether a file is a duplicate, always hashes.
    public func rebuild(
        _ library: Library,
        knownDigests: [String: String] = [:],
        progress: @Sendable (Int, String) -> Void = { _, _ in }
    ) throws -> Result {
        var result = Result()
        let manager = FileManager.default

        let authorFolders =
            try manager
            .contentsOfDirectory(at: library.root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
            .filter { $0.hasDirectoryPath && $0.lastPathComponent != Library.privateFolderName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var scanned = 0
        for authorFolder in authorFolders {
            let bookFolders =
                (try? manager.contentsOfDirectory(
                    at: authorFolder, includingPropertiesForKeys: [.isDirectoryKey], options: []))?
                .filter(\.hasDirectoryPath)
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

            for bookFolder in bookFolders {
                if Task.isCancelled { return result }
                let relative = "\(authorFolder.lastPathComponent)/\(bookFolder.lastPathComponent)"
                scanned += 1
                progress(scanned, relative)

                guard let found = try readFolder(bookFolder, relative: relative, knownDigests: knownDigests) else {
                    result.unreadableFolders.append(relative)
                    continue
                }
                result.entries.append(found.entry)
                if !found.hadOPF { result.withoutOPF.append(relative) }
                result.shelfPathsSeen.formUnion(found.entry.book.shelves)
                result.highestNumber = max(result.highestNumber, found.entry.number)
            }
        }
        return result
    }

    /// One book's folder, read exactly as a full rebuild reads it.
    ///
    /// Public because a resumed import adopts a leftover folder through it
    /// (`OrphanedFolders.adopt`): the entry that goes into the index for a
    /// folder the last run left behind has to be the same entry a rebuild would
    /// make of it, or the two would disagree about the same folder.
    public func readFolder(
        _ folder: URL, relative: String, knownDigests: [String: String] = [:]
    ) throws -> (entry: LibraryEntry, hadOPF: Bool)? {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []

        // A folder without a book file is not a book, whatever else is in it.
        let bookFiles = names.compactMap { name -> (String, BookFileFormat)? in
            guard let format = BookFileFormat.from(fileExtension: (name as NSString).pathExtension) else {
                return nil
            }
            return (name, format)
        }
        guard !bookFiles.isEmpty else { return nil }

        let number = Self.number(in: folder.lastPathComponent)

        // The OPF is the authority: it carries the UUID, and the UUID is the
        // book's identity across a rebuild (CONCEPT §5.3).
        var book: Book
        var hadOPF = false
        let opfURL = folder.appendingPathComponent(OPFDocument.fileName)
        if let data = try? Data(contentsOf: opfURL),
            let parsed = try? OPFDocument.read(data, fallbackTitle: Self.title(in: folder.lastPathComponent))
        {
            book = parsed.book
            hadOPF = true
        } else if let readable = bookFiles.sorted(by: { $0.1 < $1.1 })
            .first(where: { $0.1.readerLayer == .core }),
            case let read = BookFileReader.read(
                url: folder.appendingPathComponent(readable.0), format: readable.1, readCover: false),
            read.fromTheFile
        {
            // The book file itself, when there is no OPF. Sorted by preference
            // first, so a folder holding both an EPUB and a MOBI is described
            // by the EPUB — the same order the planner uses, so a rebuild and
            // an import cannot disagree about the same folder.
            //
            // Only the formats the *core* reads. A rebuild must give the same
            // answer on Linux as on this Mac, and asking PDFKit here would make
            // that untrue; a folder holding only a PDF falls through to the
            // folder name, which its OPF will normally have saved it from.
            book = read.book
        } else {
            // Last resort, and still a book: the folder name is
            // `Title (17)` and its parent is the author.
            book = Book(
                title: Self.title(in: folder.lastPathComponent),
                authors: [folder.deletingLastPathComponent().lastPathComponent])
        }

        var formats: [BookFormat] = []
        for (name, format) in bookFiles.sorted(by: { $0.0 < $1.0 }) {
            let url = folder.appendingPathComponent(name)
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                let byteSize = attributes[.size] as? Int64,
                let modified = attributes[.modificationDate] as? Date
            else { continue }

            // The digest is reused when the file has not changed. The key
            // carries size and date for exactly that reason: a file replaced
            // under the same name misses and is hashed again.
            let cacheKey = "\(relative)/\(name)|\(byteSize)|\(Int64(modified.timeIntervalSince1970))"
            let digest = try knownDigests[cacheKey] ?? FileDigest.sha256(of: url, makeHasher: makeHasher)

            formats.append(
                BookFormat(
                    bookID: book.id, format: format, fileName: name, byteSize: byteSize,
                    sha256: digest, modifiedAt: modified))
        }
        guard !formats.isEmpty else { return nil }

        return (
            LibraryEntry(book: book, number: number, folder: relative, formats: formats),
            hadOPF
        )
    }

    /// The key a digest is remembered under, so the caller can build the same
    /// map from the index before a rebuild.
    public static func digestKey(folder: String, fileName: String, byteSize: Int64, modifiedAt: Date) -> String {
        "\(folder)/\(fileName)|\(byteSize)|\(Int64(modifiedAt.timeIntervalSince1970))"
    }

    // MARK: Reading the folder name

    /// `Pride and Prejudice (17)` → 17, and 0 when there is no number.
    ///
    /// Zero rather than a guess: the number is only used to keep folders
    /// unique, and a rebuild that invented one could collide with a real book.
    /// The rebuilder reports the highest it found and the library's counter is
    /// set past it.
    static func number(in folderName: String) -> Int {
        guard folderName.hasSuffix(")"), let open = folderName.lastIndex(of: "(") else { return 0 }
        let digits = folderName[folderName.index(after: open)..<folderName.index(before: folderName.endIndex)]
        return Int(digits) ?? 0
    }

    /// `Pride and Prejudice (17)` → `Pride and Prejudice`.
    static func title(in folderName: String) -> String {
        guard folderName.hasSuffix(")"), let open = folderName.lastIndex(of: "(") else { return folderName }
        let digits = folderName[folderName.index(after: open)..<folderName.index(before: folderName.endIndex)]
        guard Int(digits) != nil else { return folderName }
        return String(folderName[folderName.startIndex..<open]).trimmingCharacters(in: .whitespaces)
    }
}
