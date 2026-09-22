import Foundation

/// Writes a cover image into an EPUB's own archive — the second half of
/// `docs/adr/0021-…`'s promise, `EPUBOPFPatch` (title, authors, …) being the
/// first.
///
/// Two cases, and the manifest itself decides which one applies:
///
/// - **The manifest already names a cover.** Only that entry's *bytes* are
///   replaced, at the path it already has. The href never moves — an EPUB 2
///   cover page is often its own XHTML file that embeds the image by that
///   exact href, and renaming the file out from under it would point that
///   page at nothing. A new image in a different format than the old one is
///   still written at the old path; only the manifest's `media-type` is
///   corrected, because a wrong extension is harmless once the declared type
///   is right, and a moved file is not.
/// - **It does not.** A new manifest item is added, with a cover bytes entry
///   beside it, and a cover *declaration* in whichever form (or forms) the
///   file itself already uses — see `declarationForm(_:)`.
///
/// Never touched: `<guide>`, an existing cover page, the `<spine>`, or any
/// other entry in the archive. Rebuilding a book's cover page is rebuilding
/// the book, which this is not.
public enum EPUBCoverPatch {
    public enum Failure: Error, Equatable {
        case notAnOPF(String)
        case drmProtected
        case manifestNotFound
    }

    /// What `entries(patchingCover:in:)` did, beside the entries themselves —
    /// for a caller (a test, `shelf-tool epub-cover-patch`) to report.
    public struct Result: Sendable {
        public var entries: [ZipArchiveWriter.Entry]
        /// `true` when an existing manifest cover entry's bytes were
        /// replaced; `false` when a new one was added.
        public var replacedExisting: Bool
        /// Set only when `replacedExisting` is `true` and the new image's
        /// own format differs from what the manifest declared — the one
        /// case where the manifest text changes on top of the image itself.
        public var mediaTypeCorrected: (from: String, to: String)?
        /// `false` only in case a, when `coverData` is already, byte for
        /// byte, what the manifest's own cover entry holds — nothing was
        /// touched, `entries` is `archive`'s own entries carried forward
        /// unchanged, and a caller must not call
        /// `EPUBArchiveWriter.archive(_:)` and write the result out
        /// expecting anything to differ. Always `true` in case b: adding a
        /// cover where none existed is always a change. This is the
        /// foundation for "Nothing to write" in the window
        /// (`EPUBWrite.CoverPlan`, Sprint 11) — a cover write that would
        /// change nothing must never move a book's file to the Trash for
        /// no difference at all, the same rule Sprint 10 already applies
        /// to metadata fields.
        public var changed: Bool
    }

    /// `coverData` written into `archive`, alongside every other entry
    /// carried forward unchanged — ready for `EPUBArchiveWriter.archive(_:)`.
    public static func entries(patchingCover coverData: Data, in archive: ZipReader) throws -> Result {
        guard archive.entry(at: EPUBMetadata.encryptionPath) == nil else { throw Failure.drmProtected }

        var warnings: [String] = []
        guard let opfPath = EPUBMetadata.opfPath(in: archive, warnings: &warnings) else {
            throw Failure.notAnOPF("no OPF found in the archive")
        }
        let opfText = try archive.text(at: opfPath)
        let root: XMLTree.Element
        do {
            root = try XMLTree.parse(opfText)
        } catch {
            throw Failure.notAnOPF((error as? XMLTree.Failure).map(String.init(describing:)) ?? "unreadable")
        }

        var entries = try EPUBArchiveWriter.entries(rewriting: archive)

        guard let existingHref = OPFDocument.coverPath(root) else {
            return try Self.addNewCover(coverData, root: root, opfPath: opfPath, opfText: opfText, entries: entries)
        }

        let resolved = EPUBMetadata.resolve(existingHref, relativeTo: opfPath)
        guard let coverIndex = entries.firstIndex(where: { $0.path == resolved }) else {
            throw Failure.notAnOPF("the manifest's own cover \(resolved) is not among the archive's entries")
        }

        // Bit-identical to what is already there: nothing to touch, nothing
        // to correct — `entries` is handed back exactly as
        // `EPUBArchiveWriter.entries(rewriting:)` produced it, so a caller
        // that skips writing when `changed` is `false` truly writes
        // nothing. Unreadable existing bytes fall through to the ordinary
        // replacement below rather than being treated as "unchanged" —
        // silence here would be a write that silently never happens.
        if let existingEntry = archive.entry(at: resolved), let existingBytes = try? archive.data(for: existingEntry),
            existingBytes == coverData
        {
            return Result(entries: entries, replacedExisting: true, mediaTypeCorrected: nil, changed: false)
        }
        entries[coverIndex] = .raw(path: resolved, data: coverData)

        let mediaTypeCorrected = Self.correctMediaTypeIfNeeded(
            for: coverData, existingHref: existingHref, opfPath: opfPath, opfText: opfText, entries: &entries)

        return Result(entries: entries, replacedExisting: true, mediaTypeCorrected: mediaTypeCorrected, changed: true)
    }

