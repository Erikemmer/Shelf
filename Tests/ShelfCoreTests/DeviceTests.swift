import Foundation
import Testing

@testable import ShelfCore

/// Devices: recognising one, deciding what may go on it, what each file is
/// called there, and reading a Kobo back.
///
/// Every rule in here is tested **without a device**, which is the whole reason
/// the rules are values rather than file-system calls: the proof run has disk
/// images and nobody has four readers on the desk. What genuinely needs
/// hardware is listed in `docs/BACKLOG.md` under "To check on real hardware"
/// and is not claimed here.
@Suite("Devices")
struct DeviceTests {

    // MARK: Profiles are data

    @Test("the four profiles the concept names are there, and they are files")
    func bundledProfiles() {
        let ids = DeviceProfiles.all.map(\.id).sorted()
        #expect(ids == ["kindle", "kobo", "pocketbook", "tolino"])
        #expect(DeviceProfiles.bundled.failures.isEmpty)
    }

    @Test("a Kindle profile says what a Kindle takes, and in which order")
    func kindleProfile() throws {
        let kindle = try #require(DeviceProfiles.profile(id: "kindle"))
        #expect(kindle.booksFolder == "documents")
        #expect(kindle.preferredFormats == [.azw3, .mobi, .pdf])
        #expect(!kindle.accepts(.epub))
        // The one sentence the transfer sheet shows about it.
        #expect(kindle.note?.contains("EPUB") == true)
    }

    /// A profile that will not decode costs its own device and nothing else.
    @Test("a broken profile file is left out and named, not a crash")
    func brokenProfile() throws {
        let folder = try TemporaryFolder()
        try folder.write(
            "Profiles/good.json",
            text: """
                {"id":"good","name":"Good","markers":["m"],"volumeNames":[],"booksFolder":"",
                 "formats":["epub"],"preferredFormats":["epub"],"fileNamePattern":"{author} - {title}",
                 "readBack":"fileList","note":null}
                """)
        try folder.write("Profiles/broken.json", text: "{ this is not JSON")

        let loaded = DeviceProfiles.load(from: folder.url.appendingPathComponent("Profiles"))
        #expect(loaded.profiles.map(\.id) == ["good"])
        #expect(loaded.failures.keys.contains("broken.json"))
    }

    // MARK: Detection

