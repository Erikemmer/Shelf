import Foundation

/// How a library is written out as an ordinary folder of files.
///
/// The point of the whole feature, and of principle 3 in the *Leitlinie*: no
/// lock-in. A library kept in Shelf must be able to walk out of Shelf at any
/// moment without losing what was maintained in it.
public struct ExportOptions: Equatable, Sendable, Codable {

    /// Which formats go. `nil` means every format of every book — "all".
    ///
    /// An empty set is not the same thing and is refused: somebody who ticked
    /// nothing has not asked for everything.
    public var formats: Set<BookFileFormat>?
    public var structure: Structure
    /// The file's name, with tokens. `{author} - {title}`.
    public var namePattern: String
    public var includesCover: Bool
    public var includesOPF: Bool
    /// Whether to write shelf membership and the read status as Calibre tags
    /// as well. See `ExportPreset.forCalibre`.
    public var mapsShelvesToTags: Bool
    /// Hard links instead of copies, where the destination is on the same
    /// volume. Across volumes it is a copy, without asking: a hard link cannot
    /// cross one, and stopping to say so would be stopping to say that
    /// physics is physics.
    public var prefersHardLinks: Bool

    public enum Structure: String, Sendable, Codable, CaseIterable {
        /// `Austen, Jane/Pride and Prejudice/…` — what the library itself
        /// looks like, and what Calibre's importer walks.
        case authorTitle
        /// Everything in one folder. For a card, a phone, a reader that has no
        /// idea what a folder is.
        case flat

        public var label: String {
            switch self {
            case .authorTitle: return "Author / Title"
            case .flat: return "One flat folder"
            }
        }
    }

    public init(
        formats: Set<BookFileFormat>? = nil,
        structure: Structure = .authorTitle,
        namePattern: String = ExportOptions.defaultNamePattern,
        includesCover: Bool = true,
        includesOPF: Bool = true,
        mapsShelvesToTags: Bool = false,
        prefersHardLinks: Bool = false
    ) {
        self.formats = formats
        self.structure = structure
        self.namePattern = namePattern
        self.includesCover = includesCover
        self.includesOPF = includesOPF
        self.mapsShelvesToTags = mapsShelvesToTags
        self.prefersHardLinks = prefersHardLinks
    }

    public static let defaultNamePattern = "{author} - {title}"

    /// Why this cannot be run, in the sentence the sheet shows.
    public var refusal: String? {
        if let formats, formats.isEmpty {
            return "Tick at least one format, or nothing will be written."
        }
        if NamePattern.tokens(in: namePattern).isEmpty {
            return "The name pattern has no {title} or {author} in it, so every book would be called the same thing."
        }
        return nil
    }

    public func includes(_ format: BookFileFormat) -> Bool {
        formats.map { $0.contains(format) } ?? true
    }
}

/// The three ways of exporting that answer three different questions.
///
/// Presets rather than a page of switches, because the switches are the *how*
/// and these are the *why*. Everything each one sets is still visible and
/// still changeable — a preset is a starting point, not a mode.
public enum ExportPreset: String, Sendable, CaseIterable, Codable {
    /// Everything, and it can be imported back into Shelf without loss. This
    /// is the one the proof run checks by importing it into an empty library
    /// and comparing the two.
    case archive
    /// The book files and nothing else, for somebody who does not have Shelf.
    /// The dialogue says in as many words what stays behind.
    case booksOnly
    /// Like `archive`, plus the two things Calibre would otherwise drop.
    case forCalibre

    public var label: String {
        switch self {
        case .archive: return "Archive"
        case .booksOnly: return "Just the books"
        case .forCalibre: return "For Calibre"
        }
    }

