import Foundation

/// Whether the folder at a path is a particular book's.
///
/// Its own type because two callers need exactly this answer — the command
/// line and the window — and because the rule inside it is the one
/// `OrphanedFolders.claimable` already had to learn: **by UUID, never by
/// title.** A folder whose `metadata.opf` names a different book is a
/// different book's folder however alike the names look, and matching on a
/// title would sooner or later pour one book's files into another's.
public enum OrganizeBookProbe {

    /// `true` when the folder holds a `metadata.opf` naming this very book.
    ///
    /// A folder with no readable OPF answers `false`. That is the cautious
    /// way round: the question is only ever asked to decide whether a book has
    /// *already been moved there*, and answering yes on a folder that cannot
    /// say who it belongs to would file a book at a path on a guess.
    public static func holdsBook(at relativePath: String, id: UUID, under root: URL) -> Bool {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
            .appendingPathComponent(OPFDocument.fileName)
        guard let data = try? Data(contentsOf: url),
            let parsed = try? OPFDocument.read(data, fallbackTitle: "")
        else { return false }
        return parsed.book.id == id
    }

    /// Whether anything is at this path at all.
    public static func exists(_ relativePath: String, under root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    /// Whether the folder there holds nothing a person would miss.
    ///
    /// Hidden entries do not count here, and that is the opposite of the rule
    /// `OrganizeRunner` uses before it *removes* a folder. Deliberately: this
    /// answers "may a book be moved in here", where a stray `.DS_Store` is no
    /// reason to refuse; that one answers "may this folder be removed", where
    /// anything at all is a reason to leave it alone.
    public static func isEmpty(_ relativePath: String, under root: URL) -> Bool {
        let names =
            (try? FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(relativePath).path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.isEmpty
    }
}
