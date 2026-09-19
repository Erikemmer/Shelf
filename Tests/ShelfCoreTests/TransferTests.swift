import Foundation
import Testing

@testable import ShelfCore

/// Sending books to a device: what goes, what cannot, what it is called there,
/// and the proof that what arrived is what left.
@Suite("Sending books to a device")
struct TransferTests {

    // MARK: Fixtures

    private func device(
        _ id: String, name: String = "READER", freeBytes: Int64? = 1_000_000_000,
        fileSystem: String? = "exfat", at url: URL = URL(fileURLWithPath: "/Volumes/READER")
    ) throws -> ConnectedDevice {
        let profile = try #require(DeviceProfiles.profile(id: id))
        return ConnectedDevice(
            volume: MountedVolume(url: url, name: name, freeBytes: freeBytes, fileSystem: fileSystem),
            profile: profile)
    }

    private func candidate(
        title: String, author: String = "Jane Austen", formats: [BookFileFormat] = [.epub],
        byteSize: Int64 = 1_000, digest: String? = nil, folder: URL = URL(fileURLWithPath: "/library/book")
    ) -> TransferCandidate {
        let book = Book(title: title, authors: [author])
        let rows = formats.map {
            BookFormat(
                bookID: book.id, format: $0, fileName: "\(title).\($0.fileExtension)", byteSize: byteSize,
                sha256: digest ?? "\(title)-\($0.rawValue)")
        }
        return TransferCandidate(
            entry: LibraryEntry(book: book, number: 1, folder: "x", formats: rows), folder: folder)
    }

    /// Everything exists unless a test says otherwise.
    private let everythingExists: (URL) -> Bool = { _ in true }

    // MARK: Choosing a format

    /// The whole reason a profile has its own preference order: Shelf's own
    /// ranks EPUB first because everything reads it, and a Kindle does not.
    @Test("a Kindle gets AZW3 before MOBI before PDF, and never an EPUB")
    func kindlePreference() throws {
        let kindle = try device("kindle")
        let plan = TransferPlanner.plan(
            candidates: [
                candidate(title: "All", formats: [.epub, .pdf, .mobi, .azw3]),
                candidate(title: "NoAZW3", formats: [.epub, .pdf, .mobi]),
                candidate(title: "OnlyPDF", formats: [.epub, .pdf]),
            ],
            device: kindle, fileExists: everythingExists)

        let chosen = Dictionary(uniqueKeysWithValues: plan.operations.map { ($0.title, $0.format) })
        #expect(chosen["All"] == .azw3)
        #expect(chosen["NoAZW3"] == .mobi)
        #expect(chosen["OnlyPDF"] == .pdf)
        #expect(!plan.operations.contains { $0.format == .epub })
    }

