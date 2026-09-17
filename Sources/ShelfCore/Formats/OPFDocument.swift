import Foundation

/// `metadata.opf` – the file next to each book that holds its metadata.
///
/// Two jobs, and they are the reason this type exists rather than a reader and
/// a writer that drift apart: it reads the OPF an EPUB carries *inside* itself,
/// and it reads and writes the `metadata.opf` Shelf keeps *next to* the book.
/// Both follow the Calibre schema – Dublin Core plus `calibre:` metas – because
/// a library that Calibre can still read is the way back out of Shelf
/// (CONCEPT §4, "Must": a return to Calibre stays open).
///
/// Shelf's own fields go in `shelf:`-prefixed metas. Calibre ignores metas it
/// does not know, so writing them costs nothing and loses nothing.
public enum OPFDocument {
    public static let fileName = "metadata.opf"

    // MARK: Reading

    /// Everything an OPF says about one book, plus what the *file* says about
    /// itself that the book model has no room for.
    public struct Parsed: Equatable, Sendable {
        public var book: Book
        /// Path of the cover image inside the EPUB, relative to the OPF.
        /// Only set when reading an EPUB's own OPF.
        public var coverPath: String?
        /// Shelf names the book belonged to when it was last written. Read back
        /// on a rebuild, which is what makes shelves survive a lost index.
        public var shelfPaths: [String]
        /// Fields the file had that Shelf does not model yet – Calibre's custom
        /// columns among them. Kept so writing the file back does not drop
        /// them (Sprint 3 reads them properly).
        public var unmappedMetas: [String: String]

        public init(
            book: Book, coverPath: String? = nil, shelfPaths: [String] = [],
            unmappedMetas: [String: String] = [:]
        ) {
            self.book = book
            self.coverPath = coverPath
            self.shelfPaths = shelfPaths
            self.unmappedMetas = unmappedMetas
        }
    }

    public enum Failure: Error, Equatable {
        case notAnOPF(String)
        case cannotWrite(String)
    }

    /// Reads an OPF. `fallbackTitle` is used when the file has no usable title –
    /// which happens, and a book called after its file is better than no book.
    public static func read(_ data: Data, fallbackTitle: String) throws -> Parsed {
        let root: XMLTree.Element
        do {
            root = try XMLTree.parse(data)
        } catch {
            throw Failure.notAnOPF((error as? XMLTree.Failure).map(String.init(describing:)) ?? "unreadable")
        }
        return read(root, fallbackTitle: fallbackTitle)
    }

    /// The same, from an already-parsed tree – what the EPUB reader hands in,
    /// so the OPF is not parsed twice.
    public static func read(_ root: XMLTree.Element, fallbackTitle: String) -> Parsed {
        let metas = Metas(root)

        var identifiers: [String: String] = [:]
        var uuid: UUID?
        for element in root.descendants(named: "identifier") {
            let value = element.text.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            let scheme = (element.attribute("scheme") ?? inferredScheme(of: value)).lowercased()
            if scheme == "uuid" {
                uuid = UUID(uuidString: stripURNPrefix(value)) ?? uuid
            } else {
                identifiers[scheme] = value
            }
        }

        let title = root.firstText(named: "title") ?? fallbackTitle
        let authors = readAuthors(root)

        var book = Book(
            id: uuid ?? UUID(),
            title: title,
            titleSort: metas["calibre:title_sort"] ?? TitleSort.of(title),
            authors: authors.names,
            series: readSeries(root, metas: metas),
            rating: metas["calibre:rating"].flatMap { Int(Double($0) ?? 0) } ?? 0,
            isRead: metas["shelf:read"] == "true",
            publisher: root.firstText(named: "publisher"),
            published: root.descendants(named: "date").map(\.text).compactMap(OPFDate.parse).first,
            language: root.firstText(named: "language"),
            description: root.firstText(named: "description"),
            tags: root.descendants(named: "subject").map(\.text).filter { !$0.isEmpty },
            identifiers: identifiers)

        if let timestamp = metas["calibre:timestamp"].flatMap(OPFDate.parse) {
            book.addedAt = timestamp
        }
        if let modified = root.descendants(named: "meta")
            .first(where: { $0.attribute("property") == "dcterms:modified" })
            .map(\.text)
            .flatMap(OPFDate.parse)
        {
            book.modifiedAt = modified
        }

        return Parsed(
            book: book,
            coverPath: readCoverPath(root),
            shelfPaths: decodeShelves(metas["shelf:shelves"]),
            unmappedMetas: metas.unmapped)
    }

