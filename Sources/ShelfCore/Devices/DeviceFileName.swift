import Foundation

/// What a book is called once it is on a device.
///
/// `{author} - {title}.{ext}` — the other way round from the library's own file
/// names, which are `{title} - {author}`, because a reader sorts its file list
/// by name and an author-first list is the one people want there (CONCEPT §8.2).
///
/// **The rule is in the core, with tests**, because the file system at the far
/// end is the strictest one in the chain. Every reader that takes a USB cable
/// is formatted FAT32 or exFAT, and both of them will refuse, silently mangle
/// or quietly merge names that APFS takes without comment. A name that imports
/// fine and cannot be sent would be two rules that have to stay in step, which
/// is why `BookFolderName.sanitised` already carries FAT's forbidden characters
/// and why this calls it rather than growing a second copy.
public enum DeviceFileName {

    /// `{author}` and `{title}`, and nothing else is substituted.
    public static let defaultPattern = "{author} - {title}"

    /// How long one name may be.
    ///
    /// FAT's long-name entries count **UTF-16 code units**, not bytes, where
    /// APFS and ext4 count bytes — so both limits are applied and the shorter
    /// one wins. A German title in NFD is longer in bytes than it looks; an
    /// emoji is two UTF-16 units and four bytes. Neither budget can be derived
    /// from the other.
    public static let maxNameBytes = 255
    public static let maxNameUTF16 = 255

    /// A file of 4 GiB or more cannot exist on FAT32 at all: the directory
    /// entry stores the size in 32 bits. exFAT has no such limit.
    public static let fat32MaxFileBytes: Int64 = 4_294_967_295

    /// What `statfs` calls the file systems with that limit.
    public static let fat32FileSystemNames: Set<String> = ["msdos", "fat32", "vfat", "fat"]

    /// The name one book gets in one format on one device.
    public static func of(
        _ book: Book, format: BookFileFormat, pattern: String = defaultPattern
    ) -> String {
        let author = BookFolderName.sanitised(book.primaryAuthor, fallback: Book.unknownAuthor)
        let title = BookFolderName.sanitised(book.title, fallback: "Untitled")
        let stem = BookFolderName.sanitised(
            pattern
                .replacingOccurrences(of: "{author}", with: author)
                .replacingOccurrences(of: "{title}", with: title),
            fallback: "Untitled")
        let ext = ".\(format.fileExtension)"
        return "\(truncated(stem, room: ext))\(ext)"
    }

    /// Cuts the stem to whichever of the two budgets bites first, without
    /// splitting a character and without leaving a trailing dot or space —
    /// FAT drops those, and two titles that differ only there would become one
    /// file landing on top of the other.
    static func truncated(_ stem: String, room ext: String) -> String {
        let byteBudget = maxNameBytes - ext.utf8.count
        let unitBudget = maxNameUTF16 - ext.utf16.count
        guard stem.utf8.count > byteBudget || stem.utf16.count > unitBudget else { return stem }

        var result = ""
        var bytes = 0
        var units = 0
        for character in stem {
            let size = String(character).utf8.count
            let width = String(character).utf16.count
            if bytes + size > byteBudget || units + width > unitBudget { break }
            result.append(character)
            bytes += size
            units += width
        }
        while let last = result.last, last == " " || last == "." { result.removeLast() }
        return result.isEmpty ? "Untitled" : result
    }

    /// Whether this file is too big for the volume's file system.
    public static func isTooBig(_ byteSize: Int64, forFAT32 limited: Bool) -> Bool {
        limited && byteSize > fat32MaxFileBytes
    }
}