    /// The answer the brief asks for, word for word.
    @Test("a book the device cannot read is listed as cannot be sent, not converted")
    func noCompatibleFormat() throws {
        let kindle = try device("kindle")
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "EPUB only", formats: [.epub])],
            device: kindle, fileExists: everythingExists)

        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.noCompatibleFormat])
        #expect(SkippedTransfer.Reason.noCompatibleFormat.label == "cannot be sent: no compatible format")
    }

    @Test("a Kobo prefers KEPUB over EPUB, and takes a comic")
    func koboPreference() throws {
        let kobo = try device("kobo")
        let plan = TransferPlanner.plan(
            candidates: [
                candidate(title: "Both", formats: [.epub, .kepub]),
                candidate(title: "Comic", formats: [.cbz]),
            ],
            device: kobo, fileExists: everythingExists)
        let chosen = Dictionary(uniqueKeysWithValues: plan.operations.map { ($0.title, $0.format) })
        #expect(chosen["Both"] == .kepub)
        #expect(chosen["Comic"] == .cbz)
    }

    // MARK: Where the file lands

    @Test("books go into the device's own books folder")
    func booksFolder() throws {
        let kindle = try device("kindle")
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma", formats: [.azw3])], device: kindle,
            fileExists: everythingExists)
        #expect(plan.operations.first?.destinationPath == "documents/Jane Austen - Emma.azw3")

        let kobo = try device("kobo")
        let koboPlan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma", formats: [.epub])], device: kobo,
            fileExists: everythingExists)
        // A Kobo's books folder is the volume root.
        #expect(koboPlan.operations.first?.destinationPath == "Jane Austen - Emma.epub")
    }

    /// Two different books can share a title and an author, and a device file
    /// name has no running number to keep them apart.
    @Test("two books that would be called the same do not land on each other")
    func nameCollision() throws {
        let kobo = try device("kobo")
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma"), candidate(title: "Emma")],
            device: kobo, fileExists: everythingExists)

        let paths = plan.operations.map(\.destinationPath)
        #expect(Set(paths).count == 2)
        #expect(paths.contains("Jane Austen - Emma.epub"))
        #expect(paths.contains("Jane Austen - Emma (2).epub"))
    }

    // MARK: What is not sent

    @Test("the same bytes are not sent to the device twice")
    func alreadyOnDevice() throws {
        let kobo = try device("kobo")
        var manifest = DeviceManifest(deviceID: "kobo")
        manifest.record(
            .init(
                path: "Jane Austen - Emma.epub", bookID: UUID(), title: "Emma", author: "Jane Austen",
                format: .epub, byteSize: 1_000, sha256: "Emma-epub"))

        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma")], device: kobo, manifest: manifest,
            fileExists: everythingExists)
        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.alreadyOnDevice])
    }

    @Test("a book of 4 GB is refused before the copy on a FAT32 card, and allowed on exFAT")
    func tooBigForFAT32() throws {
        let big = candidate(title: "Huge", formats: [.pdf], byteSize: 5_000_000_000)
        let fat = try device("pocketbook", freeBytes: 30_000_000_000, fileSystem: "msdos")
        #expect(
            TransferPlanner.plan(candidates: [big], device: fat, fileExists: everythingExists)
                .skipped.map(\.reason) == [.tooBigForTheFileSystem])

        let exfat = try device("pocketbook", freeBytes: 30_000_000_000, fileSystem: "exfat")
        #expect(TransferPlanner.plan(candidates: [big], device: exfat, fileExists: everythingExists).fileCount == 1)
    }

    @Test("a file the index names and the folder has not got is a skip, not a failure")
    func missingFile() throws {
        let kobo = try device("kobo")
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Gone")], device: kobo, fileExists: { _ in false })
        #expect(plan.skipped.map(\.reason) == [.fileMissing])
    }

    // MARK: Room

    @Test("a plan that does not fit says so before anything is copied")
    func freeSpace() throws {
        let kobo = try device("kobo")
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma", byteSize: 1_000_000)], device: kobo,
            fileExists: everythingExists)
        #expect(!plan.fits(freeBytes: 500_000))
        #expect(plan.fits(freeBytes: 2_000_000))
        // The 5 % margin, the same one the import uses.
        #expect(!plan.fits(freeBytes: 1_000_001))
        // A volume that did not say is not a reason to refuse.
        #expect(plan.fits(freeBytes: nil))
    }

    @Test("the counting protocol says what will happen in one line")
    func summary() throws {
        let kindle = try device("kindle")
        let plan = TransferPlanner.plan(
            candidates: [
                candidate(title: "A", formats: [.azw3]),
                candidate(title: "B", formats: [.pdf]),
                candidate(title: "C", formats: [.epub]),
            ],
            device: kindle, fileExists: everythingExists)
        #expect(plan.summary().contains("2 books"))
        #expect(plan.summary().contains("AZW3 1"))
        #expect(plan.summary().contains("1 cannot be sent"))
    }

    // MARK: Actually copying

    /// A real copy onto a "device" that is a folder: the file arrives, it is
    /// read back and hashed, the manifest records the digest **of the copy**,
    /// and the report says "Verified".
    @Test("every file is read back off the device and hashed before it counts")
    func copyAndVerify() async throws {
        let temporary = try TemporaryFolder()
        let library = try temporary.folder("library")
        let volume = try temporary.folder("volume")
        try temporary.write("volume/.kobo/KoboReader.sqlite", text: "not really a database")
        let payload = Data("a synthetic book, 42 bytes of it, roughly".utf8)
        try payload.write(to: library.appendingPathComponent("Emma.epub"))
        let digest = try FileDigest.sha256(
            of: library.appendingPathComponent("Emma.epub"), makeHasher: PortableSHA256Hasher.factory)

        let kobo = try device("kobo", at: volume)
        let plan = TransferPlanner.plan(
            candidates: [
                candidate(
                    title: "Emma", byteSize: Int64(payload.count), digest: digest, folder: library)
            ],
            device: kobo)

        let outcome = try await TransferRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(device: kobo, plan: plan, manifest: DeviceManifest(deviceID: "kobo")))

        #expect(outcome.report.sent.count == 1)
        #expect(outcome.report.failures.isEmpty)
        #expect(outcome.report.headline == "Verified · 1 book · Skipped: 0 · Failed: 0")
        #expect(temporary.exists("volume/Jane Austen - Emma.epub"))
        // The digest in the manifest came off the device, not out of the plan.
        #expect(outcome.manifest.entries.first?.sha256 == digest)
        // And it is on the card, so the next plan can see it without a walk.
        let written = DeviceManifest.read(fromVolume: volume, deviceID: "kobo")
        #expect(written.entries.count == 1)
    }

    /// The resume the brief asks for: a second run over the same selection
    /// sends nothing, because the manifest on the card says it is there.
    @Test("a second run sends nothing, and says so rather than copying again")
    func resume() async throws {
        let temporary = try TemporaryFolder()
        let library = try temporary.folder("library")
        let volume = try temporary.folder("volume")
        let payload = Data("a synthetic book".utf8)
        try payload.write(to: library.appendingPathComponent("Emma.epub"))
        let digest = try FileDigest.sha256(
            of: library.appendingPathComponent("Emma.epub"), makeHasher: PortableSHA256Hasher.factory)

        let kobo = try device("kobo", at: volume)
        let book = candidate(title: "Emma", byteSize: Int64(payload.count), digest: digest, folder: library)
        let first = TransferPlanner.plan(candidates: [book], device: kobo)
        _ = try await TransferRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(device: kobo, plan: first, manifest: DeviceManifest(deviceID: "kobo")))

        let manifest = DeviceManifest.read(fromVolume: volume, deviceID: "kobo")
        let second = TransferPlanner.plan(candidates: [book], device: kobo, manifest: manifest)
        #expect(second.operations.isEmpty)
        #expect(second.skipped.map(\.reason) == [.alreadyOnDevice])
    }

    /// The defect `docs/RUNBOOK.md` §9 measured, pinned as a test: a transfer
    /// killed between two manifest writes leaves files on the card that no
    /// manifest names, and before this fix the next run reported every one of
    /// them as `FAILED … a file of that name is already on the device`.
    ///
    /// Killed the way a crash kills, not the way Cancel does: the file is put
    /// on the volume and the manifest is simply never told, which is exactly
    /// the state `kill -9` between two batches leaves behind.
    @Test("a resumed transfer recognises the files it wrote itself, and the manifest catches up")
    func resumeAfterAnUntidyDeath() async throws {
        let temporary = try TemporaryFolder()
        let library = try temporary.folder("library")
        let volume = try temporary.folder("volume")
        let payload = Data("a synthetic book".utf8)
        try payload.write(to: library.appendingPathComponent("Emma.epub"))
        let digest = try FileDigest.sha256(
            of: library.appendingPathComponent("Emma.epub"), makeHasher: PortableSHA256Hasher.factory)

        let kobo = try device("kobo", at: volume)
        let book = candidate(title: "Emma", byteSize: Int64(payload.count), digest: digest, folder: library)

        // What the killed run left: the book on the card, and an empty manifest.
        try payload.write(to: volume.appendingPathComponent("Jane Austen - Emma.epub"))
        #expect(DeviceManifest.read(fromVolume: volume, deviceID: "kobo").entries.isEmpty)

        let plan = TransferPlanner.plan(
            candidates: [book], device: kobo,
            onDevice: .onVolume(volume, makeHasher: PortableSHA256Hasher.factory))
        #expect(plan.operations.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.alreadyOnDevice])
        #expect(plan.adopted.map(\.path) == ["Jane Austen - Emma.epub"])

        let outcome = try await TransferRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(device: kobo, plan: plan, manifest: DeviceManifest(deviceID: "kobo")))

        // Not one failure, where there used to be one per file.
        #expect(outcome.report.failures.isEmpty)
        // And the card describes itself again, which it never did before.
        let written = DeviceManifest.read(fromVolume: volume, deviceID: "kobo")
        #expect(written.entries.map(\.path) == ["Jane Austen - Emma.epub"])
        #expect(written.entries.first?.sha256 == digest)
    }

    /// The other half of the same rule, and the more important one: a file
    /// Shelf did **not** write is neither claimed nor written over.
    @Test("a file of the same name but other bytes is left alone, not adopted")
    func aStrangersFileIsNotClaimed() async throws {
        let temporary = try TemporaryFolder()
        let library = try temporary.folder("library")
        let volume = try temporary.folder("volume")
        try Data("a synthetic book".utf8).write(to: library.appendingPathComponent("Emma.epub"))
        let digest = try FileDigest.sha256(
            of: library.appendingPathComponent("Emma.epub"), makeHasher: PortableSHA256Hasher.factory)
        let somebodyElses = Data("quite another Emma entirely".utf8)
        try somebodyElses.write(to: volume.appendingPathComponent("Jane Austen - Emma.epub"))

        let kobo = try device("kobo", at: volume)
        let book = candidate(title: "Emma", byteSize: 16, digest: digest, folder: library)
        let plan = TransferPlanner.plan(
            candidates: [book], device: kobo,
            onDevice: .onVolume(volume, makeHasher: PortableSHA256Hasher.factory))

        #expect(plan.adopted.isEmpty)
        #expect(plan.operations.count == 1)

        let outcome = try await TransferRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(device: kobo, plan: plan, manifest: DeviceManifest(deviceID: "kobo")))
        #expect(outcome.report.failures.count == 1)
        // The refusal is the point: the stranger's file is still theirs.
        let onCard = try Data(contentsOf: volume.appendingPathComponent("Jane Austen - Emma.epub"))
        #expect(onCard == somebodyElses)
    }

    /// Nothing that is not a finished book is left behind, whatever happened.
    @Test("a run leaves no .part file on the device")
    func noLeftovers() async throws {
        let temporary = try TemporaryFolder()
        let library = try temporary.folder("library")
        let volume = try temporary.folder("volume")
        try Data("book".utf8).write(to: library.appendingPathComponent("Emma.epub"))
        // A leftover from a run that was killed: this one takes it away.
        try temporary.write("volume/\(TransferRunner.partialPrefix)deadbeef.part", text: "half a book")

        let kobo = try device("kobo", at: volume)
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma", byteSize: 4, folder: library)], device: kobo)
        _ = try await TransferRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(device: kobo, plan: plan, manifest: DeviceManifest(deviceID: "kobo")))

        let leftovers = temporary.names(in: "volume").filter { $0.hasSuffix(".part") }
        #expect(leftovers.isEmpty)
    }

    @Test("a full device is refused before the first byte")
    func notEnoughRoom() async throws {
        let temporary = try TemporaryFolder()
        let library = try temporary.folder("library")
        let volume = try temporary.folder("volume")
        try Data("book".utf8).write(to: library.appendingPathComponent("Emma.epub"))

        let kobo = try device("kobo", at: volume)
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma", byteSize: 1_000_000, folder: library)], device: kobo)
        let runner = TransferRunner(makeHasher: PortableSHA256Hasher.factory, freeSpace: { _ in 10 })

        await #expect(throws: TransferRunner.Failure.self) {
            _ = try await runner.run(.init(device: kobo, plan: plan, manifest: DeviceManifest(deviceID: "kobo")))
        }
        #expect(temporary.names(in: "volume").isEmpty)
    }

    /// A file already on the card under the name a book would get is never
    /// written over: it is something Shelf did not put there.
    @Test("a file already on the device is never overwritten")
    func neverOverwrites() async throws {
        let temporary = try TemporaryFolder()
        let library = try temporary.folder("library")
        let volume = try temporary.folder("volume")
        try Data("the new book".utf8).write(to: library.appendingPathComponent("Emma.epub"))
        try temporary.write("volume/Jane Austen - Emma.epub", text: "somebody else's file")

        let kobo = try device("kobo", at: volume)
        let plan = TransferPlanner.plan(
            candidates: [candidate(title: "Emma", byteSize: 12, folder: library)], device: kobo)
        let outcome = try await TransferRunner(makeHasher: PortableSHA256Hasher.factory)
            .run(.init(device: kobo, plan: plan, manifest: DeviceManifest(deviceID: "kobo")))

        #expect(outcome.report.sent.isEmpty)
        #expect(outcome.report.failures.count == 1)
        let stillThere = try String(
            contentsOf: volume.appendingPathComponent("Jane Austen - Emma.epub"), encoding: .utf8)
        #expect(stillThere == "somebody else's file")
    }
}
