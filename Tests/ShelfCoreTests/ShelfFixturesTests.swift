import Foundation
import Testing

@testable import ShelfCore
@testable import ShelfFixtures

/// `ShelfFixtures` exists so that the shipped core holds no test tooling.
///
/// `ZipWriter`, `MinimalPNG` and the five `Synthetic…` builders were 1 343
/// lines of `ShelfCore`'s public surface that production never called, and
/// every one of them was code the Linux job had to keep compiling into what the
/// app links. They moved in Sprint 7; these are the tests that keep them out.
@Suite("Test material lives in its own target")
struct ShelfFixturesTests {
    static let repoRoot = LocalisationTests.repoRoot

    /// The names that must not appear in the window's sources. Not a check on
    /// the *import* — `App/Shelf` cannot import `ShelfFixtures`, because
    /// `project.yml` does not give it to the app — but on the names, so that a
    /// copy of one of them pasted into the app fails here rather than growing
    /// into a second implementation.
    static let fixtureNames = [
        "ZipWriter", "MinimalPNG", "SyntheticEPUB", "SyntheticPDF", "SyntheticComic",
        "SyntheticMobi", "SyntheticCalibreLibrary", "SyntheticKobo", "ShelfFixtures",
    ]

    /// Every Swift file under a folder of the repository.
    static func sources(under relativePath: String) throws -> [URL] {
        let root = repoRoot.appending(path: relativePath)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static func namesFound(under relativePath: String, ignoring ignored: Set<String> = []) throws -> [String] {
        var found: [String] = []
        for url in try sources(under: relativePath) {
            let text = try String(contentsOf: url, encoding: .utf8)
            for name in fixtureNames where !ignored.contains(name) && text.contains(name) {
                found.append("\(url.lastPathComponent): \(name)")
            }
        }
        return found
    }

    @Test("the app names no test-material builder")
    func theAppIsFreeOfThem() throws {
        let found = try Self.namesFound(under: "App/Shelf")
        #expect(found.isEmpty, "test material named in the app: \(found.joined(separator: " | "))")
    }

    /// And the other direction: `ShelfCore` itself no longer holds them either,
    /// which is what the Linux job stops compiling into the shipped core.
    @Test("the core names no test-material builder")
    func theCoreIsFreeOfThem() throws {
        let found = try Self.namesFound(under: "Sources/ShelfCore", ignoring: ["ShelfFixtures"])
        #expect(found.isEmpty, "test material still in the core: \(found.joined(separator: " | "))")
    }

    /// The move is only worth anything if the material still works. One of each,
    /// read back by the reader it exists for.
    @Test("an EPUB the fixtures write is one the core reads")
    func theEPUBStillWorks() throws {
        let folder = try TemporaryFolder()
        var book = Book(title: "A Fixture", authors: ["Someone"])
        book.tags = ["synthetic"]
        let url = folder.url.appendingPathComponent("book.epub")
        try SyntheticEPUB(book: book, cover: MinimalPNG.cover(width: 4, height: 6, seed: 1))
            .data()
            .write(to: url)

        let read = try EPUBMetadata.read(url: url)
        #expect(read.book.title == "A Fixture")
        #expect(read.book.authors == ["Someone"])
        #expect(read.cover != nil)
    }
}
