import Foundation

/// Reads an EPUB: its metadata and the bytes of its cover.
///
/// The path through the format is fixed by the standard and worth naming,
/// because every step of it is a place a real file goes wrong:
/// `META-INF/container.xml` says where the OPF is → the OPF holds the Dublin
/// Core metadata and the manifest → the manifest says which item is the cover.
/// A file that fails at any step still yields a book: the file name is the
/// fallback, and the import report says what was missing (CONCEPT §7.5).
public enum EPUBMetadata {
    /// What one EPUB turned out to hold.
    public struct Result: Equatable, Sendable {
        public var book: Book
        /// The cover image's bytes, if the file had one.
        public var cover: Data?
        /// Its name inside the EPUB, for the report and for choosing a file
        /// extension when the cover is written out.
        public var coverName: String?
        public var drm: DRMKind?
        /// What could not be read. Never fatal on its own – the book is still
        /// imported, and these lines end up in `Import-Report.txt`.
        public var warnings: [String]
        /// Fields the OPF had that Shelf does not model yet.
        public var unmappedMetas: [String: String]

        public init(
            book: Book, cover: Data? = nil, coverName: String? = nil, drm: DRMKind? = nil,
            warnings: [String] = [], unmappedMetas: [String: String] = [:]
        ) {
            self.book = book
            self.cover = cover
            self.coverName = coverName
            self.drm = drm
            self.warnings = warnings
            self.unmappedMetas = unmappedMetas
        }
    }

    public enum Failure: Error, Equatable {
        /// Not a ZIP, or a ZIP with no OPF in it – the file is not an EPUB.
        case notAnEPUB(String)
    }

    static let containerPath = "META-INF/container.xml"
    static let encryptionPath = "META-INF/encryption.xml"

    /// Reads the EPUB at `url`.
    ///
    /// `readCover` is a switch rather than always-on: the import reads covers,
    /// and a rebuild of the index from an existing library does not – the
    /// covers are already extracted next to the books.
    public static func read(url: URL, readCover: Bool = true) throws -> Result {
        let archive: ZipReader
        do {
            archive = try ZipReader(url: url)
        } catch {
            throw Failure.notAnEPUB(url.lastPathComponent)
        }
        return read(archive, fallbackTitle: url.deletingPathExtension().lastPathComponent, readCover: readCover)
    }

    /// The same for an archive already in hand, so a caller that has the bytes
    /// does not read the file twice.
    public static func read(_ archive: ZipReader, fallbackTitle: String, readCover: Bool = true) -> Result {
        var warnings: [String] = []

        // DRM first: it explains everything that follows. A protected file is
        // shown, badged and otherwise left alone – never unlocked (CONCEPT §12).
        let drm: DRMKind? = archive.entry(at: encryptionPath) != nil ? .adobeADEPT : nil

        guard let opfPath = opfPath(in: archive, warnings: &warnings),
            let opfText = try? archive.data(at: opfPath),
            let opfRoot = try? XMLTree.parse(opfText)
        else {
            warnings.append("no readable OPF – the metadata comes from the file name")
            return Result(
                book: Book(
                    title: FileNameMetadata.title(from: fallbackTitle),
                    authors: FileNameMetadata.authors(from: fallbackTitle)),
                drm: drm,
                warnings: warnings)
        }

        let parsed = OPFDocument.read(opfRoot, fallbackTitle: FileNameMetadata.title(from: fallbackTitle))
        var book = parsed.book
        if book.authors.isEmpty {
            let guessed = FileNameMetadata.authors(from: fallbackTitle)
            if !guessed.isEmpty {
                book.authors = guessed
                warnings.append("no author in the file – taken from the file name")
            }
        }

        var cover: Data?
        var coverName: String?
        if readCover {
            (cover, coverName) = readCoverImage(archive, opfPath: opfPath, coverPath: parsed.coverPath)
            if cover == nil { warnings.append("no cover in the file") }
        }

        return Result(
            book: book, cover: cover, coverName: coverName, drm: drm, warnings: warnings,
            unmappedMetas: parsed.unmappedMetas)
    }

