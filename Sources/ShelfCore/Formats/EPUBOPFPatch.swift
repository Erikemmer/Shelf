import Foundation

/// Changes title, authors, language, publisher, the published date,
/// description and identifiers in an EPUB's own `content.opf` — and nothing
/// else.
///
/// `OPFDocument.render` writes Shelf's own sidecar `metadata.opf`, which has
/// neither `<manifest>` nor `<spine>` and none of what a real book's own OPF
/// carries that Shelf does not model — accessibility metadata, a
/// publisher's own extensions, EPUB 3 rendition hints. Rendering a new OPF
/// through that writer would silently drop all of it. This type never
/// renders: it parses with `XMLTree` to find exactly the elements Shelf is
/// allowed to change, and edits only their text, in the original bytes —
/// the manifest, the spine, the guide, every element this project does not
/// model, the document's own element order and its namespace prefixes stay
/// exactly as they were (`docs/adr/0021-…`).
///
/// **Mostly never invents structure — two fields are the deliberate
/// exception.** `dc:publisher`, `dc:language`, `dc:date` and
/// `dc:description` are inserted, in the file's own namespace prefix, as
/// the last child of `<metadata>`, when the book has none: a real Gutenberg
/// EPUB usually has no `dc:publisher` at all, and a field that silently
/// does nothing because the element was never there is worse than one that
/// creates it. `dc:title` and `dc:creator` are never invented: a book
/// without a title or an author does not happen, and a new author raises
/// the same `id`/`refines` question adding one already refuses on. Whatever
/// still cannot be written — because it is one of those two, or because the
/// file's own structure makes even a `dc:publisher` unsafe to add — is
/// counted and returned, never silently dropped.
///
/// **Refuses rather than guesses**, the same shape as the writer beneath
/// it: a different number of authors than the file has creators for, a
/// creator whose role is not "author", or a local name spelled more than
/// one way in the same file are all refused, named, rather than picked
/// between.
public enum EPUBOPFPatch {
    public enum Failure: Error, Equatable {
        case notAnOPF(String)
        /// `fields.authors` was given, but its count does not match the
        /// number of existing author `dc:creator` elements. Adding or
        /// removing one correctly needs a new `id` nothing else collides
        /// with and, in EPUB 3, new `refines` metas — real work this type
        /// does not do. Refusing is safer than guessing which name goes
        /// where.
        case authorCountMismatch(existing: Int, new: Int)
        /// An existing `dc:creator` has a role other than "author" (a
        /// translator or an editor written as a creator rather than a
        /// contributor, which happens). `fields.authors` is not allowed to
        /// overwrite it, and this type has no way to know which name in
        /// the new list was meant for it, so it refuses instead of
        /// guessing.
        case creatorRoleNotSupported(String)
        /// The same local name written more than one way in one file
        /// (`dc:creator` and `Creator`, say) — rare enough that guessing
        /// which occurrence is which is riskier than refusing.
        case ambiguousElementSpelling(String)
        /// The archive announces DRM (`META-INF/encryption.xml`). Refused
        /// before the OPF is even read, in the core – not a check a future
        /// window adds, the one place a "write into the book" command must
        /// never go near (CONCEPT §12).
        case drmProtected
    }

    /// What Shelf may change, and nothing more. `nil` means "leave this
    /// field exactly as the file has it".
    public struct Fields: Sendable {
        public var title: String?
        /// Replaces existing author `dc:creator` elements' text, one for
        /// one, in document order. `nil` leaves authors untouched.
        public var authors: [String]?
        public var language: String?
        public var publisher: String?
        public var published: Date?
        public var description: String?
        /// Scheme (matched against `opf:scheme`, case-insensitively) to
        /// value. Only a scheme that already has an existing `dc:identifier`
        /// — other than the one the package's own `unique-identifier`
        /// names — is changed.
        public var identifiers: [String: String]?

        public init(
            title: String? = nil, authors: [String]? = nil, language: String? = nil,
            publisher: String? = nil, published: Date? = nil, description: String? = nil,
            identifiers: [String: String]? = nil
        ) {
            self.title = title
            self.authors = authors
            self.language = language
            self.publisher = publisher
            self.published = published
            self.description = description
            self.identifiers = identifiers
        }
    }

    /// What `apply` produces: the OPF's new text, and the name of every
    /// field `fields` asked for that could not be written — never silent,
    /// even when there was nowhere safe to put it.
    public struct Result: Sendable {
        public var text: String
        /// `"title"`, `"language"`, `"publisher"`, `"date"`, `"description"`,
        /// or `"identifier:<scheme>"` — named, so a caller can tell a person
        /// exactly which field did not make it in.
        public var unwritten: [String]
    }

