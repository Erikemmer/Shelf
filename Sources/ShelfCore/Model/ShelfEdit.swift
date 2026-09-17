import Foundation

/// The rules for changing a shelf tree: adding, renaming, moving, removing —
/// and turning a shelf into the path a book stores and back.
///
/// In the core for the same reason `BookField` is: every one of these is a rule
/// that can be wrong and none of them is about SwiftUI. A sidebar that decided
/// for itself whether two sisters may share a name, or whether a shelf may be
/// dragged into its own child, would put those decisions where no test can
/// reach them — and the same decisions have to hold for a drag, a menu, a
/// rebuild and the import of somebody else's `library.json`.
public enum ShelfEdit {
    /// Why a change to the tree was refused, in words a person can act on.
    public enum Rejection: Error, Equatable, Sendable {
        case nameMustNotBeEmpty
        case nameMustNotContainSeparator
        case nameAlreadyUsed(String, under: String?)
        case wouldMakeALoop

        public var message: String {
            switch self {
            case .nameMustNotBeEmpty:
                return "A shelf needs a name."
            case .nameMustNotContainSeparator:
                return "A shelf's name cannot contain “\(ShelfTree.pathSeparator)” — that is what "
                    + "separates a shelf from the one it stands in."
            case .nameAlreadyUsed(let name, let parent):
                if let parent {
                    return "“\(parent)” already holds a shelf called “\(name)”."
                }
                return "There is already a shelf called “\(name)”."
            case .wouldMakeALoop:
                return "A shelf cannot be put inside itself or inside one of its own shelves."
            }
        }
    }

    /// Whether a name may be used for a shelf under `parent`.
    ///
    /// `ignoring` is the shelf being renamed: a shelf keeping its own name is
    /// not a clash with itself.
    public static func check(
        name: String, under parent: UUID?, in tree: ShelfTree, ignoring: UUID? = nil
    ) -> Rejection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .nameMustNotBeEmpty }
        // A name with a separator in it would make `Fiction/Sci-Fi` ambiguous:
        // one shelf called "Fiction/Sci-Fi" or two nested ones, and the OPF
        // cannot say which. Refused with a sentence rather than escaped with a
        // rule nobody can see in the file.
        guard !trimmed.contains(ShelfTree.pathSeparator) else { return .nameMustNotContainSeparator }
        let clash = tree.children(of: parent).first {
            $0.id != ignoring && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard clash == nil else {
            return .nameAlreadyUsed(trimmed, under: parent.map { tree.path(of: $0) })
        }
        return nil
    }

    /// Adds a shelf as the last child of `parent`.
    public static func add(
        name: String, under parent: UUID? = nil, to tree: ShelfTree, id: UUID = UUID()
    ) -> Result<(tree: ShelfTree, id: UUID), Rejection> {
        if let rejection = check(name: name, under: parent, in: tree) { return .failure(rejection) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let position = (tree.children(of: parent).map(\.position).max() ?? -1) + 1
        var shelves = tree.shelves
        shelves.append(Shelf(id: id, name: trimmed, parentID: parent, position: position))
        return .success((ShelfTree(shelves), id))
    }

    public static func rename(_ id: UUID, to name: String, in tree: ShelfTree) -> Result<ShelfTree, Rejection> {
        guard let shelf = tree.shelf(id) else { return .success(tree) }
        if let rejection = check(name: name, under: shelf.parentID, in: tree, ignoring: id) {
            return .failure(rejection)
        }
        var shelves = tree.shelves
        guard let position = shelves.firstIndex(where: { $0.id == id }) else { return .success(tree) }
        shelves[position].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(ShelfTree(shelves))
    }

    /// Moves a shelf under a new parent, at the end of its new siblings.
    public static func move(
        _ id: UUID, under parent: UUID?, in tree: ShelfTree
    ) -> Result<ShelfTree, Rejection> {
        guard let shelf = tree.shelf(id) else { return .success(tree) }
        guard tree.canMove(id, under: parent) else { return .failure(.wouldMakeALoop) }
        guard shelf.parentID != parent else { return .success(tree) }
        if let rejection = check(name: shelf.name, under: parent, in: tree, ignoring: id) {
            return .failure(rejection)
        }
        var shelves = tree.shelves
        guard let position = shelves.firstIndex(where: { $0.id == id }) else { return .success(tree) }
        shelves[position].parentID = parent
        shelves[position].position = (tree.children(of: parent).map(\.position).max() ?? -1) + 1
        return .success(ShelfTree(shelves))
    }

    /// Removes a shelf and everything inside it.
    ///
    /// The tree only. **No book is touched here** – which books lose a shelf is
    /// `pathsAfterRemoving` below, and the two are separate because removing a
    /// shelf from the tree and rewriting a hundred `metadata.opf` files are
    /// different kinds of act and only one of them can half-fail.
    public static func remove(_ id: UUID, from tree: ShelfTree) -> ShelfTree {
        let doomed = Set(tree.subtree(of: id))
        return ShelfTree(tree.shelves.filter { !doomed.contains($0.id) })
    }

    /// What a book's shelf paths become once `id` and its children are gone.
    ///
    /// Prefix-matched on whole segments, so removing `Fiction` takes
    /// `Fiction/Sci-Fi` with it and leaves `Fictional Places` alone.
    public static func pathsAfterRemoving(
        _ id: UUID, from paths: [String], in tree: ShelfTree
    ) -> [String] {
        let doomed = Set(tree.subtree(of: id).compactMap { tree.storedPath(of: $0) })
        return paths.filter { path in
            !doomed.contains(where: { path == $0 || path.hasPrefix($0 + ShelfTree.pathSeparator) })
        }
    }

    /// What a book's shelf paths become once `id` has been renamed or moved and
    /// the tree already says so.
    ///
    /// Takes the tree *before* and *after*, because a stored path is only a
    /// name: nothing in `Fiction/Sci-Fi` says which shelf it is, so the only
    /// way to follow a rename is to know what the path used to be.
    public static func pathsAfterMoving(
        _ id: UUID, from paths: [String], before: ShelfTree, after: ShelfTree
    ) -> [String] {
        var replacements: [(old: String, new: String)] = []
        for moved in before.subtree(of: id) {
            guard let old = before.storedPath(of: moved), let new = after.storedPath(of: moved),
                old != new
            else { continue }
            replacements.append((old, new))
        }
        guard !replacements.isEmpty else { return paths }
        // Longest first: renaming `Fiction` also changes `Fiction/Sci-Fi`, and
        // rewriting the short one first would leave the long one half-renamed.
        replacements.sort { $0.old.count > $1.old.count }
        return
            paths
            .map { path in
                for (old, new) in replacements {
                    if path == old { return new }
                    if path.hasPrefix(old + ShelfTree.pathSeparator) {
                        return new + path.dropFirst(old.count)
                    }
                }
                return path
            }
            .sorted()
    }
}