    /// The shelves a book is on, as a JSON array.
    ///
    /// One field rather than one meta per shelf, because `<meta name=…>` is
    /// looked up by name and repeated names would collapse into one.
    static func encodeShelves(_ paths: [String]) -> String {
        guard let data = try? JSONEncoder().encode(paths), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func decodeShelves(_ content: String?) -> [String] {
        guard let content, !content.isEmpty, let data = content.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// `dc:creator` elements: the names, and the sort forms where the file gave
    /// one. Contributors (`opf:role` other than `aut`) are skipped – a
    /// translator is not the author, and Calibre files them separately too.
    private static func readAuthors(_ root: XMLTree.Element) -> (names: [String], sorts: [String: String]) {
        var names: [String] = []
        var sorts: [String: String] = [:]
        for element in root.descendants(named: "creator") {
            let name = element.text.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if let role = element.attribute("role"), role.lowercased() != "aut" { continue }
            names.append(name)
            if let fileAs = element.attribute("file-as") { sorts[name] = fileAs }
        }
        return (names, sorts)
    }

    /// The series, from Calibre's metas first and EPUB 3's own vocabulary
    /// second. Calibre's wins because a library imported from Calibre is the
    /// case this has to be right for.
    private static func readSeries(_ root: XMLTree.Element, metas: Metas) -> SeriesRef? {
        if let name = metas["calibre:series"], !name.isEmpty {
            return SeriesRef(name: name, index: metas["calibre:series_index"].flatMap(Double.init))
        }
        // EPUB 3: <meta property="belongs-to-collection" id="c1">Name</meta>
        // plus <meta refines="#c1" property="group-position">3</meta>
        let collections = root.descendants(named: "meta")
            .filter { $0.attribute("property") == "belongs-to-collection" }
        guard let collection = collections.first, !collection.text.isEmpty else { return nil }
        let position = collection.attribute("id").flatMap { id in
            root.descendants(named: "meta")
                .first { $0.attribute("refines") == "#\(id)" && $0.attribute("property") == "group-position" }
                .map(\.text)
        }
        return SeriesRef(name: collection.text, index: position.flatMap(Double.init))
    }

    /// Where the cover image sits inside the EPUB.
    ///
    /// Three ways, in the order they are trustworthy: EPUB 3's
    /// `properties="cover-image"` on a manifest item, EPUB 2's
    /// `<meta name="cover" content="itemID">`, and an item whose id or href
    /// merely looks like a cover. The last one is a guess, and it is the one
    /// that finds the cover in most books written before 2015.
    private static func readCoverPath(_ root: XMLTree.Element) -> String? {
        let items = root.descendants(named: "item")

        if let item = items.first(where: { ($0.attribute("properties") ?? "").contains("cover-image") }) {
            return item.attribute("href")
        }
        if let id = root.descendants(named: "meta").first(where: { $0.attribute("name") == "cover" })?
            .attribute("content"),
            let item = items.first(where: { $0.attribute("id") == id })
        {
            return item.attribute("href")
        }
        return items.first { item in
            let id = (item.attribute("id") ?? "").lowercased()
            let href = (item.attribute("href") ?? "").lowercased()
            let isImage = (item.attribute("media-type") ?? "").hasPrefix("image/")
            return isImage && (id.contains("cover") || href.contains("cover"))
        }?.attribute("href")
    }

    /// A value with no scheme is still often an ISBN – Calibre writes bare
    /// `urn:isbn:` and some tools write nothing at all. Thirteen or ten digits
    /// is a strong enough signal to name it.
    private static func inferredScheme(of value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("urn:isbn:") || lower.hasPrefix("isbn:") { return "isbn" }
        if lower.hasPrefix("urn:uuid:") { return "uuid" }
        let digits = value.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        if digits.count == 13 || digits.count == 10, digits.count == value.filter({ $0 != "-" }).count {
            return "isbn"
        }
        return "unknown"
    }

    private static func stripURNPrefix(_ value: String) -> String {
        let lower = value.lowercased()
        for prefix in ["urn:uuid:", "uuid:"] where lower.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    /// `<meta name=… content=…>` in one lookup, and a note of what was not
    /// recognised so a write can put it back.
    private struct Metas {
        private var values: [String: String] = [:]
        /// Metas Shelf does not model. Calibre's `user_metadata:*` lands here
        /// until Sprint 3.
        var unmapped: [String: String] = [:]

        /// The prefixes this type claims to understand; anything else is kept
        /// verbatim rather than thrown away.
        static let known = ["calibre:", "shelf:"]

        init(_ root: XMLTree.Element) {
            for element in root.descendants(named: "meta") {
                guard let name = element.attribute("name") else { continue }
                let content = element.attribute("content") ?? element.text
                values[name] = content
                if !Self.known.contains(where: { name.hasPrefix($0) }) {
                    unmapped[name] = content
                }
            }
        }

        subscript(_ name: String) -> String? {
            values[name]?.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: Writing

    /// The OPF text for a book. Rendered by hand rather than through a DOM:
    /// the file has to come out byte-identical for identical input, so a diff
    /// in a library folder means a real change and not a reordered attribute.
    public static func render(
        _ book: Book, shelfPaths: [String] = [], unmappedMetas: [String: String] = [:]
    ) -> String {
        var lines: [String] = []
        lines.append("<?xml version='1.0' encoding='utf-8'?>")
        lines.append(
            "<package xmlns=\"http://www.idpf.org/2007/opf\" unique-identifier=\"uuid_id\" version=\"2.0\">")
        lines.append(
            "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
                + "xmlns:opf=\"http://www.idpf.org/2007/opf\">")

        lines.append("    <dc:title>\(escaped(book.title))</dc:title>")
        for author in book.authors {
            lines.append(
                "    <dc:creator opf:role=\"aut\" opf:file-as=\"\(escapedAttribute(AuthorSort.of(author)))\">"
                    + "\(escaped(author))</dc:creator>")
        }
        if let language = book.language {
            lines.append("    <dc:language>\(escaped(language))</dc:language>")
        }
        if let publisher = book.publisher {
            lines.append("    <dc:publisher>\(escaped(publisher))</dc:publisher>")
        }
        if let published = book.published {
            lines.append("    <dc:date>\(OPFDate.render(published))</dc:date>")
        }
        if let description = book.description, !description.isEmpty {
            lines.append("    <dc:description>\(escaped(description))</dc:description>")
        }
        // The UUID is the book's identity and the reason the index can be
        // thrown away and rebuilt (CONCEPT §5.3).
        lines.append("    <dc:identifier id=\"uuid_id\" opf:scheme=\"uuid\">\(book.id.uuidString)</dc:identifier>")
        for scheme in book.identifiers.keys.sorted() {
            guard let value = book.identifiers[scheme] else { continue }
            lines.append(
                "    <dc:identifier opf:scheme=\"\(escapedAttribute(scheme.uppercased()))\">\(escaped(value))"
                    + "</dc:identifier>")
        }
        for tag in book.tags.sorted() {
            lines.append("    <dc:subject>\(escaped(tag))</dc:subject>")
        }

        lines.append("    <meta name=\"calibre:title_sort\" content=\"\(escapedAttribute(book.titleSort))\"/>")
        if let series = book.series {
            lines.append("    <meta name=\"calibre:series\" content=\"\(escapedAttribute(series.name))\"/>")
            if let index = series.index {
                lines.append("    <meta name=\"calibre:series_index\" content=\"\(number(index))\"/>")
            }
        }
        if book.rating > 0 {
            lines.append("    <meta name=\"calibre:rating\" content=\"\(book.rating)\"/>")
        }
        lines.append("    <meta name=\"calibre:timestamp\" content=\"\(OPFDate.render(book.addedAt))\"/>")
        // Read since Sprint 1 and, until Sprint 2, never written – so a rebuilt
        // index dated every book to the moment it was rebuilt. EPUB 3's own
        // property rather than a `calibre:` meta, because that is where the
        // reader already looks for it.
        lines.append(
            "    <meta property=\"dcterms:modified\">\(OPFDate.render(book.modifiedAt))</meta>")

        // Shelf's own fields. Calibre ignores metas it does not know, which is
        // what makes this safe to write into a library Calibre also reads.
        lines.append("    <meta name=\"shelf:read\" content=\"\(book.isRead)\"/>")
        if !shelfPaths.isEmpty {
            // A JSON array, not a joined string. A shelf name may contain any
            // printable character – a comma, a slash, a pipe – and the obvious
            // answer, an ASCII separator such as the unit separator, is *not
            // legal in XML 1.0*: the parser refuses the whole file. JSON is
            // lossless, legal, and still readable by eye in the file.
            lines.append(
                "    <meta name=\"shelf:shelves\" content=\"\(escapedAttribute(encodeShelves(shelfPaths)))\"/>")
        }
        for name in unmappedMetas.keys.sorted() {
            guard let content = unmappedMetas[name] else { continue }
            lines.append("    <meta name=\"\(escapedAttribute(name))\" content=\"\(escapedAttribute(content))\"/>")
        }

        lines.append("  </metadata>")
        lines.append("  <guide/>")
        lines.append("</package>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the OPF into a book's folder, atomically.
    ///
    /// CONCEPT §5.1 asks for a `.part` file that is renamed into place, the same
    /// rule as Selector's `.ingest-*.part`, so that a crash or a full disk leaves
    /// either the old file or the new one and never half of either – the OPF is
    /// the only record of a book's metadata once the index is gone.
    ///
    /// `Data.write(options: .atomic)` *is* that: it writes a temporary file in
    /// the same directory and renames it over the target with `rename(2)`, which
    /// is atomic. Doing it by hand instead is how this first went wrong — the
    /// hand-written version used `FileManager.replaceItemAt`, which is not
    /// implemented in swift-corelibs-foundation, so every second write of an OPF
    /// failed on Linux. The Linux CI job found it; no Mac would have.
    public static func write(
        _ book: Book, to folder: URL, shelfPaths: [String] = [], unmappedMetas: [String: String] = [:]
    ) throws {
        let text = render(book, shelfPaths: shelfPaths, unmappedMetas: unmappedMetas)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw Failure.cannotWrite(folder.lastPathComponent)
        }
    }

    /// `3` rather than `3.0`, `3.5` as itself – the way Calibre writes it.
    private static func number(_ value: Double) -> String {
        let rounded = value.rounded()
        return abs(value - rounded) < 0.001 ? String(Int(rounded)) : String(format: "%g", value)
    }

    /// The five XML entities, for text between tags. All five, always: an
    /// apostrophe inside a double-quoted attribute is legal, but an OPF that
    /// goes through another tool and comes back single-quoted would break.
    ///
    /// A carriage return is escaped as well, and that is not pedantry: XML
    /// *line-ending normalisation* turns a literal CR in element text into LF
    /// before the parser ever reports it, so a description pasted from a Windows
    /// tool would come back with different bytes than it went in with. `&#13;`
    /// survives, because a character reference is not normalised. A newline and
    /// a tab are left as themselves here – they are legal, they survive, and a
    /// 20 KB description with `&#10;` in place of every line break is a file no
    /// person can read (DATA-MODEL §3: this is a file somebody may well open).
    /// **Over unicode scalars, not characters.** `"\r\n"` is a *single*
    /// `Character` in Swift – one grapheme cluster – so `case "\r"` never
    /// matches a Windows line break, and the literal CRLF went into the file
    /// and came back as a bare LF. Written down because the code reads
    /// identically either way and only the test tells them apart.
    static func escaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\r": result += "&#13;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// The same, for a value inside an attribute – where three more characters
    /// cannot survive as themselves.
    ///
    /// XML *attribute-value normalisation* replaces every literal tab, newline
    /// and carriage return in an attribute with a space before the parser
    /// reports the value. A title sort of "Vol. 1\nSpecial" would therefore come
    /// back as "Vol. 1 Special": a round trip through the folder would change a
    /// book nobody had edited, and the index and the file would disagree for
    /// good. As character references they survive untouched.
    ///
    /// Which fields this matters for is not hypothetical: `calibre:title_sort`,
    /// `calibre:series`, `opf:file-as` and every one of Calibre's custom columns
    /// in `unmappedMetas` are attributes, and all of them hold text a person
    /// typed or pasted.
    /// Over unicode scalars, for the same reason as `escaped`.
    static func escapedAttribute(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t": result += "&#9;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// Dates in an OPF, read loosely and written one way.
///
/// Loosely because the field is a free-text `dc:date` in practice: "2019",
/// "2019-04", "2019-04-01", a full ISO-8601 stamp, and Calibre's own
/// "0101-01-01T00:00:00+00:00" for "unknown" all turn up. One way on write,
/// with a fixed locale and calendar, so the file does not change with the
/// user's region settings.
public enum OPFDate {
    /// Calibre's placeholder for "no date". Read as no date rather than as a
    /// book published in the year 101.
    static let undefinedYear = 101

    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for format in ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            guard let date = formatter.date(from: trimmed) else { continue }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            guard calendar.component(.year, from: date) > undefinedYear else { return nil }
            return date
        }
        return nil
    }

    public static func render(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss+00:00"
        return formatter.string(from: date)
    }
}