    /// `fields` applied to `opfText`. `now` is injectable so a test can
    /// compare byte for byte; production leaves it as `Date()`.
    public static func apply(_ fields: Fields, to opfText: String, now: Date = Date()) throws -> Result {
        let root: XMLTree.Element
        do {
            root = try XMLTree.parse(opfText)
        } catch {
            throw Failure.notAnOPF((error as? XMLTree.Failure).map(String.init(describing:)) ?? "unreadable")
        }

        var replacements: [(range: Range<String.Index>, text: String)] = []
        var changedAnything = false
        var unwritten: [String] = []

        // Not `expecting:` a count: a real OPF often has more than one
        // `dc:date` (publication *and* conversion, in every EPUB 2 Gutenberg
        // book this was checked against) – "first" is well-defined
        // regardless of how many exist, the same convention
        // `firstText(named:)` already uses for reading.
        //
        // `insertable`: `dc:title` is never created (a book without one
        // does not happen); the other four are, as the last child of
        // `<metadata>`, when this book has none.
        func replaceOrInsert(_ localName: String, with newValue: String, insertable: Bool) {
            if let element = root.descendants(named: localName).first,
                let body = Self.rawOccurrences(of: element.qualifiedName, in: opfText).first?.bodyRange
            {
                replacements.append((body, OPFDocument.escaped(newValue)))
                changedAnything = true
                return
            }
            if insertable, let insertion = Self.insertion(for: localName, value: newValue, root: root, in: opfText) {
                replacements.append(insertion)
                changedAnything = true
                return
            }
            unwritten.append(localName)
        }

        if let title = fields.title { replaceOrInsert("title", with: title, insertable: false) }
        if let language = fields.language { replaceOrInsert("language", with: language, insertable: true) }
        if let publisher = fields.publisher { replaceOrInsert("publisher", with: publisher, insertable: true) }
        if let published = fields.published {
            replaceOrInsert("date", with: OPFDate.render(published), insertable: true)
        }
        if let description = fields.description {
            replaceOrInsert("description", with: description, insertable: true)
        }

        if let authors = fields.authors {
            replacements.append(
                contentsOf: try Self.authorReplacements(authors, root: root, in: opfText, changed: &changedAnything))
        }

        if let identifiers = fields.identifiers {
            replacements.append(
                contentsOf: try Self.identifierReplacements(
                    identifiers, root: root, in: opfText, changed: &changedAnything, unwritten: &unwritten))
        }

        if changedAnything, let modified = Self.dctermsModifiedElement(root),
            let body = try Self.occurrences(of: modified.qualifiedName, expecting: nil, fieldName: "meta", in: opfText)
                .first(where: { $0.attributes["property"]?.lowercased() == "dcterms:modified" })?.bodyRange
        {
            replacements.append((body, OPFDocument.escaped(Self.renderModified(now))))
        }

        return Result(text: Self.splice(opfText, with: replacements), unwritten: unwritten)
    }

    /// Where a new `dc:publisher`/`dc:language`/`dc:date`/`dc:description`
    /// goes: the last child of `<metadata>`, in whatever namespace prefix
    /// the file's own Dublin Core elements already use — `nil` when either
    /// cannot be established, so the caller counts it as unwritten instead
    /// of guessing at a prefix or a position.
    private static func insertion(
        for localName: String, value: String, root: XMLTree.Element, in text: String
    ) -> (
        range: Range<String.Index>, text: String
    )? {
        guard let prefix = Self.dublinCorePrefix(root) else { return nil }
        guard let metadataElement = root.firstChild(named: "metadata"),
            let insertionPoint = Self.rawOccurrences(of: metadataElement.qualifiedName, in: text).first?.bodyRange?
                .upperBound
        else { return nil }
        let newElement = "    <\(prefix)\(localName)>\(OPFDocument.escaped(value))</\(prefix)\(localName)>\n  "
        return (insertionPoint..<insertionPoint, newElement)
    }

    /// The prefix this file writes its own Dublin Core elements with —
    /// `"dc:"`, or `""` for a default namespace — read off `dc:identifier`
    /// (required by every valid OPF) or, failing that, `dc:title`. Not
    /// assumed: a file that writes `<title>` rather than `<dc:title>` gets
    /// a new `<publisher>`, not a `<dc:publisher>` that jars beside it.
    private static func dublinCorePrefix(_ root: XMLTree.Element) -> String? {
        guard
            let sample = (root.descendants(named: "identifier").first ?? root.descendants(named: "title").first)?
                .qualifiedName
        else { return nil }
        guard let colon = sample.firstIndex(of: ":") else { return "" }
        return String(sample[...colon])
    }