    /// Where the OPF is.
    ///
    /// `container.xml` is the one file whose path the standard fixes, and its
    /// `rootfile` element names the OPF. When it is missing or unreadable – and
    /// it is, in files assembled by hand – the fallback is the first `.opf` in
    /// the archive, which in practice is the right one.
    static func opfPath(in archive: ZipReader, warnings: inout [String]) -> String? {
        if let data = try? archive.data(at: containerPath),
            let root = try? XMLTree.parse(data),
            let path = root.descendants(named: "rootfile").compactMap({ $0.attribute("full-path") }).first,
            archive.entry(at: path) != nil
        {
            return path
        }
        guard let fallback = archive.files.first(where: { $0.path.lowercased().hasSuffix(".opf") }) else {
            return nil
        }
        warnings.append("no usable \(containerPath) – used \(fallback.path) instead")
        return fallback.path
    }

    /// The cover's bytes.
    ///
    /// The OPF's href is relative to the OPF, not to the archive root, so the
    /// OPF's own folder has to be put back in front of it. When the manifest
    /// gives no cover, the first image in the archive is taken – for a comic or
    /// a hand-made EPUB that is the front page, and a wrong cover is easier to
    /// notice and fix than a missing one.
    static func readCoverImage(
        _ archive: ZipReader, opfPath: String, coverPath: String?
    ) -> (Data?, String?) {
        if let coverPath {
            let resolved = resolve(coverPath, relativeTo: opfPath)
            if let entry = archive.entry(at: resolved), let data = try? archive.data(for: entry) {
                return (data, entry.fileName)
            }
        }
        // Alphabetical, not archive order: a comic's pages are named in
        // reading order, and archive order is whatever the writer felt like.
        let images = archive.files
            .filter { imageExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        guard let first = images.first, let data = try? archive.data(for: first) else { return (nil, nil) }
        return (data, first.fileName)
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif"]

    /// Joins a manifest href onto the OPF's own folder and resolves `..`.
    ///
    /// Plain string work rather than `URL`: the paths inside a ZIP are not file
    /// system paths, and `URL` would percent-encode the spaces that half of
    /// them contain.
    static func resolve(_ href: String, relativeTo opfPath: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        if decoded.hasPrefix("/") { return String(decoded.dropFirst()) }

        let base = (opfPath as NSString).deletingLastPathComponent
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/").map(String.init) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}

/// What a file name says about a book when the file itself says nothing.
///
/// Used for MOBI, PDF and comics in Sprint 1, and for any EPUB whose metadata
/// cannot be read. Rules, not a table, and tested – because for part of a
/// library this is the *only* metadata there will be.
public enum FileNameMetadata {
    /// The separators that mean "author and title" in a downloaded file name,
    /// widest first. Reference data: a new one is a row.
    static let separators = [" - ", " – ", " — ", "_-_"]

    /// Prefixes shops and sites glue onto a file name. Stripped so a book is
    /// not called "OceanofPDF com The Wife Upstairs".
    static let noisePrefixes = ["_oceanofpdf.com_", "oceanofpdf.com_", "www.", "_"]

    /// The title part of "The Hobbit - J.R.R. Tolkien".
    ///
    /// Which side is the title is genuinely ambiguous, and the answer here is
    /// "the left one", because that is how nearly every download and every
    /// Calibre export is named (`{title} - {author}`).
    public static func title(from fileName: String) -> String {
        let cleaned = withoutNoise(fileName)
        for separator in separators {
            if let range = cleaned.range(of: separator) {
                let left = String(cleaned[cleaned.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty { return tidied(left) }
            }
        }
        return tidied(cleaned)
    }

    /// The author part, or nothing when the name has no separator. Nothing
    /// rather than a guess: a wrong author files the book in the wrong folder.
    public static func authors(from fileName: String) -> [String] {
        let cleaned = withoutNoise(fileName)
        for separator in separators {
            if let range = cleaned.range(of: separator) {
                let right = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !right.isEmpty { return [tidied(right)] }
            }
        }
        return []
    }

    private static func withoutNoise(_ name: String) -> String {
        var result = name
        let lower = result.lowercased()
        for prefix in noisePrefixes where lower.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
            break
        }
        return result
    }

    /// Underscores back to spaces, runs of whitespace collapsed. Not
    /// title-cased: "iBooks" and "eBay" would come out wrong, and a title the
    /// user can correct in one click is better than one that looks edited.
    private static func tidied(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "_", with: " ")
        return spaced.split(separator: " ").filter { !$0.isEmpty }.joined(separator: " ")
    }
}