    // MARK: Case b — adding a cover the manifest does not have yet

    /// Which form (or forms) of cover declaration a file gets, decided by
    /// what the file itself already is — never a default Shelf picks.
    ///
    /// EPUB 2 readers understand only `<meta name="cover" content="id">`;
    /// EPUB 3 readers understand `properties="cover-image"` on the manifest
    /// item. `<package version="3.…">` gets the EPUB 3 form. A real,
    /// EPUB 3 Gutenberg book (`pride-and-prejudice-epub3-images.epub`) was
    /// read while building this and turned out to carry *both*: its own
    /// `<spine toc="…">` still names an NCX, kept for readers that only
    /// understand EPUB 2 — and a book that goes to that trouble for its
    /// table of contents gets both forms of the cover declaration too,
    /// rather than a compatibility gap this project introduced on its own.
    private enum DeclarationForm: Equatable { case epub2, epub3, both }

    private static func declarationForm(_ root: XMLTree.Element) -> DeclarationForm {
        guard (root.attribute("version") ?? "").hasPrefix("3") else { return .epub2 }
        let keepsNCXForCompatibility = root.firstChild(named: "spine")?.attribute("toc") != nil
        return keepsNCXForCompatibility ? .both : .epub3
    }

    /// A new manifest `<item>` for `coverData`, its cover declaration in
    /// whichever form `declarationForm` says, and the image itself as a new
    /// archive entry — an id and a file name that avoid colliding with
    /// anything the archive or the document already has, in the OPF's own
    /// folder, beside its other entries.
    private static func addNewCover(
        _ coverData: Data, root: XMLTree.Element, opfPath: String, opfText: String,
        entries: [ZipArchiveWriter.Entry]
    ) throws -> Result {
        guard let manifestBody = EPUBOPFPatch.rawOccurrences(of: "manifest", in: opfText).first?.bodyRange else {
            throw Failure.manifestNotFound
        }

        let id = Self.uniqueName(base: "shelf-cover", taken: Self.allIDs(root))
        let folder = (opfPath as NSString).deletingLastPathComponent
        let fileName = Self.uniqueFileName(
            base: "shelf-cover", extension: CoverFile.fileExtension(for: coverData) ?? "jpg", folder: folder,
            taken: Set(entries.map(\.path)))
        let newPath = folder.isEmpty ? fileName : "\(folder)/\(fileName)"

        let form = Self.declarationForm(root)
        let properties = form == .epub2 ? "" : #" properties="cover-image""#
        let itemXML =
            "    <item id=\"\(OPFDocument.escapedAttribute(id))\" href=\"\(OPFDocument.escapedAttribute(fileName))\" "
            + "media-type=\"\(Self.mediaType(for: coverData))\"\(properties)/>\n  "

        var newOPFText = opfText
        newOPFText.insert(contentsOf: itemXML, at: manifestBody.upperBound)

        if form == .epub2 || form == .both {
            guard let metadataBody = EPUBOPFPatch.rawOccurrences(of: "metadata", in: newOPFText).first?.bodyRange
            else { throw Failure.manifestNotFound }
            let metaXML = "    <meta name=\"cover\" content=\"\(OPFDocument.escapedAttribute(id))\"/>\n  "
            newOPFText.insert(contentsOf: metaXML, at: metadataBody.upperBound)
        }

        guard let opfIndex = entries.firstIndex(where: { $0.path == opfPath }) else {
            throw Failure.notAnOPF("the OPF entry \(opfPath) was not among the archive's own entries")
        }
        var newEntries = entries
        newEntries[opfIndex] = .raw(path: opfPath, text: newOPFText)
        newEntries.append(.raw(path: newPath, data: coverData))

        return Result(entries: newEntries, replacedExisting: false, mediaTypeCorrected: nil, changed: true)
    }

    /// Every `id` attribute anywhere in the document — checked globally, not
    /// only within `<manifest>`, because an XML id has to be unique across
    /// the whole file.
    private static func allIDs(_ root: XMLTree.Element) -> Set<String> {
        var result: Set<String> = []
        func walk(_ element: XMLTree.Element) {
            if let id = element.attribute("id") { result.insert(id) }
            for child in element.children { walk(child) }
        }
        walk(root)
        return result
    }