    /// Every entry of `archive`, unchanged, except one: the OPF, patched
    /// with `fields` and written `.raw` – the only entry this can change,
    /// because there is no compressor here to re-deflate it with, so it
    /// goes in stored rather than however it arrived (`docs/adr/0021-…`).
    /// The result is ready for `EPUBArchiveWriter.archive(_:)`.
    ///
    /// Refuses a DRM-protected archive outright, before the OPF is even
    /// read – the one check that has to hold regardless of what calls this,
    /// so it lives here rather than in whatever calls it next.
    /// `entries` ready for `EPUBArchiveWriter.archive(_:)`, and every field
    /// `fields` asked for that could not be written — `apply`'s own report,
    /// carried through rather than dropped at this layer.
    public struct ArchiveResult: Sendable {
        public var entries: [ZipArchiveWriter.Entry]
        public var unwritten: [String]
    }

    public static func entries(
        patching fields: Fields, in archive: ZipReader, now: Date = Date()
    ) throws
        -> ArchiveResult
    {
        guard archive.entry(at: EPUBMetadata.encryptionPath) == nil else { throw Failure.drmProtected }

        var warnings: [String] = []
        guard let opfPath = EPUBMetadata.opfPath(in: archive, warnings: &warnings) else {
            throw Failure.notAnOPF("no OPF found in the archive")
        }
        let patched = try Self.apply(fields, to: try archive.text(at: opfPath), now: now)

        var entries = try EPUBArchiveWriter.entries(rewriting: archive)
        guard let index = entries.firstIndex(where: { $0.path == opfPath }) else {
            throw Failure.notAnOPF("the OPF entry \(opfPath) was not among the archive's own entries")
        }
        entries[index] = .raw(path: opfPath, text: patched.text)
        return ArchiveResult(entries: entries, unwritten: patched.unwritten)
    }

    // MARK: Authors

    private static func authorReplacements(
        _ authors: [String], root: XMLTree.Element, in text: String, changed: inout Bool
    ) throws -> [(range: Range<String.Index>, text: String)] {
        let creators = root.descendants(named: "creator")

        let roles = Self.refinedRoles(root)
        for creator in creators {
            let role = creator.attribute("role") ?? creator.attribute("id").flatMap { roles[$0] }
            if let role, role.lowercased() != "aut" {
                throw Failure.creatorRoleNotSupported(role)
            }
        }

        // Checked before the emptiness guard below: zero existing creators
        // and one or more requested authors is exactly the mismatch this
        // refuses elsewhere, not a silent no-op.
        guard creators.count == authors.count else {
            throw Failure.authorCountMismatch(existing: creators.count, new: authors.count)
        }
        guard !creators.isEmpty else { return [] }

        let occurrences = try Self.occurrences(
            of: creators[0].qualifiedName, expecting: creators.count, fieldName: "creator", in: text)
        var result: [(range: Range<String.Index>, text: String)] = []
        for (occurrence, author) in zip(occurrences, authors) {
            guard let body = occurrence.bodyRange else { continue }
            result.append((body, OPFDocument.escaped(author)))
        }
        if !result.isEmpty { changed = true }
        return result
    }

    /// EPUB 3's roles: `<meta refines="#creator1" property="role">aut</meta>`,
    /// by the id it refines, with the `#` taken off. The same lookup
    /// `OPFDocument` builds privately for reading; small enough, and scoped
    /// narrowly enough to this one check, that duplicating it here is
    /// cheaper than making a reading-only helper public for one caller.
    private static func refinedRoles(_ root: XMLTree.Element) -> [String: String] {
        var result: [String: String] = [:]
        for meta in root.descendants(named: "meta") {
            guard meta.attribute("property")?.lowercased() == "role",
                let refines = meta.attribute("refines"), refines.hasPrefix("#")
            else { continue }
            let role = meta.text.trimmingCharacters(in: .whitespaces)
            guard !role.isEmpty else { continue }
            result[String(refines.dropFirst())] = role
        }
        return result
    }

    // MARK: Identifiers

