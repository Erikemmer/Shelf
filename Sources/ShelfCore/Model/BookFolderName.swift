import Foundation

/// Where a book lives inside the library folder.
///
/// `Austen, Jane/Pride and Prejudice (17)/` – Calibre's layout, kept on purpose
/// so an import can take a tree over unchanged and a return to Calibre stays
/// possible (CONCEPT §5.1). Pure and tested: a wrong folder name means a book
/// that cannot be found again, and the index is rebuilt from these paths.
public enum BookFolderName {
    /// How long one path component may be. 255 is the limit on APFS, HFS+ and
    /// ext4 alike, in *bytes* for the last two – so the cut is made on bytes,
    /// not characters, and never inside one.
    public static let maxComponentBytes = 255

    /// The author part: "Austen, Jane".
    ///
    /// Cut to the byte limit like the other two. It was not, until Sprint 8
    /// asked every component of a built path whether it was legal and one
    /// answered no: `titleComponent` and `fileName` both truncated and this
    /// one did not, so a `dc:creator` holding a sentence — which real EPUBs
    /// do, and which `AuthorSort` then turns into one long component — made a
    /// folder the file system refuses. That failed the *import* of that book,
    /// not only its organise, and it had been so since Sprint 1.
    public static func authorComponent(for book: Book) -> String {
        truncated(
            sanitised(AuthorSort.of(book.primaryAuthor), fallback: Book.unknownAuthor),
            toBytes: maxComponentBytes)
    }

    /// The title part with the library's own running number: "Pride and
    /// Prejudice (17)".
    ///
    /// The number is what makes the name unique – two books can share a title
    /// and an author, and Calibre's own tree relies on the same trick. It is
    /// the library's integer id, not the UUID: a 36-character UUID in every
    /// folder name would make the paths unreadable and push against the length
    /// limit for nothing.
    public static func titleComponent(for book: Book, number: Int) -> String {
        let suffix = " (\(number))"
        let room = maxComponentBytes - suffix.utf8.count
        let title = truncated(sanitised(book.title, fallback: "Untitled"), toBytes: room)
        return "\(title)\(suffix)"
    }

    /// The book's folder, relative to the library root.
    public static func relativePath(for book: Book, number: Int) -> String {
        "\(authorComponent(for: book))/\(titleComponent(for: book, number: number))"
    }

    /// The file name one format of the book gets: "Pride and Prejudice - Jane
    /// Austen.epub", like Calibre's.
    ///
    /// Sanitised for FAT32 as well, because the same rule names files on a
    /// Kobo or a Kindle (CONCEPT §8.2) and a name that works in one place and
    /// not the other would be two rules that have to stay in step.
    public static func fileName(for book: Book, format: BookFileFormat) -> String {
        let ext = ".\(format.fileExtension)"
        let author = sanitised(book.primaryAuthor, fallback: Book.unknownAuthor)
        let title = sanitised(book.title, fallback: "Untitled")
        let stem = "\(title) - \(author)"
        return "\(truncated(stem, toBytes: maxComponentBytes - ext.utf8.count))\(ext)"
    }

    // MARK: Sanitising

    /// Characters no file system in the chain will take.
    ///
    /// The union of three sets, because one name has to survive all of them:
    /// `/` and NUL (POSIX), `:` (HFS and the Finder show it as `/`), and
    /// `\ * ? " < > |` (FAT32 and exFAT, which is what every e-reader is
    /// formatted with). Keeping them apart would mean a name that imports fine
    /// and then cannot be sent to a device.
    public static let forbidden: Set<Character> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|", "\0"]

    /// Names Windows and therefore FAT reserves outright, whatever the
    /// extension. A book called "CON" is unlikely and would be unopenable.
    public static let reservedNames: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    ]

    /// One path component, safe everywhere Shelf writes.
    ///
    /// Forbidden characters and control characters become a single space, runs
    /// of whitespace collapse, and trailing dots and spaces go – FAT silently
    /// drops those, so "Vol. 2 ." and "Vol. 2" would be the same folder and one
    /// book would land on top of the other.
    public static func sanitised(_ raw: String, fallback: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in raw {
            if forbidden.contains(character) || character.isNewline || character.unicodeScalars.allSatisfy(isControl) {
                pendingSpace = true
                continue
            }
            if character == " " || character == "\t" {
                pendingSpace = true
                continue
            }
            if pendingSpace, !result.isEmpty { result.append(" ") }
            pendingSpace = false
            result.append(character)
        }
        // Leading dots hide a folder on every Unix; trailing dots and spaces
        // are dropped by FAT.
        while let first = result.first, first == "." { result.removeFirst() }
        while let last = result.last, last == "." || last == " " { result.removeLast() }

        if result.isEmpty { return fallback }
        if reservedNames.contains(result.lowercased()) { return "\(result)_" }
        return result
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// Cuts a name to a byte budget without splitting a character in half.
    ///
    /// Byte-wise, because the limit is bytes: 255 emoji are 1 020 bytes, and a
    /// German title in NFD can be a third longer than its character count
    /// suggests.
    public static func truncated(_ name: String, toBytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard name.utf8.count > limit else { return name }
        var result = ""
        var used = 0
        for character in name {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        // Trailing space after a cut, again: FAT drops it and two different
        // titles would collapse into one folder.
        while let last = result.last, last == " " || last == "." { result.removeLast() }
        return result
    }
}
