import Foundation

/// Whether a folder an organise has just emptied may be taken away, and how.
///
/// This is the only place in Shelf's library handling that removes a *folder*,
/// so the rule and the act are kept apart: the rule is a pure function that
/// runs on Linux and is tested there, and the act goes through a seam
/// (`FolderDisposal`) so that what actually happens on a Mac is the Trash and
/// not an `rmdir`.
///
/// **Why anything may be removed at all.** An organise moves a book out of
/// `Atwood, Adrian/` and into `Fitzek, Sebastian/`. What is left is an author
/// folder for an author no book in the library has any more. Leaving them means
/// an organise that tidies the books and litters the library — a merge of
/// fifty-five spellings left fifty-five of them in the closing run. But a
/// folder is not a file, and "it looked empty" is not good enough, so:
public enum EmptiedFolder {

    /// Names that are the file system talking to itself, not somebody's data.
    ///
    /// An allow-list and never "anything beginning with a dot": a dot file is
    /// how a great many programs keep something that matters — `.gitignore`,
    /// `.calibre`, a note somebody hid on purpose — and the difference between
    /// "the Finder has looked in here" and "somebody put something in here" is
    /// the whole of this decision.
    ///
    /// Spotlight's are matched by prefix because their names carry a volume
    /// UUID (`.Spotlight-V100`, `.com.apple.timemachine.donotpresent`,
    /// `.fseventsd`), and Windows and Linux leave their own when a library has
    /// travelled.
    public static let systemResidue: Set<String> = [
        ".DS_Store", ".localized", ".fseventsd", ".Spotlight-V100", ".TemporaryItems",
        ".DocumentRevisions-V100", ".apdisk", ".VolumeIcon.icns", ".com.apple.timemachine.donotpresent",
        // Not Apple's, and a library folder is a thing people copy between
        // machines: these arrive from a Windows or a Linux file manager.
        "Thumbs.db", "desktop.ini", ".directory", ".Trash-1000",
    ]

    public static func isSystemResidue(_ name: String) -> Bool {
        systemResidue.contains(name)
            || name.hasPrefix(".Spotlight-")
            || name.hasPrefix(".TemporaryItems")
            || name.hasPrefix("._")  // an AppleDouble left by a copy onto FAT
    }

    /// Whether a folder holding exactly these entries counts as emptied.
    ///
    /// `false` for a folder holding nothing but residue *and* something else,
    /// and — deliberately — `true` for one holding only residue. Before
    /// Sprint 8's closing review this said `contents.isEmpty`, which meant a
    /// single `.DS_Store` kept an author folder alive for ever: the Finder
    /// writes one the moment somebody opens the folder to look at it, so
    /// "looked at once" became "never tidied".
    public static func holdsNothingButResidue(_ contents: [String]) -> Bool {
        contents.allSatisfy(isSystemResidue)
    }

    /// Whether this path is one an organise is allowed to consider at all.
    ///
    /// Four conditions, and they are here rather than at the call site so a
    /// test can state each one:
    ///
    /// 1. it is the **parent of a folder this run has just moved out** — the
    ///    caller passes that path, and nothing else ever reaches here;
    /// 2. that parent is a *direct child* of the library root — an author
    ///    folder, the only level a book folder can be moved out of;
    /// 3. it is not `.shelf`;
    /// 4. it is not the root itself, and not empty.
    ///
    /// Returns the author folder's name, or `nil`.
    public static func candidate(parentOf movedFrom: String) -> String? {
        let components = movedFrom.split(separator: "/").map(String.init)
        guard components.count == 2 else { return nil }
        let parent = components[0]
        guard !parent.isEmpty, parent != Library.privateFolderName, parent != "." else { return nil }
        return parent
    }
}

/// How a folder Shelf has finished with is disposed of.
///
/// A seam, for the reason every seam in this project exists: the decision is
/// testable without a file system, and the act is the platform's. It also
/// answers a question the core cannot — `FileManager.trashItem` is Darwin's
/// and is not in swift-corelibs-foundation, so a core that called it directly
/// would not build on Linux, which is the guard rail that keeps this package
/// honest.
public struct FolderDisposal: Sendable {
    /// Moves the folder somewhere it can be got back from. Throws if it
    /// cannot, and the caller then leaves the folder exactly where it is.
    public var dispose: @Sendable (URL) throws -> Void

    public init(dispose: @escaping @Sendable (URL) throws -> Void) {
        self.dispose = dispose
    }

    public enum Failure: Error, Equatable {
        /// There is no Trash on this platform. Nothing is removed, because
        /// "nothing is deleted outright" is a rule and not a preference.
        case noTrashHere
    }

    /// **The Trash, never `removeItem`.** An empty author folder is worth very
    /// little, and that is not the point: the point is that a person can look
    /// in the Trash and see what a command did, and drag it back. A folder
    /// that has gone is a folder nobody can check.
    public static let trash = FolderDisposal { url in
        #if os(macOS)
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        #else
            throw Failure.noTrashHere
        #endif
    }

    /// Leaves everything where it is. What a dry run uses, and what a test
    /// uses to prove that nothing is removed behind the seam's back.
    public static let none = FolderDisposal { _ in throw Failure.noTrashHere }
}
