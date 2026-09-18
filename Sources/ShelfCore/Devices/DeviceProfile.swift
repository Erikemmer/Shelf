import Foundation

/// What Shelf knows about one kind of e-reader.
///
/// **Data, not code** ([ADR 0013](../../../docs/adr/0013-device-profiles-are-data-not-code.md)):
/// one JSON file per device in `Devices/Profiles/`, loaded at runtime. A new
/// model, a changed books folder or a device that has learned a format is a
/// file somebody can write — including a user, one day — rather than a release.
/// The same argument the formats table and the shortcut list are already built
/// on, taken one step further because a device is the one thing here that
/// changes without Shelf changing.
public struct DeviceProfile: Equatable, Sendable, Codable, Identifiable {
    /// Stable, lower case, and what the manifest on the device stores.
    public var id: String
    /// What the sidebar calls it.
    public var name: String
    /// Paths that must **all** exist, relative to the volume root, for this
    /// volume to be this device.
    public var markers: [String]
    /// Volume names that say so on their own, compared case-insensitively.
    /// A Tolino is recognised by `.tolino/` *or* by being called "tolino",
    /// because not every model writes the folder.
    public var volumeNames: [String]
    /// Where books go, relative to the volume root. Empty means the root.
    public var booksFolder: String
    /// What the device can open at all. A file of any other format is never
    /// written to it.
    public var formats: [BookFileFormat]
    /// Which of them to send when a book has several, best first.
    ///
    /// Not `BookFileFormat.preferenceRank`: that ranks formats for *Shelf*,
    /// where EPUB wins because everything reads it. A Kindle reads AZW3 and
    /// not EPUB, and a profile that could not say so would send it a file it
    /// cannot open.
    public var preferredFormats: [BookFileFormat]
    /// How the file is named on the device. `{author}` and `{title}`.
    public var fileNamePattern: String
    /// What can be read back from the device.
    public var readBack: ReadBack
    /// A sentence the transfer sheet shows about this device, when there is
    /// one worth saying — "a Kindle does not read EPUB over USB".
    public var note: String?

    public enum ReadBack: String, Equatable, Sendable, Codable {
        /// The files on it, and nothing else.
        case fileList
        /// The files, plus reading progress, shelves and read status out of
        /// `KoboReader.sqlite` — **read only**, through a copy, and never
        /// written back (CONCEPT §8.1, ADR 0009).
        case kobo
    }

    public init(
        id: String, name: String, markers: [String], volumeNames: [String] = [], booksFolder: String,
        formats: [BookFileFormat], preferredFormats: [BookFileFormat],
        fileNamePattern: String = DeviceFileName.defaultPattern,
        readBack: ReadBack = .fileList, note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.markers = markers
        self.volumeNames = volumeNames
        self.booksFolder = booksFolder
        self.formats = formats
        self.preferredFormats = preferredFormats
        self.fileNamePattern = fileNamePattern
        self.readBack = readBack
        self.note = note
    }

    /// The best format of the ones a book actually has, or nothing.
    ///
    /// Nothing is an answer the sheet shows — "cannot be sent: no compatible
    /// format" — rather than something to work around. Shelf converts nothing
    /// in v1.0 (CONCEPT §4, "Won't").
    public func bestFormat(among available: Set<BookFileFormat>) -> BookFileFormat? {
        preferredFormats.first { available.contains($0) }
    }

    /// Whether a format may be written to this device at all.
    public func accepts(_ format: BookFileFormat) -> Bool { formats.contains(format) }
}

/// The profiles that ship with Shelf, read from the JSON beside this file.
///
/// Loaded once and kept, because a volume appearing is not a reason to read
/// four files off the disk. A profile that will not decode is **left out and
/// named**, never a crash: a malformed file must cost its own device and
/// nothing else.
public enum DeviceProfiles {

    /// Every profile Shelf could read, and every file it could not.
    public struct Loaded: Sendable {
        public var profiles: [DeviceProfile]
        /// File name → why it was left out. Shown in the device sheet, so a
        /// profile somebody edited by hand and broke says so.
        public var failures: [String: String]

        public init(profiles: [DeviceProfile], failures: [String: String] = [:]) {
            self.profiles = profiles
            self.failures = failures
        }
    }

    /// The bundled profiles, in the order detection tries them.
    public static let bundled: Loaded = load()

    public static var all: [DeviceProfile] { bundled.profiles }

    public static func profile(id: String) -> DeviceProfile? {
        all.first { $0.id == id }
    }

    /// Reads every `.json` in the profiles folder of the package's own bundle.
    ///
    /// `Bundle.module`, which SwiftPM generates on macOS and on Linux alike —
    /// the core is tested on both and a profile that only loaded on a Mac
    /// would be a rule only half of CI can see.
    static func load(from directory: URL? = nil) -> Loaded {
        let folder = directory ?? Bundle.module.url(forResource: "Profiles", withExtension: nil)
        guard let folder,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return Loaded(profiles: []) }

        var profiles: [DeviceProfile] = []
        var failures: [String: String] = [:]
        let decoder = JSONDecoder()
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            do {
                let profile = try decoder.decode(DeviceProfile.self, from: Data(contentsOf: url))
                profiles.append(profile)
            } catch {
                failures[name] = (error as NSError).localizedDescription
            }
        }
        return Loaded(profiles: ordered(profiles), failures: failures)
    }

    /// Detection order: **the most specific profile first.**
    ///
    /// A Kindle is `system/` *and* `documents/`; a PocketBook is `system/` and
    /// `applications/`. Both would match a volume that had all three, and
    /// which one won would otherwise depend on the order a directory listing
    /// came back in — which is not a rule, it is a coincidence. More markers
    /// means more evidence; ties go by name so two runs agree.
    static func ordered(_ profiles: [DeviceProfile]) -> [DeviceProfile] {
        profiles.sorted {
            $0.markers.count == $1.markers.count ? $0.id < $1.id : $0.markers.count > $1.markers.count
        }
    }
}
