import Foundation

/// Reads a MOBI or AZW3: its metadata and the bytes of its cover.
///
/// The route through the format, and every step of it a place a real file goes
/// wrong: the PalmDB container says where record 0 is → record 0 holds the
/// PalmDOC header, the MOBI header and the EXTH records → EXTH holds the author,
/// the title, the ISBN and the date, and EXTH 201 says which image record is the
/// cover.
///
/// Like the EPUB reader, it never refuses a book for having odd metadata: a
/// file that fails at any step still yields a `Book` named after its file, and
/// what was missing goes into the import report. The one thing that *is*
/// refused is a file that is not a Palm database at all, because then it is not
/// this reader's file.
///
/// **KFX is not read** — the format is a different container entirely and is
/// undocumented. A `.kfx` is carried as a file with a name, a size and a badge
/// (ADR 0011), which is more honest than a parser that would be wrong.
///
/// **DRM is recognised and nothing more.** EXTH 209 (`tamper-proof keys`) and a
/// non-zero PalmDOC encryption type both mean the text is locked; Shelf badges
/// the file, reads whatever metadata is still in the clear, and leaves it
/// alone. Nothing here removes or works around anything (CONCEPT §12, ADR 0012).
public enum MobiMetadata {

    /// The EXTH record types Shelf reads. Reference data, one row each, rather
    /// than a chain of `if type == …` — adding a field later is a row.
    enum EXTH {
        static let author: UInt32 = 100
        static let publisher: UInt32 = 101
        static let description: UInt32 = 103
        static let isbn: UInt32 = 104
        static let subject: UInt32 = 105
        static let publishingDate: UInt32 = 106
        static let asin: UInt32 = 113
        /// The image record holding the cover, counted from the first image.
        static let coverOffset: UInt32 = 201
        static let thumbnailOffset: UInt32 = 202
        /// Present when the file carries Kindle DRM.
        static let tamperProofKeys: UInt32 = 209
        /// The title, when the publisher updated it after the fact. Preferred
        /// over the MOBI header's own name, which is what the file was called
        /// when it was first built.
        static let updatedTitle: UInt32 = 503
        static let language: UInt32 = 524
    }

    public struct Result: Equatable, Sendable {
        public var book: Book
        public var cover: Data?
        public var coverName: String?
        public var drm: DRMKind?
        public var warnings: [String]

        public init(
            book: Book, cover: Data? = nil, coverName: String? = nil, drm: DRMKind? = nil,
            warnings: [String] = []
        ) {
            self.book = book
            self.cover = cover
            self.coverName = coverName
            self.drm = drm
            self.warnings = warnings
        }
    }

    public enum Failure: Error, Equatable {
        /// Not a Palm database, so not a MOBI whatever its name says.
        case notAMobi(String)
    }

    public static func read(url: URL, readCover: Bool = true) throws -> Result {
        guard let data = try? Data(contentsOf: url) else {
            throw Failure.notAMobi(url.lastPathComponent)
        }
        return try read(
            Array(data), fallbackTitle: url.deletingPathExtension().lastPathComponent, readCover: readCover)
    }

    public static func read(_ bytes: [UInt8], fallbackTitle: String, readCover: Bool = true) throws -> Result {
        let database: PalmDatabase
        do {
            database = try PalmDatabase(bytes: bytes)
        } catch {
            throw Failure.notAMobi(fallbackTitle)
        }
        guard database.looksLikeABook else { throw Failure.notAMobi(fallbackTitle) }

        var warnings: [String] = []
        let fromFileName = Book(
            title: FileNameMetadata.title(from: fallbackTitle),
            authors: FileNameMetadata.authors(from: fallbackTitle))

        guard let record0 = database.record(0), let header = try? MobiHeader(record0: record0) else {
            // A Palm database with no MOBI header: an old PalmDOC, or a file
            // whose record 0 is damaged. Still a book, still imported.
            warnings.append("no MOBI header – the metadata comes from the file name")
            return Result(book: fromFileName, warnings: warnings)
        }

        // DRM before anything else, because it explains everything that is
        // missing afterwards.
        let drm: DRMKind? =
            header.exth[EXTH.tamperProofKeys] != nil || header.encryptionType != 0 ? .kindle : nil

        var book = fromFileName
        book.title = title(header, fallback: fromFileName.title, database: database)
        book.titleSort = TitleSort.of(book.title)

        // One EXTH 100 per author, in the order the file lists them — the first
        // one decides the folder, so the order is kept rather than sorted.
        let authors = header.strings(EXTH.author).flatMap(Self.splitAuthors)
        if !authors.isEmpty {
            book.authors = authors
        } else if book.authors.isEmpty {
            warnings.append("no author in the file")
        }

        book.publisher = header.string(EXTH.publisher)
        book.description = header.string(EXTH.description)
        book.language = header.string(EXTH.language) ?? book.language
        book.tags = Set(header.strings(EXTH.subject).flatMap(Self.splitSubjects)).sorted()

        // Normalised, not validated. The reader takes what the file says and
        // the *editor* is what refuses a bad check digit: a library full of
        // slightly wrong ISBNs must not become a library of missing ones.
        if let raw = header.string(EXTH.isbn) {
            let isbn = ISBN.normalised(raw)
            if !isbn.isEmpty { book.identifiers["isbn"] = isbn }
        }
        if let asin = header.string(EXTH.asin) {
            book.identifiers["asin"] = asin
        }
        if let raw = header.string(EXTH.publishingDate) {
            if let date = Self.date(from: raw) {
                book.published = date
            } else {
                warnings.append("the publishing date “\(raw)” could not be read")
            }
        }

        var cover: Data?
        var coverName: String?
        if readCover {
            (cover, coverName) = readCoverImage(database, header: header)
            if cover == nil {
                warnings.append(
                    drm == nil ? "no cover in the file" : "no cover Shelf can reach – the file is protected")
            }
        }

        if drm != nil {
            warnings.append("the file carries Kindle DRM – it is badged and otherwise left alone")
        }

        return Result(book: book, cover: cover, coverName: coverName, drm: drm, warnings: warnings)
    }

