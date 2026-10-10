import XCTest

@testable import ShelfCore

final class RecentLibraryTests: XCTestCase {
    private func row(_ path: String, _ mark: UInt8, _ count: Int, _ stamp: Double) -> RecentLibrary {
        RecentLibrary(
            path: path, name: path.uppercased(), bookmark: Data([mark]), bookCount: count,
            lastOpened: Date(timeIntervalSince1970: stamp))
    }

    private func sample() -> [RecentLibrary] {
        [row("/a", 1, 0, 100), row("/b", 2, 5, 50)]
    }

    func testChangesOnlyTheCountKeepingOrderBookmarkAndDate() {
        var list = sample()
        let before = list
        XCTAssertTrue(RecentLibrary.updateBookCount(in: &list, path: "/b", to: 40))
        XCTAssertEqual(list.map(\.path), ["/a", "/b"])
        XCTAssertEqual(list[1].bookCount, 40)
        XCTAssertEqual(list[1].bookmark, before[1].bookmark)
        XCTAssertEqual(list[1].lastOpened, before[1].lastOpened)
        XCTAssertEqual(list[0], before[0])
    }

    func testUnknownPathIsIgnored() {
        var list = sample()
        XCTAssertFalse(RecentLibrary.updateBookCount(in: &list, path: "/zzz", to: 9))
        XCTAssertEqual(list, sample())
    }

    func testUnchangedCountReportsNoChange() {
        var list = sample()
        XCTAssertFalse(RecentLibrary.updateBookCount(in: &list, path: "/b", to: 5))
        XCTAssertEqual(list, sample())
    }

    func testRemovesOnlyTheNamedRowKeepingTheOrderOfTheRest() {
        var list = sample() + [row("/c", 3, 7, 10)]
        XCTAssertTrue(RecentLibrary.remove(from: &list, path: "/b"))
        XCTAssertEqual(list.map(\.path), ["/a", "/c"])
        XCTAssertEqual(list[0], sample()[0])
    }

    func testRemovingAnUnknownPathChangesNothing() {
        var list = sample()
        XCTAssertFalse(RecentLibrary.remove(from: &list, path: "/zzz"))
        XCTAssertEqual(list, sample())
    }

    func testRemovingTheLastRowLeavesAnEmptyList() {
        var list = [row("/a", 1, 0, 100)]
        XCTAssertTrue(RecentLibrary.remove(from: &list, path: "/a"))
        XCTAssertTrue(list.isEmpty)
    }
}
