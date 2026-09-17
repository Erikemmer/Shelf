import Foundation

/// The counting protocol a Calibre import shows **before** it is allowed to
/// start (CONCEPT §7.3, Leitlinie: "Importe mit Zählprotokoll").
///
/// Everything here is counted from one reading of the database and one walk of
/// the folder, so the numbers cannot disagree with each other — and the same
/// value is what the sheet draws and what `shelf-tool calibre-dry` prints, so
/// the command line and the window cannot disagree either.
///
/// It answers the two questions somebody about to move a library actually has:
/// *is all of it there*, and *will it fit*.
public struct CalibreCensus: Equatable, Sendable {
    public var books: Int
    /// How many files of each format Shelf will import.
    public var formats: [BookFileFormat: Int]
    /// Formats Calibre lists that Shelf does not import, by Calibre's own name
    /// (`SNB`, `LRF`, `TXTZ`…). Counted rather than hidden: a library that is
    /// half LRF should say so before the import, not after.
    public var otherFormats: [String: Int]
    public var authors: Int
    public var series: Int
    public var tags: Int
    public var customColumns: [CalibreCustomColumn]
    public var unknownColumns: [CalibreUnknownColumn]
    /// Listed in the database, not on the disk. Relative paths.
    public var missingFiles: [String]
    /// On the disk, not in the database. Relative paths.
    public var orphanFiles: [String]
    public var booksWithoutCover: Int
    /// The real size of the files that are actually there.
    public var totalBytes: Int64
    /// Free at the destination, or `nil` when there is no destination yet.
    public var availableBytes: Int64?
    public var schema: CalibreSchema
    public var warnings: [String]

    public init(
        books: Int = 0, formats: [BookFileFormat: Int] = [:], otherFormats: [String: Int] = [:],
        authors: Int = 0, series: Int = 0, tags: Int = 0,
        customColumns: [CalibreCustomColumn] = [], unknownColumns: [CalibreUnknownColumn] = [],
        missingFiles: [String] = [], orphanFiles: [String] = [], booksWithoutCover: Int = 0,
        totalBytes: Int64 = 0, availableBytes: Int64? = nil,
        schema: CalibreSchema = CalibreSchema(userVersion: 0, isKnown: true),
        warnings: [String] = []
    ) {
        self.books = books
        self.formats = formats
        self.otherFormats = otherFormats
        self.authors = authors
        self.series = series
        self.tags = tags
        self.customColumns = customColumns
        self.unknownColumns = unknownColumns
        self.missingFiles = missingFiles
        self.orphanFiles = orphanFiles
        self.booksWithoutCover = booksWithoutCover
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.schema = schema
        self.warnings = warnings
    }

    /// What must be free before the first byte is copied: the payload plus the
    /// same 5 % `ImportPlan` uses, so the two agree about what "enough room"
    /// means (ADR 0002, decision 5).
    public var requiredBytes: Int64 {
        Int64((Double(totalBytes) * ImportPlan.freeSpaceMargin).rounded(.up))
    }

    /// `nil` when nothing has been asked about the destination yet.
    public var hasRoom: Bool? {
        availableBytes.map { $0 >= requiredBytes }
    }

    public var fileCount: Int {
        formats.values.reduce(0, +) + otherFormats.values.reduce(0, +)
    }

    /// Whether "Import" may be clicked at all. Only room decides that; the
    /// missing files, the orphans and the unknown columns are things to *read*
    /// before deciding, not reasons the button is dead.
    public var mayImport: Bool {
        books > 0 && formats.values.reduce(0, +) > 0 && hasRoom != false
    }

