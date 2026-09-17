import Foundation

/// A shelf: a named, hand-filled group of books.
///
/// Hierarchical (CONCEPT §15, decision 3): a shelf may sit inside another, so
/// the sidebar can show "Fiction ▸ Science Fiction" the way a bookcase works.
/// The hierarchy is a parent pointer rather than nested values, because the
/// index is relational and because moving a shelf must not rewrite its children.
public struct Shelf: Identifiable, Equatable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    /// nil for a top-level shelf.
    public var parentID: UUID?
    /// Where it sits among its siblings. Hand-sorted, because a bookcase is.
    public var position: Int

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, position: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.position = position
    }
}

/// A whole shelf tree, and the questions the sidebar asks of it.
///
/// A value type over a flat list: the tree is derived, never stored twice. That
/// is what keeps "move this shelf into that one" a single field change, and it
/// is why the cycle check below can exist at all.
public struct ShelfTree: Equatable, Sendable {
    /// Settable inside the package so `ShelfEdit` can build a tree up; the
    /// rules for *what* may be added live there, next to each other, rather
    /// than as a set of mutating methods spread over this type.
    public internal(set) var shelves: [Shelf]

    public init(_ shelves: [Shelf] = []) {
        self.shelves = shelves
    }

    public var isEmpty: Bool { shelves.isEmpty }

    public func shelf(_ id: UUID) -> Shelf? {
        shelves.first { $0.id == id }
    }

    /// The children of a shelf, in their hand-given order; `nil` asks for the
    /// top level.
    public func children(of parent: UUID?) -> [Shelf] {
        shelves
            .filter { $0.parentID == parent }
            .sorted { $0.position == $1.position ? $0.name < $1.name : $0.position < $1.position }
    }

    /// "Fiction ▸ Science Fiction ▸ Space Opera" – what the inspector shows and
    /// what a report names, so a shelf is never ambiguous.
    /// A shelf that has itself somewhere above it – only possible from a
    /// corrupt file, since `canMove` refuses to create one – must not hang the
    /// app while it is being reported. Both walks below therefore remember
    /// where they have been rather than counting steps: a visited set gives the
    /// right answer for a healthy tree *and* terminates on a broken one, where
    /// a step limit only does the second.
    public func path(of id: UUID, separator: String = " ▸ ") -> String {
        var names: [String] = []
        var seen: Set<UUID> = []
        var current = shelf(id)
        while let shelf = current, !seen.contains(shelf.id) {
            seen.insert(shelf.id)
            names.insert(shelf.name, at: 0)
            current = shelf.parentID.flatMap { self.shelf($0) }
        }
        return names.joined(separator: separator)
    }

    /// Every shelf under `id`, itself included – what "show this shelf" means
    /// when it has children, and what a delete would take with it.
    public func subtree(of id: UUID) -> [UUID] {
        var found: [UUID] = [id]
        var seen: Set<UUID> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in children(of: next).map(\.id) where !seen.contains(child) {
                seen.insert(child)
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    /// Whether a shelf may become a child of another.
    ///
    /// A shelf cannot go inside itself or inside one of its own children – that
    /// would make a loop the sidebar could not draw and the subtree walk could
    /// not end. Checked here so the answer is the same for a drag, a menu and
    /// an import.
    public func canMove(_ id: UUID, under parent: UUID?) -> Bool {
        guard let parent else { return true }
        guard parent != id else { return false }
        return !subtree(of: id).contains(parent)
    }
}
