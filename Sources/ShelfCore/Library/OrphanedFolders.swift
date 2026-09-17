import Foundation

/// A book folder the index knows nothing about.
///
/// These are what an interrupted import leaves behind. `ImportRunner` writes
/// each book's folder, file, cover and OPF before the book reaches `saveBatch`,
/// and `saveBatch` runs every 200 books — so a run that is *killed* (rather
/// than cancelled, which still saves its short last batch) leaves up to 200
/// finished folders the index never heard of. In the Sprint 3 measurement run
/// it was 23.
///
/// Nothing here deletes anything. The type answers "which folders are these"
/// and names every file in them; moving them to the Trash is a separate,
/// confirmed step, and the Trash rather than `unlink` because a folder that
/// turns out to have been somebody's book has to be gettable back.
public struct OrphanedFolder: Identifiable, Equatable, Sendable {
    public var id: String { path }

    /// Relative to the library root: `Austen, Jane/Emma (17)`.
    public var path: String
    /// From the folder's own `metadata.opf`, when it has one.
    ///
    /// This is the whole of what makes re-use possible: the runner writes the
    /// OPF with the book's UUID in it, so a leftover folder can say which book
    /// it was going to be, and a resumed import can take it over instead of
    /// making a second folder for the same book (CONCEPT §5.3).
    public var bookID: UUID?
    /// For the confirmation list, so a person reads a title rather than a path.
    public var title: String?
    /// Every file in the folder, by name. The confirmation names all of them —
    /// the same rule as deleting on a device (CONCEPT §8.3): nothing goes that
    /// was not read out first.
    public var files: [String]
    public var byteSize: Int64
    /// Whether the folder holds a file in a format Shelf reads. A folder with
    /// no book in it is debris either way, but a folder *with* one is a book
    /// that fell out of the index, which is a different thing to tell someone.
    public var holdsABook: Bool

    public init(
        path: String, bookID: UUID? = nil, title: String? = nil, files: [String] = [],
        byteSize: Int64 = 0, holdsABook: Bool = false
    ) {
        self.path = path
        self.bookID = bookID
        self.title = title
        self.files = files
        self.byteSize = byteSize
        self.holdsABook = holdsABook
    }

    /// The line the confirmation dialog shows for this folder.
    public var summary: String {
        let name = title ?? path
        let count = files.count
        return "\(name) — \(count) file\(count == 1 ? "" : "s"), \(ByteCount.format(byteSize))"
    }
}

/// Finding the folders no book points at, and taking the ones that belong back.
///
/// Two jobs that look like one and are not:
///
/// * **Adoption** happens by itself, inside a resumed import. A folder whose
///   OPF carries a UUID this very run is importing is that book's folder; the
///   run reads it into the index and then plans against a library that has it,
///   so the file is recognised as already there and no second folder is made.
/// * **Everything left over** is reported, by path, and shown by
///   `Library ▸ Find Orphaned Folders…`. Shelf does not guess at those. They
///   move to the Trash on an explicit confirmation that names every file, or
///   they stay where they are.
public enum OrphanedFolders {