    private static func identifierReplacements(
        _ identifiers: [String: String], root: XMLTree.Element, in text: String, changed: inout Bool,
        unwritten: inout [String]
    ) throws -> [(range: Range<String.Index>, text: String)] {
        let allIdentifiers = root.descendants(named: "identifier")
        guard !allIdentifiers.isEmpty else {
            unwritten.append(contentsOf: identifiers.keys.sorted().map { "identifier:\($0)" })
            return []
        }
        let anchorID = root.attribute("unique-identifier")

        let spellings = Set(allIdentifiers.map(\.qualifiedName))
        guard spellings.count <= 1, let qualifiedName = allIdentifiers.first?.qualifiedName else {
            throw Failure.ambiguousElementSpelling("identifier")
        }
        // Positionally paired with `allIdentifiers`, both in document
        // order – the package's `unique-identifier` is matched by `id`
        // against the tree's own attributes, never by counting, so which
        // one is skipped does not depend on this pairing being exact.
        let occurrences = try Self.occurrences(
            of: qualifiedName, expecting: allIdentifiers.count, fieldName: "identifier", in: text)

        var matchedSchemes: Set<String> = []
        var result: [(range: Range<String.Index>, text: String)] = []
        for (element, occurrence) in zip(allIdentifiers, occurrences) {
            let isAnchor = anchorID != nil && element.attribute("id") == anchorID
            guard !isAnchor else { continue }
            guard let scheme = element.attribute("scheme")?.lowercased(), let value = identifiers[scheme],
                let body = occurrence.bodyRange
            else { continue }
            result.append((body, OPFDocument.escaped(value)))
            matchedSchemes.insert(scheme)
        }
        if !result.isEmpty { changed = true }
        for scheme in identifiers.keys.sorted() where !matchedSchemes.contains(scheme.lowercased()) {
            unwritten.append("identifier:\(scheme)")
        }
        return result
    }

    // MARK: dcterms:modified

    private static func dctermsModifiedElement(_ root: XMLTree.Element) -> XMLTree.Element? {
        root.descendants(named: "meta").first { $0.attribute("property")?.lowercased() == "dcterms:modified" }
    }

