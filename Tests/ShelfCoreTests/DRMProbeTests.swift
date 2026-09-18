import Foundation
import Testing

@testable import ShelfCore

/// Recognising protection, and never doing anything else about it.
///
/// Every test here checks two things at once: that the flag is seen, and that
/// the file is otherwise read and kept. Shelf detects DRM so it can tell the
/// user why a book's metadata is thin — not as a step towards anything, and
/// nothing in this repository explains how to remove it (CONCEPT §12, ADR 0012).
@Suite("Recognising DRM")
struct DRMProbeTests {

    private func hasher() -> HasherFactory { PortableSHA256Hasher.factory }

    // MARK: The probe itself

    @Test("an EPUB with META-INF/encryption.xml is Adobe DRM")
    func adobeEPUB() throws {
        let folder = try TemporaryFolder()
        let book = Book(title: "Protected", authors: ["A Publisher"])
        let url = try folder.write("p.epub", data: SyntheticEPUB.withAdobeDRM(book: book).data())

        #expect(DRMProbe.drm(of: url, format: .epub) == .adobeADEPT)
        // And the same file without it is not protected, which is what makes
        // the test above mean something.
        let clean = try folder.write("c.epub", data: SyntheticEPUB(book: book).data())
        #expect(DRMProbe.drm(of: clean, format: .epub) == nil)
    }

    @Test("a MOBI or AZW3 announcing EXTH 209 is Kindle DRM")
    func kindleMobi() throws {
        let folder = try TemporaryFolder()
        let book = Book(title: "Protected", authors: ["A Publisher"])

        for (name, format, isAZW3) in [("p.mobi", BookFileFormat.mobi, false), ("p.azw3", .azw3, true)] {
            let url = try folder.write(
                name, data: SyntheticMobi(book: book, isAZW3: isAZW3, withKindleDRM: true).data())
            #expect(DRMProbe.drm(of: url, format: format) == .kindle)
        }
        let clean = try folder.write("c.mobi", data: SyntheticMobi(book: book).data())
        #expect(DRMProbe.drm(of: clean, format: .mobi) == nil)
    }

    @Test("a comic and a KFX carry no scheme Shelf recognises")
    func noSchemeForTheRest() throws {
        let folder = try TemporaryFolder()
        let cbz = try folder.write("a.cbz", data: SyntheticComic().data())
        #expect(DRMProbe.drm(of: cbz, format: .cbz) == nil)
        let kfx = try folder.write("a.kfx", data: Data("CONT".utf8))
        #expect(DRMProbe.drm(of: kfx, format: .kfx) == nil)
    }

    @Test("an ordinary PDF is not called protected")
    func plainPDF() throws {
        let folder = try TemporaryFolder()
        let url = try folder.write("a.pdf", data: SyntheticPDF(book: Book(title: "Emma", authors: ["A"])).data())
        #expect(DRMProbe.drm(of: url, format: .pdf) == nil)
    }

    /// The heuristic, stated: an encrypted PDF names `/Encrypt` in its trailer,
    /// and the trailer is at the end of the file.
    @Test("a PDF naming /Encrypt in its trailer is protected")
    func encryptedPDF() throws {
        let folder = try TemporaryFolder()
        var pdf = SyntheticPDF(book: Book(title: "Emma", authors: ["A"])).data()
        pdf.append(Data("\ntrailer\n<< /Encrypt 9 0 R >>\n%%EOF\n".utf8))
        let url = try folder.write("e.pdf", data: pdf)
        #expect(DRMProbe.drm(of: url, format: .pdf) == .unknown)
    }

    /// Erring towards "not protected" on purpose: a badge that is missing is a
    /// smaller wrong than a badge on a file that reads perfectly well.
    @Test("a file that cannot be read is unreadable, not protected")
    func unreadableIsNotProtected() {
        let missing = URL(fileURLWithPath: "/nowhere/at/all.epub")
        for format in BookFileFormat.allCases {
            #expect(DRMProbe.drm(of: missing, format: format) == nil, "\(format.label) called a missing file protected")
        }
    }

    // MARK: One badge for a book whose files disagree

    /// A protected book bought twice really is an EPUB with Adobe's DRM and an
    /// AZW3 with Kindle's. The grid has room for one badge, and naming either
    /// one of them would be wrong about the other file.
    @Test("a book protected two different ways is badged simply 'DRM'")
    func mixedProtection() {
        let id = UUID()
        func format(_ kind: BookFileFormat, _ drm: DRMKind?) -> BookFormat {
            BookFormat(bookID: id, format: kind, fileName: "x.\(kind.rawValue)", byteSize: 1, sha256: "d", drm: drm)
        }
        var entry = LibraryEntry(book: Book(id: id, title: "Protected", authors: ["A"]), number: 1, folder: "A/B")

        entry.formats = [format(.epub, .adobeADEPT), format(.azw3, .kindle)]
        #expect(entry.drm == .unknown)
        #expect(entry.drm?.label == "DRM")

        // One kind, however many files carry it, keeps its own name.
        entry.formats = [format(.mobi, .kindle), format(.azw3, .kindle)]
        #expect(entry.drm == .kindle)

        // A protected file next to an unprotected one is still that protection.
        entry.formats = [format(.epub, .adobeADEPT), format(.pdf, nil)]
        #expect(entry.drm == .adobeADEPT)

        entry.formats = [format(.epub, nil), format(.pdf, nil)]
        #expect(entry.drm == nil)
    }

