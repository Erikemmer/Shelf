import Foundation
import Testing

@testable import ShelfCore

@Suite("Merging metadata and choosing the better format file")
struct BookMergePlannerTests {

    // MARK: BookMetadataMerge

    @Test("an empty field is filled when every absorbed book agrees")
    func fillsAgreeingField() {
        let survivor = Book(title: "Schattenpfad", authors: ["A"])
        let absorbedID = UUID()
        let absorbed = Book(title: "Schattenpfad", authors: ["A"], publisher: "Rowohlt")
        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(absorbedID, absorbed)])

        #expect(result.book.publisher == "Rowohlt")
        #expect(result.fills.count == 1)
        #expect(result.fills[0].field == .publisher)
        #expect(result.fills[0].fromBookID == absorbedID)
        #expect(result.conflicts.isEmpty)
    }

    @Test("a non-empty field keeps the surviving value and counts the disagreement")
    func keepsSurvivorOnConflict() {
        let survivor = Book(title: "Schattenpfad", authors: ["A"], publisher: "Rowohlt")
        let absorbed = Book(title: "Schattenpfad", authors: ["A"], publisher: "Fischer")
        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(UUID(), absorbed)])

        #expect(result.book.publisher == "Rowohlt")
        #expect(result.fills.isEmpty)
        #expect(result.conflicts.count == 1)
        #expect(result.conflicts[0].field == .publisher)
        #expect(result.conflicts[0].survivingValue == "Rowohlt")
        #expect(result.conflicts[0].otherValues.map(\.value) == ["Fischer"])
    }

    @Test("an empty field stays empty when the absorbed books disagree among themselves")
    func staysEmptyOnAbsorbedDisagreement() {
        let survivor = Book(title: "Schattenpfad", authors: ["A"])
        let one = Book(title: "Schattenpfad", authors: ["A"], publisher: "Rowohlt")
        let two = Book(title: "Schattenpfad", authors: ["A"], publisher: "Fischer")
        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(UUID(), one), (UUID(), two)])

        #expect(result.book.publisher == nil)
        #expect(result.fills.isEmpty)
        #expect(result.conflicts.count == 1)
        #expect(result.conflicts[0].survivingValue == "")
    }

    @Test("tags and shelves are unioned, never overwritten or lost")
    func unionsTagsAndShelves() {
        var survivor = Book(title: "Schattenpfad", authors: ["A"])
        survivor.tags = ["fiction"]
        survivor.shelves = ["Read"]
        var absorbed = Book(title: "Schattenpfad", authors: ["A"])
        absorbed.tags = ["thriller", "fiction"]
        absorbed.shelves = ["To Read"]

        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(UUID(), absorbed)])
        #expect(result.book.tags == ["fiction", "thriller"])
        #expect(result.book.shelves == ["Read", "To Read"])
    }

    @Test("an empty ISBN is filled from an absorbed book's identifier")
    func fillsISBN() {
        let survivor = Book(title: "Schattenpfad", authors: ["A"])
        let absorbed = Book(title: "Schattenpfad", authors: ["A"], identifiers: ["isbn": "9783404178926"])
        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(UUID(), absorbed)])
        #expect(result.book.isbn == "9783404178926")
    }

    /// Found live against the real library: a MOBI's EXTH record says `eng`,
    /// an EPUB's `dc:language` says `en` — the same language, not a
    /// disagreement, and the same normalisation `MergeCandidates` already
    /// uses for grouping.
    @Test("a language code and its ISO equivalent are not a conflict")
    func normalisesLanguageBeforeComparing() {
        let survivor = Book(title: "Schattenpfad", authors: ["A"], language: "eng")
        let absorbed = Book(title: "Schattenpfad", authors: ["A"], language: "en")
        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(UUID(), absorbed)])
        // The survivor's own value is never overwritten just because it was
        // compared through the normalised form — only the false conflict is
        // what the normalisation exists to prevent.
        #expect(result.book.language == "eng")
        #expect(result.conflicts.isEmpty)
        #expect(result.fills.isEmpty)
    }

    @Test("an empty language is filled with the canonical two-letter code")
    func fillsLanguageNormalised() {
        let survivor = Book(title: "Schattenpfad", authors: ["A"])
        let absorbed = Book(title: "Schattenpfad", authors: ["A"], language: "deu")
        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(UUID(), absorbed)])
        #expect(result.book.language == "de")
        #expect(result.fills.count == 1)
    }

    @Test("a description already present is never overwritten by a merge")
    func neverOverwritesADescription() {
        let survivor = Book(title: "Schattenpfad", authors: ["A"], description: "The survivor's own words.")
        let absorbed = Book(title: "Schattenpfad", authors: ["A"], description: "Something else entirely.")
        let result = BookMetadataMerge.merge(surviving: survivor, absorbed: [(UUID(), absorbed)])
        #expect(result.book.description == "The survivor's own words.")
    }

    // MARK: FormatPreference

    private func format(drm: DRMKind? = nil, byteSize: Int64 = 100) -> BookFormat {
        BookFormat(bookID: UUID(), format: .epub, fileName: "a.epub", byteSize: byteSize, sha256: "d", drm: drm)
    }

    private func quality(opens: Bool = true, cover: Bool = true, fields: Int = 5) -> FormatQuality {
        FormatQuality(opensSuccessfully: opens, hasCover: cover, filledFieldCount: fields)
    }

    @Test("no DRM beats DRM, before anything else is even asked")
    func drmLosesToClean() {
        let clean = format(drm: nil)
        let protected = format(drm: .adobeADEPT)
        #expect(FormatPreference.preferred(clean, quality(), over: protected, quality()))
        #expect(!FormatPreference.preferred(protected, quality(), over: clean, quality()))
    }

    @Test("opening successfully beats not opening, once DRM is equal")
    func opensBeatsDoesNotOpen() {
        let opens = format()
        let doesNotOpen = format()
        #expect(FormatPreference.preferred(opens, quality(opens: true), over: doesNotOpen, quality(opens: false)))
    }

    @Test("having a cover beats not having one, once DRM and opening are equal")
    func coverBeatsNoCover() {
        let withCover = format()
        let withoutCover = format()
        #expect(
            FormatPreference.preferred(
                withCover, quality(cover: true), over: withoutCover, quality(cover: false)))
    }

    @Test("more filled fields beats fewer, once everything above is equal")
    func moreFieldsBeatsFewer() {
        let fuller = format()
        let sparser = format()
        #expect(FormatPreference.preferred(fuller, quality(fields: 8), over: sparser, quality(fields: 2)))
    }

    @Test("size is the last resort, when nothing else disagrees")
    func sizeIsLastResort() {
        let bigger = format(byteSize: 900_000)
        let smaller = format(byteSize: 100)
        #expect(FormatPreference.preferred(bigger, quality(), over: smaller, quality()))
    }

    // MARK: BookMergePlanner — whole-group planning

    private func entry(
        title: String, author: String, number: Int, folder: String? = nil, formats: [BookFormat] = []
    ) -> LibraryEntry {
        let book = Book(title: title, authors: [author])
        return LibraryEntry(
            book: book, number: number, folder: folder ?? "\(author)/\(title) (\(number))", formats: formats)
    }

    private func libraryAt(_ folder: TemporaryFolder) throws -> Library {
        try Library.create(at: try folder.folder("Lib")).0
    }

    /// A quality probe that never has to read a real file: every format is
    /// "opens fine, no cover, five fields" unless a test overrides it by URL.
    private func plainQuality(overrides: [String: FormatQuality] = [:]) -> FormatQualityProbe {
        { url, _ in
            overrides[url.lastPathComponent]
                ?? FormatQuality(opensSuccessfully: true, hasCover: false, filledFieldCount: 5)
        }
    }

    @Test("a book missing a format simply gets it added, nothing discarded")
    func addsAMissingFormat() throws {
        let temp = try TemporaryFolder()
        let library = try libraryAt(temp)
        var survivor = entry(title: "Schattenpfad", author: "A", number: 1, folder: "A/Schattenpfad (1)")
        let bookID = survivor.book.id
        survivor.formats = [BookFormat(bookID: bookID, format: .epub, fileName: "a.epub", byteSize: 10, sha256: "e")]
        var absorbedEntry = entry(title: "Schattenpfad", author: "A", number: 2, folder: "A/Schattenpfad (2)")
        let absorbedID = absorbedEntry.book.id
        absorbedEntry.formats = [
            BookFormat(bookID: absorbedID, format: .mobi, fileName: "a.mobi", byteSize: 20, sha256: "m")
        ]

        let entries = [bookID: survivor, absorbedID: absorbedEntry]
        let group = MergeGroup(bookIDs: [bookID, absorbedID])
        let plan = BookMergePlanner.plan(
            groups: [group], entries: entries, library: library, quality: plainQuality(), hasCover: { _ in false })

        #expect(plan.groups.count == 1)
        let groupPlan = plan.groups[0]
        #expect(groupPlan.survivingID == bookID)
        #expect(groupPlan.absorbedIDs == [absorbedID])
        #expect(groupPlan.moves.count == 1)
        #expect(groupPlan.moves[0].format.fileName == "a.mobi")
        #expect(groupPlan.discards.isEmpty)
    }

    @Test("byte-identical files of the same format collapse to one, the rest discarded")
    func collapsesByteIdenticalDuplicates() throws {
        let temp = try TemporaryFolder()
        let library = try libraryAt(temp)
        var survivor = entry(title: "Schattenpfad", author: "A", number: 1, folder: "A/Schattenpfad (1)")
        let bookID = survivor.book.id
        survivor.formats = [BookFormat(bookID: bookID, format: .epub, fileName: "a.epub", byteSize: 10, sha256: "same")]
        var absorbedEntry = entry(title: "Schattenpfad", author: "A", number: 2, folder: "A/Schattenpfad (2)")
        let absorbedID = absorbedEntry.book.id
        absorbedEntry.formats = [
            BookFormat(bookID: absorbedID, format: .epub, fileName: "b.epub", byteSize: 10, sha256: "same")
        ]

        let entries = [bookID: survivor, absorbedID: absorbedEntry]
        let plan = BookMergePlanner.plan(
            groups: [MergeGroup(bookIDs: [bookID, absorbedID])], entries: entries, library: library,
            quality: plainQuality(), hasCover: { _ in false })

        let groupPlan = plan.groups[0]
        // Nothing moves in: the survivor's own copy is kept, the identical
        // absorbed one is discarded rather than added as a second file.
        #expect(groupPlan.moves.isEmpty)
        #expect(groupPlan.discards.count == 1)
        #expect(groupPlan.discards[0].reason == .byteIdenticalDuplicate)
        #expect(groupPlan.discards[0].format.fileName == "b.epub")
    }

    @Test("two different-content files of the same format are decided by FormatPreference, not by which book survives")
    func tieBreaksDifferentContentSameFormat() throws {
        let temp = try TemporaryFolder()
        let library = try libraryAt(temp)
        var survivor = entry(title: "Schattenpfad", author: "A", number: 1, folder: "A/Schattenpfad (1)")
        let bookID = survivor.book.id
        // The survivor's own EPUB is DRM-protected; the absorbed book's is clean.
        survivor.formats = [
            BookFormat(
                bookID: bookID, format: .epub, fileName: "survivor.epub", byteSize: 10, sha256: "s", drm: .adobeADEPT)
        ]
        var absorbedEntry = entry(title: "Schattenpfad", author: "A", number: 2, folder: "A/Schattenpfad (2)")
        let absorbedID = absorbedEntry.book.id
        absorbedEntry.formats = [
            BookFormat(bookID: absorbedID, format: .epub, fileName: "clean.epub", byteSize: 10, sha256: "c", drm: nil)
        ]

        let entries = [bookID: survivor, absorbedID: absorbedEntry]
        let plan = BookMergePlanner.plan(
            groups: [MergeGroup(bookIDs: [bookID, absorbedID])], entries: entries, library: library,
            quality: plainQuality(), hasCover: { _ in false })

        let groupPlan = plan.groups[0]
        // The clean copy wins even though it belongs to the *absorbed* book —
        // it has to move in, and the survivor's own protected copy is
        // discarded even though nothing else changes about which book survives.
        #expect(groupPlan.moves.count == 1)
        #expect(groupPlan.moves[0].format.fileName == "clean.epub")
        #expect(groupPlan.discards.count == 1)
        #expect(groupPlan.discards[0].format.fileName == "survivor.epub")
        #expect(groupPlan.discards[0].reason == .losingTiebreak)
    }

    @Test("the survivor's own cover is never displaced by an absorbed book's")
    func neverDisplacesSurvivorsCover() throws {
        let temp = try TemporaryFolder()
        let library = try libraryAt(temp)
        let survivor = entry(title: "Schattenpfad", author: "A", number: 1, folder: "A/Schattenpfad (1)")
        let bookID = survivor.book.id
        let absorbedEntry = entry(title: "Schattenpfad", author: "A", number: 2, folder: "A/Schattenpfad (2)")
        let absorbedID = absorbedEntry.book.id

        let entries = [bookID: survivor, absorbedID: absorbedEntry]
        let plan = BookMergePlanner.plan(
            groups: [MergeGroup(bookIDs: [bookID, absorbedID])], entries: entries, library: library,
            quality: plainQuality(),
            hasCover: { url in url.path.contains("Schattenpfad (1)") || url.path.contains("Schattenpfad (2)") })

        // Both "have" a cover in this fake probe, but the survivor's own wins
        // simply because it exists — no comparison ever happens.
        #expect(plan.groups[0].coverFromBookID == nil)
    }

    @Test("an absorbed book's cover fills in when the survivor has none")
    func fillsCoverFromAbsorbedBook() throws {
        let temp = try TemporaryFolder()
        let library = try libraryAt(temp)
        let survivor = entry(title: "Schattenpfad", author: "A", number: 1, folder: "A/Schattenpfad (1)")
        let bookID = survivor.book.id
        let absorbedEntry = entry(title: "Schattenpfad", author: "A", number: 2, folder: "A/Schattenpfad (2)")
        let absorbedID = absorbedEntry.book.id

        let entries = [bookID: survivor, absorbedID: absorbedEntry]
        let plan = BookMergePlanner.plan(
            groups: [MergeGroup(bookIDs: [bookID, absorbedID])], entries: entries, library: library,
            quality: plainQuality(), hasCover: { url in url.path.contains("Schattenpfad (2)") })

        #expect(plan.groups[0].coverFromBookID == absorbedID)
    }

    @Test("a group with only one member is not planned at all")
    func skipsGroupsOfOne() throws {
        let temp = try TemporaryFolder()
        let library = try libraryAt(temp)
        let survivor = entry(title: "Solo", author: "A", number: 1)
        let entries = [survivor.book.id: survivor]
        let plan = BookMergePlanner.plan(
            groups: [MergeGroup(bookIDs: [survivor.book.id])], entries: entries, library: library,
            quality: plainQuality(), hasCover: { _ in false })
        #expect(plan.isEmpty)
    }
}