    // MARK: The title

    /// EXTH 503 first, then the MOBI header's full name, then the file name.
    ///
    /// In that order because 503 is what the publisher last said the book is
    /// called, the header's name is what it was called when the file was built,
    /// and the PalmDB name is a 31-character truncation of one of the two —
    /// which is why it is not used at all unless nothing else spoke up.
    static func title(_ header: MobiHeader, fallback: String, database: PalmDatabase) -> String {
        if let updated = header.string(EXTH.updatedTitle), !updated.isEmpty { return updated }
        if let full = header.fullName, !full.isEmpty { return full }
        if !fallback.isEmpty { return fallback }
        return database.name
    }

    // MARK: The cover

    /// EXTH 201 counts from the first image record, not from the start of the
    /// file — so the cover is record `firstImageIndex + coverOffset`.
    ///
    /// The thumbnail (EXTH 202) is the fallback, and after that the first image
    /// record that looks like an image at all. A slightly wrong cover is easier
    /// to notice and fix than a missing one, the same judgement the EPUB reader
    /// makes.
    static func readCoverImage(_ database: PalmDatabase, header: MobiHeader) -> (Data?, String?) {
        guard let first = header.firstImageIndex else { return (nil, nil) }

        for type in [EXTH.coverOffset, EXTH.thumbnailOffset] {
            guard let offset = header.number(type), offset < 0xFFFF_FFF0 else { continue }
            let index = first + Int(offset)
            if let record = database.record(index), let name = imageName(record) {
                return (Data(record), name)
            }
        }

        // Nothing said which one; take the first record from the image area
        // that actually begins like an image.
        var index = first
        while index < database.recordCount, index < first + 64 {
            if let record = database.record(index), let name = imageName(record) {
                return (Data(record), name)
            }
            index += 1
        }
        return (nil, nil)
    }

    /// A name for the cover with the right extension, or nil when the bytes are
    /// not an image Shelf recognises.
    ///
    /// The bytes decide, not a field: MOBI records carry no type, and writing
    /// `cover.jpg` over a PNG is how a cover cache ends up full of files whose
    /// name lies about them. `CoverFile` already knows the magic numbers.
    static func imageName(_ record: [UInt8]) -> String? {
        guard record.count > 64 else { return nil }
        let data = Data(record.prefix(16))
        guard CoverFile.fileExtension(for: data) != nil else { return nil }
        return CoverFile.name(for: Data(record))
    }

    // MARK: Small rules

    /// `Le Guin, Ursula K.` stays one author; `Gaiman, Neil & Pratchett, Terry`
    /// is two. The rule is `AuthorField`'s, shared with the PDF reader and the
    /// comic reader — it was written twice before it was written once.
    static func splitAuthors(_ raw: String) -> [String] { AuthorField.split(raw) }

    /// Subjects arrive one per record, but some writers pack several into one
    /// with a comma or a semicolon between them.
    static func splitSubjects(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The date formats EXTH 106 turns up in, widest first.
    ///
    /// A table, because there are four of them and they are data: ISO 8601 with
    /// a time, ISO 8601 without, a bare year-month and a bare year. Anything
    /// else is left unset and named in the report rather than guessed at — a
    /// wrong publication date sorts a book into the wrong decade silently.
    static let dateFormats = ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy-MM", "yyyy"]

    static func date(from raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for format in dateFormats {
            let formatter = DateFormatter()
            // Fixed locale and a fixed zone: a date that reads differently on a
            // German Mac is the same class of defect as the "64,4" the smoke
            // test was bitten by.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