extension ShelfTree {
    /// What separates a shelf from the one it stands in, inside a stored path.
    ///
    /// `/` because that is what a path looks like to everybody, and because the
    /// value is read by eye in `metadata.opf`. A shelf may not have one in its
    /// name (`ShelfEdit.check`), which is what keeps `Fiction/Sci-Fi` a
    /// sentence with one meaning.
    public static let pathSeparator = "/"

    /// `Fiction/Sci-Fi` – what a book stores, and what a rebuild reads back.
    ///
    /// `nil` for a shelf this tree does not hold, and for one whose ancestry is
    /// broken: a path that silently drops a level would file books on the wrong
    /// shelf, which is worse than filing them nowhere.
    public func storedPath(of id: UUID) -> String? {
        var names: [String] = []
        var seen: Set<UUID> = []
        var current = shelf(id)
        while let shelf = current {
            // Only reachable from a corrupt file – `canMove` refuses to make
            // one – and it has to end rather than hang. Answering `nil` files
            // the book nowhere, which is what a path that cannot be written
            // down deserves.
            guard !seen.contains(shelf.id) else { return nil }
            seen.insert(shelf.id)
            names.insert(shelf.name, at: 0)
            guard let parentID = shelf.parentID else {
                return names.joined(separator: Self.pathSeparator)
            }
            guard let parent = self.shelf(parentID) else { return nil }
            current = parent
        }
        return nil
    }

    /// The shelf a stored path names, if this tree holds it.
    public func shelf(atPath path: String) -> Shelf? {
        let names = path.components(separatedBy: Self.pathSeparator)
        guard !names.isEmpty else { return nil }
        var parent: UUID?
        var found: Shelf?
        for name in names {
            guard
                let next = children(of: parent).first(where: {
                    $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
                })
            else { return nil }
            found = next
            parent = next.id
        }
        return found
    }

    /// Makes sure a stored path exists, creating whatever levels are missing,
    /// and answers the shelf at the end of it.
    ///
    /// This is what a rebuild needs. A book's OPF may name a shelf that
    /// `library.json` has lost — a restored backup, a file somebody edited, a
    /// library copied without its dot folder — and the choice is between
    /// inventing the shelf and dropping the book off it. Inventing it is right:
    /// the book said where it stands, and the folder is the truth.
    public mutating func ensure(path: String) -> UUID? {
        let names = path.components(separatedBy: Self.pathSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        var parent: UUID?
        for name in names {
            if let existing = children(of: parent).first(where: {
                $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                parent = existing.id
                continue
            }
            let position = (children(of: parent).map(\.position).max() ?? -1) + 1
            let shelf = Shelf(name: name, parentID: parent, position: position)
            shelves.append(shelf)
            parent = shelf.id
        }
        return parent
    }

    /// Every shelf, deepest-first as the sidebar draws it: a shelf, then what
    /// is inside it, then the next sister.
    public func inDrawnOrder(under parent: UUID? = nil, depth: Int = 0) -> [(shelf: Shelf, depth: Int)] {
        children(of: parent).flatMap { shelf in
            [(shelf, depth)] + inDrawnOrder(under: shelf.id, depth: depth + 1)
        }
    }
}