    /// The counting protocol, one fact per line, in the order somebody reads
    /// it: what is there, what is missing, how much room it needs.
    public func lines() -> [String] {
        var lines: [String] = []
        lines.append("Books                 \(books)")
        lines.append("Authors               \(authors)")
        lines.append("Series                \(series)")
        lines.append("Tags                  \(tags)")
        for format in formats.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            lines.append("  \(format.label.padding(toLength: 18, withPad: " ", startingAt: 0))\(formats[format] ?? 0)")
        }
        for format in otherFormats.keys.sorted() {
            lines.append(
                "  \(format.padding(toLength: 18, withPad: " ", startingAt: 0))\(otherFormats[format] ?? 0)"
                    + "   (not imported)")
        }
        for column in customColumns {
            lines.append("  \(column.hashLabel.padding(toLength: 18, withPad: " ", startingAt: 0))\(column.kind.label)")
        }
        for column in unknownColumns {
            lines.append(
                "  \(("#" + column.label).padding(toLength: 18, withPad: " ", startingAt: 0))"
                    + "\(column.datatype)   (unknown – reported, not imported)")
        }
        if !missingFiles.isEmpty {
            lines.append("Missing on disk       \(missingFiles.count)   (listed in metadata.db, not there)")
        }
        if !orphanFiles.isEmpty {
            lines.append("Not in metadata.db    \(orphanFiles.count)   (on disk, no database entry)")
        }
        if booksWithoutCover > 0 {
            lines.append("Without a cover       \(booksWithoutCover)")
        }
        lines.append("Total size            \(ByteCount.format(totalBytes))")
        lines.append("Room needed (× 1.05)  \(ByteCount.format(requiredBytes))")
        if let availableBytes {
            lines.append(
                "Free at the destination \(ByteCount.format(availableBytes))"
                    + (hasRoom == true ? "" : "   NOT ENOUGH"))
        }
        return lines
    }
}

/// Counts a Calibre library, against the database *and* the disk.
///
/// Both, because they disagree: Calibre's `data` table is what the library
/// believes and the folder is what it has. A count taken from one of them
/// alone is the count that makes an import look fine and then fail halfway.
public struct CalibreCensusTaker: Sendable {
    private let freeSpace: FreeSpaceProbe

    public init(freeSpace: @escaping FreeSpaceProbe = FileManager.defaultFreeSpaceProbe) {
        self.freeSpace = freeSpace
    }

    /// - Parameter destination: the folder the library will be copied into, or
    ///   `nil` when nobody has chosen one yet. The free-space line is then left
    ///   out rather than guessed at.
    public func take(of library: CalibreLibrary, destination: URL? = nil) -> CalibreCensus {
        let manager = FileManager.default
        var census = CalibreCensus(
            books: library.books.count,
            customColumns: library.customColumns,
            unknownColumns: library.unknownColumns,
            schema: library.schema,
            warnings: library.warnings)

        var authors = Set<String>()
        var series = Set<String>()
        var tags = Set<String>()
        var known = Set<String>()

        for entry in library.books {
            authors.formUnion(entry.book.authors)
            if let name = entry.book.series?.name { series.insert(name) }
            tags.formUnion(entry.book.tags.map { $0.lowercased() })
            if !entry.claimsCover { census.booksWithoutCover += 1 }

            for file in entry.files {
                known.insert(file.relativePath)
                let url = library.folder.appending(path: file.relativePath)
                let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
                guard let size else {
                    census.missingFiles.append(file.relativePath)
                    continue
                }
                // The size on disk, not the size the database remembers: the
                // free-space check has to be right about the bytes that will
                // actually be copied.
                census.totalBytes += size
                if let format = file.format {
                    census.formats[format, default: 0] += 1
                } else {
                    census.otherFormats[file.calibreFormat.uppercased(), default: 0] += 1
                }
            }
        }

        census.authors = authors.count
        census.series = series.count
        census.tags = tags.count
        census.orphanFiles = orphans(in: library.folder, known: known)
        census.availableBytes = destination.flatMap(freeSpace)
        return census
    }

    /// Book files in the Calibre folder that the database does not list.
    ///
    /// Only files whose extension is a book format: `cover.jpg`,
    /// `metadata.opf` and Calibre's own `metadata_db_prefs_backup.json` are not
    /// orphans, they are furniture. Calibre leaves real orphans behind when a
    /// format is removed from the library but not from the folder, and that is
    /// a thing to know *before* an import rather than to discover after.
    func orphans(in folder: URL, known: Set<String>) -> [String] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(atPath: folder.path) else { return [] }
        var found: [String] = []
        for case let path as String in walker {
            let ext = (path as NSString).pathExtension.lowercased()
            guard BookFileFormat(rawValue: ext) != nil else { continue }
            guard !known.contains(path) else { continue }
            found.append(path)
        }
        return found.sorted()
    }
}
