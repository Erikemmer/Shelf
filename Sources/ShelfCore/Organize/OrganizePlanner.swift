import Foundation

/// One book's folder moving from where it is to where its metadata says it
/// should be.
public struct OrganizeMove: Equatable, Sendable, Identifiable {
    public var bookID: UUID
    public var title: String
    public var author: String
    /// Relative to the library root, as `LibraryEntry.folder` keeps it.
    public var from: String
    public var to: String
    /// Whether this move only changes the case of a name, on a volume where
    /// that makes the two one folder. Such a move goes through a third name;
    /// see `OrganizeRunner`.
    public var isCaseOnly: Bool

    public var id: UUID { bookID }

    public init(
        bookID: UUID, title: String, author: String, from: String, to: String,
        isCaseOnly: Bool = false
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.from = from
        self.to = to
        self.isCaseOnly = isCaseOnly
    }
}

/// A book the organise will not move, and why — in the words the preview shows.
public struct BlockedBook: Equatable, Sendable, Identifiable {
    public var bookID: UUID
    public var title: String
    public var wantedPath: String
    public var reason: Reason

    public var id: UUID { bookID }

    public enum Reason: String, Sendable, CaseIterable {
        /// Another book in this library wants the very same path. Both are
        /// left alone: picking one of them is the kind of decision that quietly
        /// buries a book inside another book's folder.
        case collision
        /// The same, but the two paths differ only in case — a collision on
        /// this volume and not on a case-sensitive one. Named apart because
        /// the two need different explanations.
        case caseOnlyCollision
        /// Something is already at the destination and it is not empty.
        /// Nothing is ever written over (ADR 0002, decision 4).
        case destinationIsNotEmpty
        /// The book's own folder is not where the index says it is, so there
        /// is nothing to move. A rebuild is the answer, not a move.
        case sourceMissing
        /// A path component would be longer than the file system allows, even
        /// after `BookFolderName` has cut it. Should be impossible, and is
        /// checked rather than trusted: it is the failure that reaches only
        /// the longest titles, which is the kind that reaches a user rather
        /// than a test (ADR 0002, decision 3).
        case nameTooLong

        public var label: String {
            switch self {
            case .collision: return "two books want this same folder"
            case .caseOnlyCollision:
                return "two books want folders that differ only in capitals, which is one folder here"
            case .destinationIsNotEmpty: return "something is already there, and it is not empty"
            case .sourceMissing: return "the book's folder is not where the index says it is"
            case .nameTooLong: return "the name would be too long for this file system"
            }
        }
    }

    public init(bookID: UUID, title: String, wantedPath: String, reason: Reason) {
        self.bookID = bookID
        self.title = title
        self.wantedPath = wantedPath
        self.reason = reason
    }
}

/// Where a book actually is, when that is not where the index said.
public struct BookLocation: Equatable, Sendable {
    public var bookID: UUID
    /// Where it is now.
    public var folder: String
    /// Where the index still thought it was — which is where it came *from*,
    /// and therefore what `Undo Organize` needs in order to put it back.
    public var previousFolder: String

    public init(bookID: UUID, folder: String, previousFolder: String) {
        self.bookID = bookID
        self.folder = folder
        self.previousFolder = previousFolder
    }
}

/// What an organise would do, before a single folder moves.
///
/// The same rule as `ImportPlan` and `TransferPlan`: what the preview shows is
/// the value the runner is handed, so the list somebody agreed to and the work
/// that happens cannot differ (ADR 0002, decision 6).
public struct OrganizePlan: Equatable, Sendable {
    public var moves: [OrganizeMove]
    /// Books whose folder is already exactly right. A number rather than a
    /// list: in a library that has been organised once, this is nearly all of
    /// them, and a list of five thousand unchanged rows says nothing.
    public var alreadyInPlace: Int
    public var blocked: [BlockedBook]
    /// Books found already sitting at their target folder although the index
    /// says otherwise — what an organise killed between two index writes
    /// leaves behind.
    ///
    /// They are counted as already in place and **not** reported as a book
    /// whose folder has gone missing, which is what they looked like before:
    /// the folder is the truth and the index is the cache, so a disagreement
    /// between them is the cache being wrong (ADR 0001). The caller writes the
    /// corrected path into the index.
    public var relocated: [BookLocation]
    /// Whether the volume folds case, as measured. Carried in the plan because
    /// the runner needs the same answer the planner used — asking twice could
    /// give two answers if the library moved between them.
    public var foldsCase: Bool

    public init(
        moves: [OrganizeMove] = [], alreadyInPlace: Int = 0, blocked: [BlockedBook] = [],
        relocated: [BookLocation] = [], foldsCase: Bool = true
    ) {
        self.moves = moves
        self.alreadyInPlace = alreadyInPlace
        self.blocked = blocked
        self.relocated = relocated
        self.foldsCase = foldsCase
    }

    public static let empty = OrganizePlan()

    public var isEmpty: Bool { moves.isEmpty }

    public func blocked(for reason: BlockedBook.Reason) -> [BlockedBook] {
        blocked.filter { $0.reason == reason }
    }