    /// EPUB 3 requires `CCYY-MM-DDThh:mm:ssZ` for `dcterms:modified` –
    /// literally `Z`, not `OPFDate`'s own `+00:00`, which is `metadata.opf`'s
    /// convention and not this one.
    private static func renderModified(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    // MARK: Locating elements in the raw text

    /// Every start tag named exactly `qualifiedName`, in document order,
    /// with the range of its body (`nil` if self-closing – this type never
    /// turns a self-closing element into a paired one, which would be
    /// inventing structure the source did not have).
    ///
    /// `expecting`, when given, is a count already known from the parsed
    /// tree; a mismatch means the raw-text scan found a different number of
    /// occurrences than `XMLTree` did, which should not happen for
    /// well-formed XML `XMLTree` has already accepted – and if it ever
    /// does, refusing beats guessing which occurrence is which.
    private static func occurrences(
        of qualifiedName: String, expecting: Int?, fieldName: String, in text: String
    ) throws -> [TagOccurrence] {
        let found = Self.rawOccurrences(of: qualifiedName, in: text)
        if let expecting, found.count != expecting {
            throw Failure.ambiguousElementSpelling(fieldName)
        }
        return found
    }

    /// Internal, not private — `EPUBCoverPatch` reuses this to find
    /// `<manifest>`'s own body range, to insert a new `<item>` as its last
    /// child the same way this type inserts into `<metadata>`.
    struct TagOccurrence {
        var attributes: [String: String]
        var bodyRange: Range<String.Index>?
    }

    static func rawOccurrences(of qualifiedName: String, in text: String) -> [TagOccurrence] {
        var results: [TagOccurrence] = []
        var cursor = text.startIndex
        while let tagStart = Self.nextTagStart(named: qualifiedName, in: text, from: cursor) {
            guard let (tagEnd, selfClosing) = Self.endOfOpeningTag(startingAt: tagStart, in: text) else { break }
            let attributes = Self.attributes(inOpeningTag: text[tagStart..<tagEnd])
            if selfClosing {
                results.append(TagOccurrence(attributes: attributes, bodyRange: nil))
                cursor = tagEnd
            } else if let closeRange = Self.closingTag(named: qualifiedName, after: tagEnd, in: text) {
                results.append(TagOccurrence(attributes: attributes, bodyRange: tagEnd..<closeRange.lowerBound))
                cursor = closeRange.upperBound
            } else {
                break
            }
        }
        return results
    }

    /// The index of the next `<qualifiedName` whose name ends at a real tag
    /// boundary (whitespace, `>` or `/`) rather than continuing into a
    /// longer name (`<title` must not match inside `<titlepage`).
    ///
    /// Internal, not private: `EPUBCoverPatch` scans for `<item>` tags the
    /// same way, to find and edit one manifest entry's `media-type`
    /// attribute — a second copy of tag-boundary scanning would be a second
    /// place to get the edge cases (a quoted `>`, a self-closing tag) wrong.
    static func nextTagStart(
        named qualifiedName: String, in text: String, from start: String.Index
    ) -> String.Index? {
        let needle = "<\(qualifiedName)"
        var searchFrom = start
        while let range = text.range(of: needle, range: searchFrom..<text.endIndex) {
            if range.upperBound == text.endIndex {
                return range.lowerBound
            }
            let next = text[range.upperBound]
            if next.isWhitespace || next == ">" || next == "/" {
                return range.lowerBound
            }
            searchFrom = range.upperBound
        }
        return nil
    }

    /// Walks forward from a tag's own `<`, respecting quoted attribute
    /// values (where `>` is legal and not the tag's end), to the index just
    /// after the tag's closing `>` and whether it was self-closing.
    ///
    /// Internal — see `nextTagStart`'s own comment on why `EPUBCoverPatch`
    /// shares this rather than reimplementing it.
    static func endOfOpeningTag(
        startingAt tagStart: String.Index, in text: String
    ) -> (
        end: String.Index, selfClosing: Bool
    )? {
        var index = text.index(after: tagStart)
        var quote: Character?
        while index < text.endIndex {
            let char = text[index]
            if let openQuote = quote {
                if char == openQuote { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == ">" {
                let selfClosing = index > text.startIndex && text[text.index(before: index)] == "/"
                return (text.index(after: index), selfClosing)
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func closingTag(
        named qualifiedName: String, after point: String.Index, in text: String
    )
        -> Range<String.Index>?
    {
        guard let nameRange = text.range(of: "</\(qualifiedName)", range: point..<text.endIndex) else { return nil }
        guard let closeAngle = text.range(of: ">", range: nameRange.upperBound..<text.endIndex) else { return nil }
        return nameRange.lowerBound..<closeAngle.upperBound
    }

    /// Attributes of one opening tag, from `<name` up to (but not
    /// including) its terminating `>` or `/>`. Keys are lower-cased and
    /// prefix-stripped, matching `XMLTree`'s own convention, so a caller
    /// comparing against what `XMLTree` reported gets the same answer.
    private static func attributes(inOpeningTag tag: Substring) -> [String: String] {
        var result: [String: String] = [:]
        guard let firstSpace = tag.firstIndex(where: { $0.isWhitespace }) else { return result }
        var index = firstSpace
        while index < tag.endIndex {
            while index < tag.endIndex, tag[index].isWhitespace { index = tag.index(after: index) }
            guard index < tag.endIndex, tag[index] != "/" else { break }
            guard let equals = tag[index...].firstIndex(of: "=") else { break }
            let rawName = tag[index..<equals].trimmingCharacters(in: .whitespaces)
            var valueStart = tag.index(after: equals)
            while valueStart < tag.endIndex, tag[valueStart].isWhitespace { valueStart = tag.index(after: valueStart) }
            guard valueStart < tag.endIndex, tag[valueStart] == "\"" || tag[valueStart] == "'" else { break }
            let quote = tag[valueStart]
            let contentStart = tag.index(after: valueStart)
            guard let quoteEnd = tag[contentStart...].firstIndex(of: quote) else { break }
            let name = Self.localName(of: rawName).lowercased()
            result[name] = Self.unescaped(String(tag[contentStart..<quoteEnd]))
            index = tag.index(after: quoteEnd)
        }
        return result
    }

    /// Internal — shared with `EPUBCoverPatch`'s own attribute scan.
    static func localName(of name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// The inverse of `OPFDocument.escaped` / `escapedAttribute`, for
    /// attribute values read raw from the file rather than through
    /// `XMLTree` – needed only to compare them, never written back out.
    ///
    /// Internal — shared with `EPUBCoverPatch`'s own attribute scan.
    static func unescaped(_ text: String) -> String {
        var result = text
        let entities: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&"),
        ]
        for (entity, character) in entities {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    /// Copies `text` through unchanged except at `replacements`, applied in
    /// document order in a single forward pass – no offsets to keep in step
    /// with each other, because nothing here mutates in place.
    private static func splice(
        _ text: String, with replacements: [(range: Range<String.Index>, text: String)]
    ) -> String {
        let sorted = replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        result.reserveCapacity(text.count)
        var cursor = text.startIndex
        for replacement in sorted {
            result += text[cursor..<replacement.range.lowerBound]
            result += replacement.text
            cursor = replacement.range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
