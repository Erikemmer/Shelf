import Foundation
import Testing

@testable import ShelfCore

/// The shortcut table is read by three places — the menu bar, the ⌘? sheet and
/// the welcome screen's one line — and a reference that tells three different
/// stories is worse than none.
///
/// Until Sprint 7 the menu bar was not one of the three; it declared its keys by
/// hand. Two things had drifted by the time anybody looked:
///
/// - **⌘A and ⇧⌘W were in the menus and in no reference.** Select All Books and
///   Close Library worked and were written down nowhere a user could read.
/// - **⌥⌘I was declared twice**, on `File ▸ Import from Calibre…` and on
///   `View ▸ Inspector`. AppKit gives the first matching item the key, so the
///   inspector's shortcut had never worked. CONCEPT §3.3 says ⌘I is the
///   inspector and ⌥⌘I the Calibre import, so that is what the table now says,
///   and Add Books — which had taken ⌘I — moved to ⇧⌘I.
///
/// These are the tests that make a third one impossible without noticing.
@Suite("One table, and the menu bar reads it")
struct ShortcutTests {
    @Test("no action is listed twice")
    func everyActionIsListedOnce() {
        let ids = ShortcutReference.all.map(\.id)
        #expect(Set(ids).count == ids.count, "listed twice: \(ids)")
    }

    @Test("every action in the enumeration is in the table")
    func everyActionHasARow() {
        let listed = Set(ShortcutReference.all.map(\.id))
        let missing = ShortcutAction.allCases.filter { !listed.contains($0) }
        #expect(missing.isEmpty, "not in the table: \(missing.map(\.rawValue))")
    }

    /// The two halves of an entry: the string the sheet prints, and the chord
    /// the menu declares. Written separately because they are read by different
    /// things; held against each other here, so an entry that says ⌘O and
    /// declares ⌘P cannot be committed.
    @Test("what the sheet prints is what the menu declares")
    func printedKeysMatchTheChord() {
        for shortcut in ShortcutReference.all {
            guard let key = shortcut.menuKey else { continue }
            #expect(
                key.printed == shortcut.keys,
                "\(shortcut.id.rawValue): the sheet prints “\(shortcut.keys)”, the menu declares “\(key.printed)”")
        }
    }

    /// ADR 0006 and ADR 0017, as a rule rather than as a habit. A menu key
    /// equivalent is offered the event before the responder chain — so a bare
    /// digit never reaches a text field — and a *held* one spends 58 % of its
    /// time inside AppKit's menu machinery. Every chord the menu bar may
    /// declare therefore has ⌘ in it.
    @Test("a menu shortcut always has ⌘ in it")
    func everyMenuChordIsCommanded() {
        for shortcut in ShortcutReference.all {
            guard let key = shortcut.menuKey else { continue }
            #expect(
                key.modifiers.contains(.command) || key.key == .newline,
                "\(shortcut.id.rawValue) would be a menu key equivalent without ⌘")
        }
    }

    /// One chord, one action. `⌥⌘I` was on two menu items for four sprints and
    /// the second of them simply did nothing.
    @Test("no two actions claim the same chord")
    func noChordIsClaimedTwice() {
        var seen: [ShortcutKey: ShortcutAction] = [:]
        for shortcut in ShortcutReference.all {
            guard let key = shortcut.menuKey else { continue }
            if let other = seen[key] {
                Issue.record(
                    "\(shortcut.id.rawValue) and \(other.rawValue) both claim \(key.printed)")
            }
            seen[key] = shortcut.id
        }
    }

    /// CONCEPT §3.3 is the specification, and the table is what the window
    /// obeys. The five that differ from a plain reading of the source are worth
    /// naming: the concept writes ⌘⌥I, ⌘⇧S and ⌘? and this table writes the
    /// modifiers in the order macOS draws them.
    @Test("the keys CONCEPT §3.3 names are the keys the table holds")
    func theConceptsKeysAreTheTables() {
        let expected: [ShortcutAction: String] = [
            .search: "⌘F",
            .inspector: "⌘I",
            .fetchMetadata: "⌘E",
            .sendToDevice: "⇧⌘S",
            .importFromCalibre: "⌥⌘I",
            .openLibrary: "⌘O",
            .undoRedo: "⌘Z / ⇧⌘Z",
            .thisList: "⌘?",
            .quickLook: "␣",
            .openInDefaultApp: "↩",
            .rating: "1–5, 0",
            .readUnread: "R",
            .editTags: "T",
            .moveThroughTheGrid: "←→↑↓",
            // Added to the concept's table in Sprint 7, because they were in
            // the menus and in no reference — and because ⌘I had to be taken
            // back from Add Books to give the Inspector the key CONCEPT §3.3
            // always gave it.
            .addBooks: "⇧⌘I",
            .selectAllBooks: "⌘A",
            .closeLibrary: "⇧⌘W",
            .grid: "⌘1",
            .table: "⌘2",
            .largerCovers: "⌘+",
            .smallerCovers: "⌘−",
            .firstOrLastBook: "↖ / ↘",
        ]
        for (id, keys) in expected {
            #expect(ShortcutReference.find(id)?.keys == keys, "\(id.rawValue)")
        }
    }

    /// The blunt one: **no key equivalent is written by hand in the window.**
    ///
    /// The tests above can only check the table. This one starts from the other
    /// end and reads the app's own source, because the failure being prevented
    /// is a `.keyboardShortcut("x", modifiers: .command)` somebody adds beside
    /// a new menu item without touching the table — which is exactly how ⌘A and
    /// ⇧⌘W came to exist in no reference at all.
    @Test("no window declares a key equivalent of its own")
    func theWindowDeclaresNoKeysOfItsOwn() throws {
        var found: [String] = []
        for file in try LocalisationTests.swiftSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains(".keyboardShortcut("), !trimmed.hasPrefix("//") else { continue }
                // The one permitted call is the bridge in `Theme.swift`, which
                // is handed whatever the table holds and nothing of its own.
                if trimmed.contains("ShortcutReference.find") { continue }
                // `.defaultAction` and `.cancelAction` are ⏎ and Escape inside
                // a sheet. They belong to the sheet that is open and to no
                // menu, so they are not shortcuts a reference could list —
                // every dialogue on this platform has them and nobody looks
                // them up.
                if trimmed.contains(".defaultAction"), trimmed.contains(".cancelAction") { continue }
                if trimmed.contains("keyboardShortcut(.defaultAction)") { continue }
                if trimmed.contains("keyboardShortcut(.cancelAction)") { continue }
                found.append("\(file.lastPathComponent):\(number + 1): \(trimmed)")
            }
        }
        #expect(found.isEmpty, "declared outside the table: \(found.joined(separator: " | "))")
    }
}