    /// "37 to move · 4 959 already right · 2 cannot be".
    public func summary() -> String {
        var parts: [String] = []
        parts.append("\(moves.count) to move")
        parts.append("\(alreadyInPlace) already right")
        if !blocked.isEmpty { parts.append("\(blocked.count) cannot be") }
        return parts.joined(separator: " · ")
    }
}

/// Works out where every book's folder ought to be.
///
/// Pure. Everything it needs to know about the disk is answered by closures the
/// caller supplies, which is what lets every rule in here — a collision, a case
/// that is not a case on this volume, a destination that is occupied — be
/// tested without a file system that has those properties to hand.
///
/// **It never guesses the folder from the folder.** The target is built from
/// the book's metadata by `BookFolderName`, the very function the importer uses
/// to name a new book's folder, so an organised library and a freshly imported
/// one are laid out by one rule and not by two that drift (ADR 0007's last
/// consequence, now cashed in).
public enum OrganizePlanner {

    public static func plan(
        entries: [LibraryEntry],
        foldsCase: Bool,
        /// Whether a folder exists at this path, relative to the library root.
        folderExists: (String) -> Bool = { _ in false },
        /// Whether it holds anything at all. Only asked when it exists.
        folderIsEmpty: (String) -> Bool = { _ in true },
        /// Whether the folder at this path is *this book's* — asked by reading
        /// the `metadata.opf` there and comparing the UUID. By UUID and never
        /// by title, for the reason `OrphanedFolders.claimable` gives: a title
        /// match would sooner or later pour one book's files into another
        /// book's folder.
        folderHoldsBook: (String, UUID) -> Bool = { _, _ in true }
    ) -> OrganizePlan {
        var moves: [OrganizeMove] = []
        var blocked: [BlockedBook] = []
        var relocated: [BookLocation] = []
        var alreadyInPlace = 0

        // Two books wanting one path is decided before anything else, because
        // it is a fact about the plan rather than about the disk — and because
        // a book that collides must not also be reported as "the destination
        // is occupied" by its own twin.
        let wanted = entries.map { (entry: $0, path: target(for: $0)) }
        var byKey: [String: [UUID]] = [:]
        for one in wanted {
            byKey[VolumeCase.key(one.path, folding: foldsCase), default: []].append(one.entry.id)
        }

        for (entry, path) in wanted {
            let colliding = byKey[VolumeCase.key(path, folding: foldsCase)] ?? []
            if colliding.count > 1 {
                // Whether the two are a collision *everywhere* or only here
                // decides the sentence, so the two are counted apart.
                let exact = wanted.count { $0.path == path }
                blocked.append(
                    .init(
                        bookID: entry.id, title: entry.book.title, wantedPath: path,
                        reason: exact > 1 ? .collision : .caseOnlyCollision))
                continue
            }
            if let tooLong = overLongComponent(in: path) {
                blocked.append(
                    .init(
                        bookID: entry.id, title: entry.book.title, wantedPath: tooLong,
                        reason: .nameTooLong))
                continue
            }
            if VolumeCase.same(entry.folder, path, folding: foldsCase), entry.folder == path {
                alreadyInPlace += 1
                continue
            }
            guard folderExists(entry.folder) else {
                // Not where the index says. Before calling that a missing
                // book, ask whether it is where it *ought* to be: an organise
                // killed between two index writes leaves exactly that, and it
                // is a stale cache rather than a lost book.
                if folderExists(path), folderHoldsBook(path, entry.id) {
                    relocated.append(
                        .init(bookID: entry.id, folder: path, previousFolder: entry.folder))
                    alreadyInPlace += 1
                } else {
                    blocked.append(
                        .init(
                            bookID: entry.id, title: entry.book.title, wantedPath: path,
                            reason: .sourceMissing))
                }
                continue
            }
            // The destination being the book's own folder under another
            // spelling of the same name is not an obstacle — it is the whole
            // of a case-only move.
            let caseOnly = VolumeCase.isCaseOnly(from: entry.folder, to: path, folding: foldsCase)
            if !caseOnly, folderExists(path), !folderIsEmpty(path) {
                blocked.append(
                    .init(
                        bookID: entry.id, title: entry.book.title, wantedPath: path,
                        reason: .destinationIsNotEmpty))
                continue
            }
            moves.append(
                .init(
                    bookID: entry.id, title: entry.book.title, author: entry.book.primaryAuthor,
                    from: entry.folder, to: path, isCaseOnly: caseOnly))
        }

        return OrganizePlan(
            moves: moves.sorted { $0.to < $1.to }, alreadyInPlace: alreadyInPlace,
            blocked: blocked.sorted { $0.title < $1.title }, relocated: relocated,
            foldsCase: foldsCase)
    }

    /// Where this book belongs — the importer's own answer, asked again.
    public static func target(for entry: LibraryEntry) -> String {
        BookFolderName.relativePath(for: entry.book, number: entry.number)
    }

    /// The first component that is over the byte limit, or `nil`.
    static func overLongComponent(in path: String) -> String? {
        path.split(separator: "/").map(String.init)
            .first { $0.utf8.count > BookFolderName.maxComponentBytes }
    }
}
