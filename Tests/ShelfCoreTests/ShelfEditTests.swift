import Foundation
import Testing

@testable import ShelfCore

/// The rules for changing a shelf tree, and for turning a shelf into the path a
/// book stores.
///
/// They are the reason a shelf can survive a lost index: the path in each
/// book's `metadata.opf` is the only record of where the book stands, so
/// writing one, reading it back and following it through a rename all have to
/// mean the same thing. Each of those is a rule that can be wrong.
@Suite("Shelves")
struct ShelfEditTests {

    /// Fiction ▸ Sci-Fi, Fiction ▸ Crime, Non-Fiction — the shape every test
    /// below starts from.
    private func tree() -> (tree: ShelfTree, fiction: UUID, scifi: UUID, crime: UUID, nonFiction: UUID) {
        var tree = ShelfTree()
        guard case .success(let one) = ShelfEdit.add(name: "Fiction", to: tree) else {
            fatalError("Fiction was refused")
        }
        tree = one.tree
        guard case .success(let two) = ShelfEdit.add(name: "Sci-Fi", under: one.id, to: tree) else {
            fatalError("Sci-Fi was refused")
        }
        tree = two.tree
        guard case .success(let three) = ShelfEdit.add(name: "Crime", under: one.id, to: tree) else {
            fatalError("Crime was refused")
        }
        tree = three.tree
        guard case .success(let four) = ShelfEdit.add(name: "Non-Fiction", to: tree) else {
            fatalError("Non-Fiction was refused")
        }
        return (four.tree, one.id, two.id, three.id, four.id)
    }

    // MARK: Paths

    @Test("a shelf's stored path names every level down to it")
    func storedPath() {
        let (tree, fiction, scifi, _, _) = self.tree()
        #expect(tree.storedPath(of: fiction) == "Fiction")
        #expect(tree.storedPath(of: scifi) == "Fiction/Sci-Fi")
    }

    @Test("a stored path finds its shelf again, whatever case it is written in")
    func pathRoundTrip() {
        let (tree, _, scifi, _, _) = self.tree()
        #expect(tree.shelf(atPath: "Fiction/Sci-Fi")?.id == scifi)
        // An OPF somebody edited by hand, or a library copied between a
        // case-sensitive and a case-insensitive disk.
        #expect(tree.shelf(atPath: "fiction/sci-fi")?.id == scifi)
        #expect(tree.shelf(atPath: "Fiction/Fantasy") == nil)
    }

    /// The rebuild's case: a book's OPF names a shelf that `library.json` has
    /// lost. Inventing the shelf is right — the book said where it stands, and
    /// the folder is the truth (ADR 0001).
    @Test("a path the tree has lost is created rather than dropped")
    func ensureCreatesMissingLevels() {
        var tree = ShelfTree()
        let id = tree.ensure(path: "Fiction/Sci-Fi/Space Opera")
        #expect(id != nil)
        #expect(tree.shelves.count == 3)
        #expect(tree.storedPath(of: id ?? UUID()) == "Fiction/Sci-Fi/Space Opera")
        // Asking twice creates nothing the second time.
        _ = tree.ensure(path: "Fiction/Sci-Fi/Space Opera")
        #expect(tree.shelves.count == 3)
    }

    // MARK: What is refused

