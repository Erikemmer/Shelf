import Foundation
import Testing

@testable import ShelfCore

/// The window has to speak both languages, and neither of the two ways of
/// losing that is visible by looking at the app.
///
/// - **A sentence with no catalogue entry** draws in English in a German
///   window. Nothing warns: `Bundle.localizedString` falls back to the key,
///   which is the English, which looks exactly right.
/// - **A catalogue entry with no German** does the same thing for the same
///   reason. SlateKit lost its whole German that way in 0.3.0 and the package
///   still built, still ran and still looked correct in English.
///
/// So both are tests. They read the **repository**, not a built bundle: a
/// catalogue missing a translation compiles into a perfectly valid bundle, and
/// the question here is what is committed.
///
/// These live in `ShelfCoreTests` because that is the target `swift test` runs —
/// on Linux as well, where the app cannot even be built. The files they read are
/// checked out there like any other.
@Suite("The window speaks German too")
struct LocalisationTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ShelfCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // the repository

    static let catalogueURL = repoRoot.appending(path: "App/Shelf/Resources/Localizable.xcstrings")
    static let appSources = repoRoot.appending(path: "App/Shelf")

    // MARK: Reading the catalogue

    static func catalogue() throws -> [String: Any] {
        let data = try Data(contentsOf: catalogueURL)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func strings() throws -> [String: Any] {
        try catalogue()["strings"] as? [String: Any] ?? [:]
    }

    /// Whether an entry has a finished translation in `language` — either a
    /// plain one or, for a counted sentence, one per plural category.
    ///
    /// A unit still marked `new` or `needs_review` does **not** count. That is
    /// a translation somebody meant to come back to, and until they do it ships
    /// as English.
    static func isTranslated(_ entry: Any, into language: String) -> Bool {
        guard let entry = entry as? [String: Any],
            let localizations = entry["localizations"] as? [String: Any],
            let side = localizations[language] as? [String: Any]
        else { return false }
        if let unit = side["stringUnit"] as? [String: Any] { return finished(unit) }
        guard let variations = side["variations"] as? [String: Any],
            let plural = variations["plural"] as? [String: Any], !plural.isEmpty
        else { return false }
        return plural.values.allSatisfy { category in
            guard let category = category as? [String: Any],
                let unit = category["stringUnit"] as? [String: Any]
            else { return false }
            return finished(unit)
        }
    }

    private static func finished(_ unit: [String: Any]) -> Bool {
        guard let value = unit["value"] as? String, !value.isEmpty else { return false }
        return (unit["state"] as? String) == "translated"
    }

    // MARK: The catalogue itself

    @Test("the catalogue is there and says what language it is written in")
    func catalogueExists() throws {
        #expect(FileManager.default.fileExists(atPath: Self.catalogueURL.path))
        #expect(try Self.catalogue()["sourceLanguage"] as? String == "en")
        #expect(try Self.strings().count > 200)
    }

    /// The test SlateKit 0.3.0 would have failed.
    @Test("every entry in the catalogue has a German translation")
    func everyEntryHasGerman() throws {
        let missing = try Self.strings()
            .filter { !Self.isTranslated($0.value, into: "de") }
            .keys.sorted()
        #expect(missing.isEmpty, "no German for \(missing.count): \(missing.prefix(20).joined(separator: " | "))")
    }

    /// And an English one, because a counted sentence needs its own plural
    /// forms in English too — "1 books" was in the window until this catalogue
    /// existed.
    @Test("every entry in the catalogue has an English one as well")
    func everyEntryHasEnglish() throws {
        let missing = try Self.strings()
            .filter { !Self.isTranslated($0.value, into: "en") }
            .keys.sorted()
        #expect(missing.isEmpty, "no English for \(missing.count): \(missing.prefix(20).joined(separator: " | "))")
    }

    // MARK: What the window asks for

    /// Every `Loc.string("…")` and `Loc.count("…")` in `App/Shelf`, with the
    /// `+`-joined continuations put back together.
    ///
    /// A small scan rather than a parse, for the reason SlateKit's is: it has
    /// one job, it is read by whoever adds the next sentence, and a regular
    /// expression over one call shape is easier to be sure about than a syntax
    /// tree. It only has to be right about `Loc.…("` followed by a literal —
    /// which is the only shape the app is allowed to use, and the test below
    /// is what enforces that.
    @Test("every sentence the window asks for is in the catalogue")
    func everyAskedSentenceIsInTheCatalogue() throws {
        let known = Set(try Self.strings().keys)
        var missing: [String] = []
        for file in try Self.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for key in Self.locKeys(in: text) where !known.contains(key) {
                missing.append("\(file.lastPathComponent): \(key)")
            }
        }
        #expect(missing.isEmpty, "asked for but not in the catalogue: \(missing.joined(separator: " | "))")
    }

    /// Every sentence `ShelfCore` can answer with, walked out of the core's own
    /// enumerations.
    ///
    /// Not a scan: these reach the window through `Loc.core`, which is handed a
    /// value at runtime, so there is no literal in `App/Shelf` to read. Walking
    /// the enumerations is better than a list would have been — an eighth
    /// `BookField` or a fourth `DuplicateReason` fails this the day it is added,
    /// which a list in a test would not.
    @Test("every sentence the core can answer with is in the catalogue")
    func everyCoreSentenceIsInTheCatalogue() throws {
        let known = Set(try Self.strings().keys)
        let missing = Self.coreSentences.filter { !known.contains($0) }.sorted()
        #expect(missing.isEmpty, "the core says these and the catalogue has not heard of them: \(missing)")
    }

    /// Everything `Loc.core` is ever handed.
    static var coreSentences: [String] {
        var all: [String] = []
        for field in BookField.allCases {
            all += [field.label, field.placeholder, field.hint]
        }
        all += SmartCollection.allCases.map(\.title)
        for reason in DuplicateReason.allCases { all += [reason.label, reason.detail] }
        all += DRMKind.allCases.map(\.label)
        all += BookSort.allCases.map(\.label)
        all += LibraryViewSettings.Mode.allCases.map(\.label)
        all += MetadataChange.Field.allCases.map(\.label)
        all += SkippedImport.Reason.allCases.map(\.label)
        all += SkippedTransfer.Reason.allCases.map(\.label)
        all += KoboReadingState.ReadStatus.allCases.map(\.label)
        all += DeviceFile.Match.allCases.map(\.label)
        all += CalibreCustomColumn.Kind.allCases.map(\.label)
        all += ShortcutReference.all.map(\.label)
        all += ShortcutGroup.allCases.map(\.rawValue)
        return all.filter { !$0.isEmpty }
    }

    /// The blunt one: a sentence drawn in the window that never went through
    /// `Loc` at all.
    ///
    /// The test above can only check what it is shown. A literal handed
    /// straight to `Text(…)` is invisible to it — and that is exactly how the
    /// first German run came out with an English sidebar: `SlateSidebarRow`
    /// takes its title as the first argument, which was not on any list, so
    /// seven smart collections and six section headings stayed English while
    /// every other word in the window turned over.
    ///
    /// So this one starts from the other end: **every** string literal in
    /// `App/Shelf` that reads like a sentence has to be inside a `Loc` call.
    /// What is not window text is named in `notWindowText` below, by file or by
    /// literal, which is a list somebody has to add to deliberately.
    @Test("no sentence is drawn without going through the catalogue")
    func nothingIsDrawnDirectly() throws {
        var stray: [String] = []
        for file in try Self.swiftSources() where !Self.exemptFiles.contains(file.lastPathComponent) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (line, literal) in Self.strayProse(in: text) {
                stray.append("\(file.lastPathComponent):\(line): \(literal)")
            }
        }
        #expect(stray.isEmpty, "drawn without Loc: \(stray.joined(separator: " | "))")
    }

    /// Files that hold no window text at all: the log, the readers' own
    /// diagnostics (which go into `Import-Report.txt`, and reports are English
    /// on purpose), the caches and the small services that draw nothing.
    static let exemptFiles: Set<String> = [
        "Strings.swift", "TimingLog.swift", "PDFFileReader.swift", "FileReader.swift",
        "RecentLibrariesStore.swift", "CoverDiskCache.swift", "SHA256Hasher.swift",
        "CoverDecoder.swift", "CoverLoader.swift", "QuickLookPreview.swift", "DeviceWatcher.swift",
        "EditingKeys.swift", "CoverWarmer.swift",
    ]

    /// Literals that are not sentences: header names, defaults keys, focus
    /// keys, a folder inside the caches, the app's own name.
    static let notWindowText: Set<String> = [
        "Library/Caches/Shelf", "Shelf/online", "User-Agent", "application/json", "Accept",
        "SHELF_ONLINE_HOST", "SHELF_TIMING", "recentLibraries", "identifier:", "shelf:",
        "libarchive (version unknown)", "Shelf",
        // A sort sentinel and a line break, neither of which anybody reads.
        "\\u{10FFFF}", "\\n",
    ]

    /// Lines that are plainly not drawing anything.
    static let notDrawing = [
        "logger", "Logger", "os_log", "systemName", "systemImage", "forKey", "UserDefaults",
        "withExtension", "subsystem", "category", "Notification.Name", "customizationID",
        "contentTypes", "privacy:", "warning:", "case \"",
    ]

    /// Every literal in `source` that reads like a sentence and is not inside a
    /// `Loc` call.
    static func strayProse(in source: String) -> [(Int, String)] {
        var found: [(Int, String)] = []
        let lines = source.components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            if Self.notDrawing.contains(where: { line.contains($0) }) { continue }
            // `case shelves = "Shelves"` is an **identity**, not a sentence:
            // it is what the section is stored and compared by, and a German
            // window that called it something else would disagree with an
            // English one about which section is which. What is drawn is the
            // `title` beside it, which does go through `Loc`.
            if trimmed.hasPrefix("case "), trimmed.contains(" = \"") { continue }
            // A line that is only a literal continues the key above it.
            let previous = offset > 0 ? lines[offset - 1].trimmingCharacters(in: .whitespaces) : ""
            let isContinuation =
                (trimmed.hasPrefix("\"") || trimmed.hasPrefix("+ \""))
                && (previous.contains("Loc.") || previous.hasPrefix("\"") || previous.hasPrefix("+ \""))
            if isContinuation { continue }
            for (column, literal) in Self.literals(in: line) where Self.readsLikeASentence(literal) {
                // Inside a `Loc.…(` on this line? Then it is a key, not a stray.
                let before = String(line.prefix(column))
                if let call = before.range(of: "Loc.", options: .backwards),
                    !before[call.upperBound...].contains(")")
                {
                    continue
                }
                found.append((offset + 1, literal))
            }
        }
        return found
    }

    /// Whether a literal is a sentence somebody reads rather than a key, a
    /// path, a file name or a format specifier.
    static func readsLikeASentence(_ value: String) -> Bool {
        if value.count < 2 { return false }
        if !value.contains(where: \.isLetter) { return false }
        if value.contains("://") || value.hasPrefix("/") { return false }
        if notWindowText.contains(value) { return false }
        if value.contains("\\(") { return false }
        // An identifier, a key or an SF Symbol name: lower case, no spaces.
        if value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) {
            return false
        }
        if value.hasPrefix("%") { return false }
        return true
    }

    /// Every literal in one line, with the column it starts at.
    static func literals(in line: String) -> [(Int, String)] {
        var found: [(Int, String)] = []
        var index = line.startIndex
        var column = 0
        while index < line.endIndex {
            if line[index] == "\"" {
                let start = column
                guard let (value, after) = Self.literal(in: line[index...]) else { return found }
                found.append((start, value))
                column += line.distance(from: index, to: after.startIndex)
                index = after.startIndex
                continue
            }
            index = line.index(after: index)
            column += 1
        }
        return found
    }

    // MARK: Reading the sources

    static func swiftSources() throws -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: appSources, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// `Loc.string("…")` / `Loc.count("…")`, including a key written across
    /// several lines with `+`.
    static func locKeys(in source: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(source)
        while let call = Self.nextCall(in: rest) {
            rest = rest[call.upperBound...]
            // Skip the whitespace and newlines a formatted call site may have
            // between the bracket and the literal.
            let opening = rest.drop { $0 == " " || $0 == "\n" }
            guard opening.first == "\"" else { continue }
            var scan = opening
            var key = ""
            // One literal, then any `+ "…"` continuations before the comma or
            // the closing bracket.
            while scan.first == "\"" {
                guard let (piece, after) = Self.literal(in: scan) else { break }
                key += piece
                scan = after.drop { $0 == " " || $0 == "\n" }
                guard scan.first == "+" else { break }
                scan = scan.dropFirst().drop { $0 == " " || $0 == "\n" }
            }
            if !key.isEmpty, !key.contains("\\(") { keys.append(key) }
            rest = scan
        }
        return keys
    }

    /// The next `Loc.…("` in `text`. Three call shapes draw a key from a
    /// literal; `Loc.core` is not one of them, because what it is handed is a
    /// value rather than a literal.
    private static func nextCall(in text: Substring) -> Range<Substring.Index>? {
        ["Loc.string(", "Loc.count(", "Loc.contextual("]
            .compactMap { text.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// The contents of the literal `text` starts with, and what follows it.
    static func literal(in text: Substring) -> (String, Substring)? {
        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { return nil }
                // `\"` is a quotation mark in the sentence, not its end; every
                // other escape is kept as written so the key matches the
                // catalogue, which holds the same two characters.
                value += text[next] == "\"" ? "\"" : "\\\(text[next])"
                index = text.index(after: next)
                continue
            }
            if character == "\"" { return (value, text[text.index(after: index)...]) }
            value.append(character)
            index = text.index(after: index)
        }
        return nil
    }
}
