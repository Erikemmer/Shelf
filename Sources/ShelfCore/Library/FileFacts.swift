import Foundation

/// What the file system says about one file, with symlinks followed.
///
/// It exists because `FileManager.attributesOfItem(atPath:)` does **not**
/// follow a symlink – it reports the link's own size and date – while
/// `FileHandle(forReadingAtPath:)` does follow it. A symlinked book therefore
/// imported with the right content and a size of about eighty bytes, which is
/// the sort of disagreement that makes a library's numbers quietly wrong. Found
/// while importing real books through symlinks.
///
/// One place, so the importer and the command-line tool cannot differ about it.
public struct FileFacts: Equatable, Sendable {
    /// The file itself, with any symlinks resolved – what should be read and
    /// copied.
    public var url: URL
    public var byteSize: Int64
    public var modifiedAt: Date

    public init(url: URL, byteSize: Int64, modifiedAt: Date) {
        self.url = url
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
    }

    /// Reads the facts, or nil when the file cannot be reached at all.
    public static func of(_ url: URL) -> FileFacts? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            let byteSize = attributes[.size] as? Int64
        else { return nil }
        return FileFacts(
            url: resolved,
            byteSize: byteSize,
            modifiedAt: (attributes[.modificationDate] as? Date) ?? Date())
    }
}