    // MARK: The defect the proof run found

    /// **The regression this file exists for.** The importer detected DRM and
    /// stored it; `Rebuild Index from Folders` set it back to nothing. Nine
    /// protected files in the measuring library, nine badges, and after a
    /// rebuild zero — with nothing failing and nothing logged.
    ///
    /// The index is a cache and may be thrown away at any time (ADR 0001), so
    /// anything it holds has to be re-derivable from the folder. This one was
    /// not.
    @Test("DRM survives throwing the index away and rebuilding from the folders")
    func drmSurvivesARebuild() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))

        // Three protected files of the three kinds that can carry the
        // announcement, and one clean book so the test can tell "everything is
        // badged" from "the right things are badged".
        var candidates: [ImportCandidate] = []
        let protectedBook = Book(title: "Protected", authors: ["A Publisher"])
        let files: [(String, BookFileFormat, Data)] = [
            ("p.epub", .epub, SyntheticEPUB.withAdobeDRM(book: protectedBook).data()),
            ("p.mobi", .mobi, SyntheticMobi(book: protectedBook, withKindleDRM: true).data()),
            ("p.azw3", .azw3, SyntheticMobi(book: protectedBook, isAZW3: true, withKindleDRM: true).data()),
            ("clean.epub", .epub, SyntheticEPUB(book: Book(title: "Clean", authors: ["Somebody"])).data()),
        ]
        for (name, format, data) in files {
            let url = try temporary.write("source/\(name)", data: data)
            let read = BookFileReader.read(url: url, format: format)
            candidates.append(
                ImportCandidate(
                    source: url, byteSize: Int64(data.count), format: format,
                    sha256: try FileDigest.sha256(of: url, makeHasher: hasher()),
                    book: read.book, cover: read.cover, coverName: read.coverName, drm: read.drm))
        }

        let plan = ImportPlanner.plan(candidates: candidates)
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: plan, sourceDescription: "test"))

        let importedDRM = outcome.entries.flatMap { $0.formats }.compactMap(\.drm)
        #expect(importedDRM.count == 3)
        #expect(Set(importedDRM) == [.adobeADEPT, .kindle])

        // And now the part that was broken: throw it all away and read the
        // folders again.
        let rebuilt = try IndexRebuilder(makeHasher: hasher()).rebuild(library)
        let rebuiltDRM = rebuilt.entries.flatMap { $0.formats }.compactMap(\.drm)

        #expect(rebuiltDRM.count == 3, "a rebuild lost the DRM badges")
        #expect(Set(rebuiltDRM) == [.adobeADEPT, .kindle])
        // The clean book is still clean: the fix must not badge everything.
        #expect(rebuilt.entries.flatMap { $0.formats }.count == 4)
    }

    /// The badge is a fact about the bytes, not a note somebody once made — so
    /// a file that stops being protected stops being badged.
    @Test("a file whose protection is gone stops being badged on the next rebuild")
    func badgeFollowsTheBytes() async throws {
        let temporary = try TemporaryFolder()
        let (library, _) = try Library.create(at: try temporary.folder("Lib"))
        let book = Book(title: "Protected", authors: ["A Publisher"])
        let data = SyntheticEPUB.withAdobeDRM(book: book).data()
        let url = try temporary.write("source/p.epub", data: data)
        let read = BookFileReader.read(url: url, format: .epub)

        let plan = ImportPlanner.plan(candidates: [
            ImportCandidate(
                source: url, byteSize: Int64(data.count), format: .epub,
                sha256: try FileDigest.sha256(of: url, makeHasher: hasher()),
                book: read.book, cover: read.cover, drm: read.drm)
        ])
        let outcome = try await ImportRunner(makeHasher: hasher())
            .run(.init(library: library, plan: plan, sourceDescription: "test"))
        #expect(outcome.entries.first?.formats.first?.drm == .adobeADEPT)

        // Replace the file in the library with the same book, unprotected.
        // (Shelf itself never writes a book file — this is the test standing in
        // for whatever the user did outside it.)
        let entry = try #require(outcome.entries.first)
        let inLibrary = library.root
            .appendingPathComponent(entry.folder)
            .appendingPathComponent(try #require(entry.formats.first).fileName)
        try SyntheticEPUB(book: book).data().write(to: inLibrary)

        let rebuilt = try IndexRebuilder(makeHasher: hasher()).rebuild(library)
        #expect(rebuilt.entries.first?.formats.first?.drm == nil)
    }
}