    private func volume(_ name: String, freeBytes: Int64? = nil, fileSystem: String? = nil) -> MountedVolume {
        MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name, freeBytes: freeBytes,
            fileSystem: fileSystem)
    }

    @Test(
        "each of the four layouts is recognised by its marker",
        arguments: [
            (["(.kobo/KoboReader.sqlite)"], "kobo"),
            (["(system)", "(documents)"], "kindle"),
            (["(.tolino)"], "tolino"),
            (["(system)", "(applications)"], "pocketbook"),
        ])
    func layouts(present: [String], expected: String) {
        let paths = Set(present.map { String($0.dropFirst().dropLast()) })
        let found = DeviceDetection.profile(for: volume("READER")) { paths.contains($0) }
        #expect(found?.id == expected)
    }

    /// The reason detection asks for **all** of a profile's markers. `system/`
    /// on its own is a Kindle, a PocketBook and half the USB sticks in the
    /// world.
    @Test("one marker of two is not a device")
    func partialMarkers() {
        let found = DeviceDetection.profile(for: volume("STICK")) { $0 == "system" }
        #expect(found == nil)
    }

    @Test("a plain USB stick is not a device")
    func plainStick() {
        #expect(DeviceDetection.profile(for: volume("USB")) { _ in false } == nil)
    }

    /// Not every Tolino writes `.tolino/`, so the volume's name is the second
    /// route — and the only profile that has one is the one that needs it.
    @Test("a Tolino is recognised by its volume name when the folder is missing")
    func tolinoByName() {
        #expect(DeviceDetection.profile(for: volume("tolino")) { _ in false }?.id == "tolino")
        #expect(DeviceDetection.profile(for: volume("Tolino")) { _ in false }?.id == "tolino")
        // And no other profile answers to a name.
        #expect(DeviceDetection.profile(for: volume("kindle")) { _ in false } == nil)
    }

    /// Kindle and PocketBook share `system/`. A volume carrying every marker
    /// of both must not depend on the order a directory listing came back in.
    @Test("a volume matching two profiles takes the more specific one, the same way twice")
    func detectionOrderIsARule() {
        let all: Set<String> = ["system", "documents", "applications"]
        let first = DeviceDetection.profile(for: volume("ODD")) { all.contains($0) }
        let second = DeviceDetection.profile(for: volume("ODD")) { all.contains($0) }
        #expect(first?.id == second?.id)
        #expect(first?.id == "kindle")
    }

    // MARK: File names on the device

    @Test("a book on a device is {author} - {title}.{ext}")
    func deviceName() {
        var book = Book(title: "Emma", authors: ["Jane Austen"])
        book.titleSort = "Emma"
        #expect(DeviceFileName.of(book, format: .epub) == "Jane Austen - Emma.epub")
    }

    /// The characters FAT32 and exFAT refuse. Every reader that takes a USB
    /// cable is formatted with one of them.
    @Test("characters no FAT file system takes are cleaned out")
    func forbiddenCharacters() {
        let book = Book(title: "Who? What: Where/When", authors: ["A*B|C"])
        let name = DeviceFileName.of(book, format: .epub)
        #expect(!name.contains { BookFolderName.forbidden.contains($0) })
        #expect(name.hasSuffix(".epub"))
    }

    /// FAT drops a trailing dot or space, so two titles that differ only there
    /// would become one file and the second copy would land on the first.
    @Test("a name never ends in a dot or a space before its extension")
    func noTrailingDotOrSpace() {
        let book = Book(title: "Vol. 2 .", authors: ["An Author"])
        let name = DeviceFileName.of(book, format: .epub)
        #expect(name == "An Author - Vol. 2.epub")
    }

    /// Two budgets, and the shorter one wins: FAT counts UTF-16 code units and
    /// APFS counts bytes, and neither can be derived from the other.
    @Test("a very long name is cut to both the byte and the UTF-16 budget")
    func longNames() {
        let book = Book(title: String(repeating: "ä", count: 400), authors: [String(repeating: "Ω", count: 80)])
        let name = DeviceFileName.of(book, format: .epub)
        #expect(name.utf8.count <= DeviceFileName.maxNameBytes)
        #expect(name.utf16.count <= DeviceFileName.maxNameUTF16)
        #expect(name.hasSuffix(".epub"))

        let emoji = Book(title: String(repeating: "📚", count: 300), authors: ["A"])
        let emojiName = DeviceFileName.of(emoji, format: .epub)
        #expect(emojiName.utf8.count <= DeviceFileName.maxNameBytes)
        #expect(emojiName.utf16.count <= DeviceFileName.maxNameUTF16)
    }

    @Test("a name Windows reserves outright gets out of the way")
    func reservedNames() {
        let book = Book(title: "NUL", authors: [""])
        #expect(DeviceFileName.of(book, format: .epub, pattern: "{title}") == "NUL_.epub")
    }

    @Test("a file of 4 GB or more cannot go on FAT32, and can go on anything else")
    func fourGigabyteLimit() {
        #expect(DeviceFileName.isTooBig(5_000_000_000, forFAT32: true))
        #expect(!DeviceFileName.isTooBig(5_000_000_000, forFAT32: false))
        #expect(!DeviceFileName.isTooBig(DeviceFileName.fat32MaxFileBytes, forFAT32: true))
    }

    @Test("the file system decides whether the 4 GB limit applies, and an unknown one does not")
    func fileSystemLimit() {
        #expect(volume("A", fileSystem: "msdos").hasFAT32FileSizeLimit)
        #expect(!volume("A", fileSystem: "exfat").hasFAT32FileSizeLimit)
        #expect(!volume("A", fileSystem: nil).hasFAT32FileSizeLimit)
    }
}