    @Test("a shelf needs a name, and it cannot hold the separator")
    func namesAreChecked() {
        let (tree, fiction, _, _, _) = self.tree()
        #expect(ShelfEdit.check(name: "  ", under: nil, in: tree) == .nameMustNotBeEmpty)
        // Otherwise `Fiction/Sci-Fi` in an OPF could mean one shelf or two, and
        // nothing in the file says which.
        #expect(
            ShelfEdit.check(name: "Crime/Mystery", under: nil, in: tree) == .nameMustNotContainSeparator)
        #expect(ShelfEdit.check(name: "Sci-Fi", under: fiction, in: tree) != nil)
        // The same name under a *different* parent is fine: that is what a
        // hierarchy is for.
        #expect(ShelfEdit.check(name: "Sci-Fi", under: nil, in: tree) == nil)
    }

    @Test("a shelf cannot be put inside itself or inside its own shelves")
    func loopsAreRefused() {
        let (tree, fiction, scifi, _, _) = self.tree()
        #expect(ShelfEdit.move(fiction, under: scifi, in: tree) == .failure(.wouldMakeALoop))
        #expect(ShelfEdit.move(fiction, under: fiction, in: tree) == .failure(.wouldMakeALoop))
    }

    @Test("a shelf renamed onto a sister's name is refused, and keeps its own")
    func renameClash() {
        let (tree, _, scifi, crime, _) = self.tree()
        #expect(ShelfEdit.rename(scifi, to: "Crime", in: tree) != .success(tree))
        guard case .failure(let why) = ShelfEdit.rename(scifi, to: "Crime", in: tree) else {
            Issue.record("renaming Sci-Fi to Crime was allowed")
            return
        }
        #expect(why == .nameAlreadyUsed("Crime", under: "Fiction"))
        _ = crime
        // Renaming a shelf to what it is already called is not a clash with
        // itself.
        #expect(ShelfEdit.rename(scifi, to: "Sci-Fi", in: tree) == .success(tree))
    }

    // MARK: What happens to the books

    /// The one thing a rename must not do is leave books pointing at a shelf
    /// that no longer exists. A stored path is only a name, so following a
    /// rename needs both trees.
    @Test("renaming a shelf carries the books on it and on its children")
    func renameFollowsThrough() {
        let (before, fiction, _, _, _) = self.tree()
        guard case .success(let after) = ShelfEdit.rename(fiction, to: "Novels", in: before) else {
            Issue.record("the rename was refused")
            return
        }
        let paths = ["Fiction", "Fiction/Sci-Fi", "Non-Fiction", "Fictional Places"]
        let moved = ShelfEdit.pathsAfterMoving(fiction, from: paths, before: before, after: after)
        #expect(moved == ["Fictional Places", "Non-Fiction", "Novels", "Novels/Sci-Fi"])
    }

    @Test("moving a shelf under another carries its whole subtree")
    func moveFollowsThrough() {
        let (before, fiction, _, _, nonFiction) = self.tree()
        guard case .success(let after) = ShelfEdit.move(fiction, under: nonFiction, in: before) else {
            Issue.record("the move was refused")
            return
        }
        let moved = ShelfEdit.pathsAfterMoving(
            fiction, from: ["Fiction/Sci-Fi", "Fiction"], before: before, after: after)
        #expect(moved == ["Non-Fiction/Fiction", "Non-Fiction/Fiction/Sci-Fi"])
    }

    /// Whole segments, or removing `Fiction` would also take `Fictional Places`
    /// — a book quietly falling off a shelf nobody touched.
    @Test("removing a shelf takes its children and leaves lookalikes alone")
    func removeTakesTheSubtree() {
        let (tree, fiction, _, _, _) = self.tree()
        let paths = ["Fiction", "Fiction/Sci-Fi", "Fictional Places", "Non-Fiction"]
        #expect(
            ShelfEdit.pathsAfterRemoving(fiction, from: paths, in: tree)
                == ["Fictional Places", "Non-Fiction"])

        let smaller = ShelfEdit.remove(fiction, from: tree)
        #expect(smaller.shelves.count == 1)
        #expect(smaller.shelf(atPath: "Fiction/Sci-Fi") == nil)
    }

    // MARK: What the sidebar asks

    @Test("the sidebar's order is a shelf, then what is inside it, then the next")
    func drawnOrder() {
        let (tree, _, _, _, _) = self.tree()
        let drawn = tree.inDrawnOrder().map { "\($0.depth):\($0.shelf.name)" }
        #expect(drawn == ["0:Fiction", "1:Sci-Fi", "1:Crime", "0:Non-Fiction"])
    }

    /// Selecting a shelf shows what is on it *and* what is on the shelves
    /// inside it — a shelf whose books all live in its children would otherwise
    /// read as empty, which is not what a bookcase does.
    @Test("a shelf covers itself and everything inside it, but not a lookalike")
    func standingOnAShelf() {
        let book = Book(title: "x", shelves: ["Fiction/Sci-Fi"])
        #expect(LibraryFilter.stands(book, on: "Fiction"))
        #expect(LibraryFilter.stands(book, on: "Fiction/Sci-Fi"))
        #expect(!LibraryFilter.stands(book, on: "Fictional Places"))
        #expect(!LibraryFilter.stands(book, on: "Fiction/Sci"))
    }
}
