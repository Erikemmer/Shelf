import Foundation

// On Linux the XML parser lives in its own module; on Darwin it is part of
// Foundation. The core has to build on both, so the import is conditional.
#if canImport(FoundationXML)
    import FoundationXML
#endif

/// A small read-only XML tree, built with Foundation's own parser.
///
/// Why a tree and not the parser directly: an OPF is navigated, not streamed –
/// "the `metadata` element's `dc:title` children", "the `manifest` item whose
/// id matches this `spine` reference". A SAX delegate for each of those
/// questions would be the same walk written five times.
///
/// Why Foundation's parser and not a hand-written one: entities, CDATA and
/// encodings are where a hand-written reader goes wrong, and they are exactly
/// what an OPF full of `&amp;` and HTML descriptions is made of.
///
/// **Namespaces are handled by name, not by URI.** Element and attribute names
/// are matched on their local part, so `dc:title`, `DC:title` and a `title` in
/// a default Dublin Core namespace all answer to `"title"`. That is deliberate:
/// EPUBs in the wild declare prefixes wrongly often enough that resolving URIs
/// strictly would lose metadata that is plainly there.
public struct XMLTree: Sendable {
    public struct Element: Sendable, Equatable {
        /// Local name, lower-cased: `dc:title` → `title`.
        public var name: String
        /// The name as written, prefix included – needed for the OPF writer,
        /// which has to put back what Calibre expects to read.
        public var qualifiedName: String
        /// Attributes keyed by local name, lower-cased, for the same reason.
        public var attributes: [String: String]
        /// The element's own character data, whitespace-trimmed.
        public var text: String
        public var children: [Element]

        public init(
            name: String, qualifiedName: String = "", attributes: [String: String] = [:],
            text: String = "", children: [Element] = []
        ) {
            self.name = name
            self.qualifiedName = qualifiedName.isEmpty ? name : qualifiedName
            self.attributes = attributes
            self.text = text
            self.children = children
        }

        // MARK: Navigating

        public func children(named name: String) -> [Element] {
            let wanted = name.lowercased()
            return children.filter { $0.name == wanted }
        }

        public func firstChild(named name: String) -> Element? {
            children(named: name).first
        }

        public func attribute(_ name: String) -> String? {
            attributes[name.lowercased()]
        }

        /// Every element with this name anywhere below, in **document order**.
        ///
        /// Used rather than an exact path because OPF files disagree about
        /// their own structure: `dc:title` is meant to sit inside `metadata`,
        /// and in enough real files it does not.
        ///
        /// Document order is not a nicety. `dc:creator` elements are read
        /// through this, the order of authors is data – the first one decides
        /// which folder the book lives in – and a stack-based walk hands them
        /// back reversed. That is exactly what the first version of this did.
        public func descendants(named name: String) -> [Element] {
            let wanted = name.lowercased()
            var found: [Element] = []
            for child in children {
                if child.name == wanted { found.append(child) }
                found.append(contentsOf: child.descendants(named: name))
            }
            return found
        }

        /// The first non-empty text of any element with this name below.
        public func firstText(named name: String) -> String? {
            descendants(named: name).map(\.text).first { !$0.isEmpty }
        }
    }

    public enum Failure: Error, Equatable {
        case notXML(String)
    }

    /// Parses a document and hands back its root element.
    public static func parse(_ data: Data) throws -> Element {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // Off on purpose: with namespace processing on, an undeclared prefix is
        // an error, and a `dc:` that was never declared is common enough in
        // real EPUBs that it must not cost the book its title.
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), let root = builder.root else {
            throw Failure.notXML(builder.errorDescription ?? "the file is not readable XML")
        }
        return root
    }

    public static func parse(_ text: String) throws -> Element {
        try parse(Data(text.utf8))
    }
}

/// Turns the parser's events into a tree. A class because `XMLParserDelegate`
/// needs one; used inside a single synchronous call and never shared.
private final class Builder: NSObject, XMLParserDelegate {
    private(set) var root: XMLTree.Element?
    private(set) var errorDescription: String?

    /// The elements currently open, outermost first. Text and children are
    /// accumulated into the last one.
    private var open: [XMLTree.Element] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        var localAttributes: [String: String] = [:]
        localAttributes.reserveCapacity(attributes.count)
        for (key, value) in attributes {
            localAttributes[Self.localName(of: key)] = value
        }
        open.append(
            XMLTree.Element(
                name: Self.localName(of: elementName),
                qualifiedName: elementName,
                attributes: localAttributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !open.isEmpty else { return }
        open[open.count - 1].text += string
    }

    /// A description is character data too, and a long one arrives as a CDATA
    /// block rather than as characters.
    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        guard !open.isEmpty, let text = String(data: block, encoding: .utf8) else { return }
        open[open.count - 1].text += text
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
    ) {
        guard var finished = open.popLast() else { return }
        finished.text = finished.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if open.isEmpty {
            root = finished
        } else {
            open[open.count - 1].children.append(finished)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        errorDescription = (parseError as NSError).localizedDescription
    }

    /// `dc:title` → `title`, `xmlns:opf` → `opf`, `title` → `title`.
    private static func localName(of name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name.lowercased() }
        return String(name[name.index(after: colon)...]).lowercased()
    }
}