    private static func uniqueName(base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private static func uniqueFileName(
        base: String, extension ext: String, folder: String, taken: Set<String>
    )
        -> String
    {
        func path(_ name: String) -> String { folder.isEmpty ? name : "\(folder)/\(name)" }
        guard taken.contains(path("\(base).\(ext)")) else { return "\(base).\(ext)" }
        var suffix = 2
        while taken.contains(path("\(base)-\(suffix).\(ext)")) { suffix += 1 }
        return "\(base)-\(suffix).\(ext)"
    }

    // MARK: Correcting a mismatched media-type, in place

    /// When the new image's own format differs from what the manifest
    /// declared for the item at `existingHref`, corrects that one
    /// `media-type` attribute — nothing else in the tag, nothing elsewhere
    /// in the file — and replaces `entries`' OPF entry with the result.
    /// `nil` when nothing needed correcting.
    private static func correctMediaTypeIfNeeded(
        for coverData: Data, existingHref: String, opfPath: String, opfText: String,
        entries: inout [ZipArchiveWriter.Entry]
    ) -> (from: String, to: String)? {
        guard let tag = Self.manifestItemTag(hrefEquals: existingHref, in: opfText),
            let mediaTypeRange = tag.valueRanges["media-type"]
        else { return nil }

        let existing = EPUBOPFPatch.unescaped(String(opfText[mediaTypeRange]))
        let corrected = Self.mediaType(for: coverData)
        guard existing.lowercased() != corrected.lowercased() else { return nil }

        var newText = opfText
        newText.replaceSubrange(mediaTypeRange, with: OPFDocument.escapedAttribute(corrected))
        if let opfIndex = entries.firstIndex(where: { $0.path == opfPath }) {
            entries[opfIndex] = .raw(path: opfPath, text: newText)
        }
        return (from: existing, to: corrected)
    }

    /// The media type this project writes for `data`'s own sniffed format —
    /// the same list `CoverFile.fileExtension` knows, mapped onto what an
    /// OPF manifest calls it. Unrecognised bytes still get a value, `image/
    /// jpeg`, the same "written under .jpg" default `CoverFile.name` uses:
    /// a cover Shelf cannot name is better kept than dropped.
    static func mediaType(for data: Data) -> String {
        switch CoverFile.fileExtension(for: data) {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        default: return "image/jpeg"
        }
    }

    // MARK: Scanning the manifest's raw text for one `<item>` tag

    /// One manifest `<item>` tag's exact span in the OPF's raw text, and
    /// each of its attributes' lower-cased local name mapped to the *range*
    /// of that attribute's raw value (between the quotes, entities not
    /// decoded) — enough to replace one attribute's value without touching
    /// anything else in the tag, the same job `EPUBOPFPatch.apply` does for
    /// an element's body text rather than an attribute.
    private struct ManifestItemTag {
        var tagRange: Range<String.Index>
        var valueRanges: [String: Range<String.Index>]
    }

    /// The first `<item>` tag whose own `href` decodes to exactly `href` —
    /// document order, the same order the manifest itself uses.
    private static func manifestItemTag(hrefEquals href: String, in text: String) -> ManifestItemTag? {
        var cursor = text.startIndex
        while let tagStart = EPUBOPFPatch.nextTagStart(named: "item", in: text, from: cursor) {
            guard let (tagEnd, _) = EPUBOPFPatch.endOfOpeningTag(startingAt: tagStart, in: text) else { break }
            let span = tagStart..<tagEnd
            let ranges = Self.attributeValueRanges(inTagSpanning: span, in: text)
            if let hrefRange = ranges["href"], EPUBOPFPatch.unescaped(String(text[hrefRange])) == href {
                return ManifestItemTag(tagRange: span, valueRanges: ranges)
            }
            cursor = tagEnd
        }
        return nil
    }

    /// Every attribute of one opening tag, spanning `span` in `text`, as its
    /// lower-cased local name to the range of its raw value — `EPUBOPFPatch
    /// .attributes(inOpeningTag:)`'s own scan, kept as ranges instead of
    /// decoded strings, because this caller has to splice one value back in
    /// rather than only read it.
    private static func attributeValueRanges(
        inTagSpanning span: Range<String.Index>, in text: String
    ) -> [String: Range<String.Index>] {
        var result: [String: Range<String.Index>] = [:]
        guard let firstSpace = text[span].firstIndex(where: { $0.isWhitespace }) else { return result }
        var index = firstSpace
        while index < span.upperBound {
            while index < span.upperBound, text[index].isWhitespace { index = text.index(after: index) }
            guard index < span.upperBound, text[index] != "/", text[index] != ">" else { break }
            guard let equals = text[index..<span.upperBound].firstIndex(of: "=") else { break }
            let rawName = text[index..<equals].trimmingCharacters(in: .whitespaces)
            var valueStart = text.index(after: equals)
            while valueStart < span.upperBound, text[valueStart].isWhitespace {
                valueStart = text.index(after: valueStart)
            }
            guard valueStart < span.upperBound, text[valueStart] == "\"" || text[valueStart] == "'" else { break }
            let quote = text[valueStart]
            let contentStart = text.index(after: valueStart)
            guard let quoteEnd = text[contentStart..<span.upperBound].firstIndex(of: quote) else { break }
            result[EPUBOPFPatch.localName(of: rawName).lowercased()] = contentStart..<quoteEnd
            index = text.index(after: quoteEnd)
        }
        return result
    }
}