    /// What the dialogue says about this choice — the honest sentence, not the
    /// flattering one.
    public var explanation: String {
        switch self {
        case .archive:
            return "Everything: the book files, the covers and a metadata.opf each. "
                + "This can be imported back into Shelf with nothing lost."
        case .booksOnly:
            return "The book files alone. The rating, the read status, the tags and the shelves "
                + "will not go with them — they live in the metadata.opf, and that is not written."
        case .forCalibre:
            return "Everything Archive writes, plus the two things Calibre cannot read: "
                + "each shelf becomes a tag like “Shelf/Fiction/Sci-Fi”, and a book that has "
                + "been read gets the tag “Read”. That is a mapping, not the real fields — "
                + "Shelf's own are still written beside them and Calibre still ignores those."
        }
    }

    public var options: ExportOptions {
        switch self {
        case .archive:
            return ExportOptions(includesCover: true, includesOPF: true)
        case .booksOnly:
            return ExportOptions(includesCover: false, includesOPF: false)
        case .forCalibre:
            return ExportOptions(includesCover: true, includesOPF: true, mapsShelvesToTags: true)
        }
    }

    /// Which preset a set of options *is*, or `nil` when it has been changed
    /// into something of its own. What the sheet uses to keep the chosen
    /// preset lit while nothing has been touched.
    public static func matching(_ options: ExportOptions) -> ExportPreset? {
        allCases.first { $0.options == options }
    }
}

/// The tokens a file name may be built from.
///
/// A table rather than a chain of replacements, so the list the dialogue shows
/// and the list the renderer honours are one list and cannot drift.
public enum NamePattern {
    public enum Token: String, CaseIterable, Sendable {
        case author = "{author}"
        case title = "{title}"
        case series = "{series}"
        case index = "{index}"
        case number = "{number}"

        public var explanation: String {
            switch self {
            case .author: return "the first author"
            case .title: return "the title"
            case .series: return "the series name, or nothing"
            case .index: return "the number in the series, or nothing"
            case .number: return "the library's own running number"
            }
        }
    }

    /// Which tokens a pattern actually uses.
    public static func tokens(in pattern: String) -> [Token] {
        Token.allCases.filter { pattern.contains($0.rawValue) }
    }

    /// The name for one book, sanitised and cut to the byte limit — the same
    /// rules a folder inside the library follows, because an exported folder
    /// has to survive the same file systems (`BookFolderName`).
    public static func name(for entry: LibraryEntry, pattern: String, extension ext: String) -> String {
        var name = pattern
        for token in Token.allCases {
            name = name.replacingOccurrences(of: token.rawValue, with: value(of: token, for: entry))
        }
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let stem = BookFolderName.sanitised(tidied(name), fallback: "Untitled")
        return
            "\(BookFolderName.truncated(stem, toBytes: BookFolderName.maxComponentBytes - suffix.utf8.count))\(suffix)"
    }

    /// Takes out the separator an empty token leaves behind.
    ///
    /// `{series} - {title}` over a book in no series produced `" - Emma.epub"`,
    /// and `{author} - {series} - {title}` produced `"Jane Austen -  - Emma"`.
    /// Not only ugly: a book file with no `metadata.opf` beside it is read
    /// from its *name*, and a leading or doubled separator is exactly what a
    /// name parser trips over. Found by exporting a library and importing it
    /// back, which is the one test that asks the two halves whether they agree.
    ///
    /// `{author}` is never empty — it falls back to "Unknown", because a file
    /// name cannot be blank and that is what a device file name does too
    /// (`Book.primaryAuthor`). The tokens this is really for are `{series}`
    /// and `{index}`.
    ///
    /// Split, drop the empties, rejoin: one pass, and no loop that has to be
    /// reasoned about.
    static func tidied(_ name: String) -> String {
        var result = name
        for separator in [" - ", " — ", " – "] {
            guard result.contains(separator) else { continue }
            result =
                result
                .components(separatedBy: separator)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: separator)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func value(of token: Token, for entry: LibraryEntry) -> String {
        switch token {
        case .author: return entry.book.primaryAuthor
        case .title: return entry.book.title
        case .series: return entry.book.series?.name ?? ""
        case .index:
            guard let index = entry.book.series?.index else { return "" }
            let rounded = index.rounded()
            return abs(index - rounded) < 0.001 ? String(Int(rounded)) : String(format: "%g", index)
        case .number: return String(entry.number)
        }
    }
}