    /// The book folders under `library.root` that `knownFolders` does not hold.
    ///
    /// Exactly two levels deep, like `IndexRebuilder`: that is the layout
    /// (CONCEPT §5.1), and a recursive walk would call a folder somebody
    /// dropped in by hand an orphan.
    ///
    /// - Parameter knownFolders: the `folder` of every entry in the index,
    ///   relative to the root.
    public static func find(in library: Library, knownFolders: Set<String>) -> [OrphanedFolder] {
        let manager = FileManager.default
        // Case-insensitively, because APFS is: a folder the index recorded as
        // `Austen, Jane/Emma (3)` and read back as `austen, jane/Emma (3)` is
        // one folder, and calling it an orphan would offer to trash a book.
        let known = Set(knownFolders.map { $0.lowercased() })

        guard
            let authors = try? manager.contentsOfDirectory(
                at: library.root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return [] }

        var found: [OrphanedFolder] = []
        for author in authors
        where author.hasDirectoryPath && author.lastPathComponent != Library.privateFolderName {
            let books =
                (try? manager.contentsOfDirectory(
                    at: author, includingPropertiesForKeys: [.isDirectoryKey], options: []))?
                .filter(\.hasDirectoryPath) ?? []

            for book in books {
                let relative = "\(author.lastPathComponent)/\(book.lastPathComponent)"
                guard !known.contains(relative.lowercased()) else { continue }
                found.append(describe(book, relative: relative))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Reads one folder without hashing anything: the names, the sizes, and
    /// whatever the OPF is willing to say.
    private static func describe(_ folder: URL, relative: String) -> OrphanedFolder {
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()

        var bytes: Int64 = 0
        for name in names {
            let attributes = try? manager.attributesOfItem(
                atPath: folder.appendingPathComponent(name).path)
            bytes += (attributes?[.size] as? Int64) ?? 0
        }

        // The OPF is read for its UUID and its title and for nothing else. A
        // broken one costs the folder its identity, not its place in the list:
        // it is still reported, just as one Shelf cannot attribute.
        var bookID: UUID?
        var title: String?
        let opf = folder.appendingPathComponent(OPFDocument.fileName)
        if let data = try? Data(contentsOf: opf),
            let parsed = try? OPFDocument.read(data, fallbackTitle: IndexRebuilder.title(in: folder.lastPathComponent))
        {
            bookID = parsed.book.id
            title = parsed.book.title
        }

        let holdsABook = names.contains { BookFileFormat.from(fileExtension: ($0 as NSString).pathExtension) != nil }
        return OrphanedFolder(
            path: relative, bookID: bookID,
            title: title ?? IndexRebuilder.title(in: folder.lastPathComponent),
            files: names, byteSize: bytes, holdsABook: holdsABook)
    }

    /// The orphans a run that is importing `bookIDs` can take over as its own.
    ///
    /// Only by UUID, and only for a folder that actually holds a book. An
    /// orphan whose OPF is gone cannot be attributed to anything and is left
    /// for the user to look at — guessing from a title would sooner or later
    /// pour one book's files into another book's folder.
    public static func claimable(_ orphans: [OrphanedFolder], importing bookIDs: Set<UUID>) -> [OrphanedFolder] {
        orphans.filter { orphan in
            guard orphan.holdsABook, let id = orphan.bookID else { return false }
            return bookIDs.contains(id)
        }
    }

    /// Reads claimed folders into index entries, so the library holds them
    /// before the plan is made.
    ///
    /// This is the step that turns a leftover into a book again: afterwards the
    /// index knows the folder, the file and its digest, and the ordinary
    /// planner rules do the rest — the same file is a duplicate of itself and
    /// is skipped, a second format joins it in the folder it is already in.
    /// Nothing is copied and nothing is written into the folder.
    public static func adopt(
        _ orphans: [OrphanedFolder], in library: Library, makeHasher: @escaping HasherFactory
    ) -> [LibraryEntry] {
        let rebuilder = IndexRebuilder(makeHasher: makeHasher)
        return orphans.compactMap { orphan in
            let url = library.root.appendingPathComponent(orphan.path, isDirectory: true)
            return try? rebuilder.readFolder(url, relative: orphan.path)?.entry
        }
    }

    /// Moves the named folders to the Trash.
    ///
    /// The Trash and never `removeItem`: a folder Shelf believes is debris may
    /// be a book whose OPF went missing, and the difference between a mistake
    /// and a disaster is whether the user can drag it back out. On Linux there
    /// is no Trash, so this refuses rather than deleting — the core builds
    /// there for CI and nobody runs this there.
    ///
    /// Returns what could not be moved, by path and reason; an empty array
    /// means every one of them went.
    public static func moveToTrash(
        _ orphans: [OrphanedFolder], in library: Library
    ) -> [(path: String, message: String)] {
        var failures: [(path: String, message: String)] = []
        for orphan in orphans {
            let url = library.root.appendingPathComponent(orphan.path, isDirectory: true)
            #if canImport(Darwin)
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    failures.append((orphan.path, (error as NSError).localizedDescription))
                }
            #else
                failures.append((orphan.path, "there is no Trash on this platform, so nothing was moved"))
            #endif
        }
        return failures
    }
}
