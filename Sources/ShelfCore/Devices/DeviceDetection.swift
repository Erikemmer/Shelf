import Foundation

/// A volume that is mounted, as far as detection needs to know.
///
/// A value rather than a `URL`, so the whole of "is this a reader, and which
/// one" can be decided without a disk — which is what lets the four device
/// layouts be tested on Linux, and what lets the app hand in a volume it has
/// already listed once.
public struct MountedVolume: Equatable, Sendable {
    public var url: URL
    /// What the Finder shows. Matched against a profile's `volumeNames`.
    public var name: String
    /// Bytes free, when the file system says. `nil` rather than 0: "unknown"
    /// and "full" are different answers and the transfer sheet says so.
    public var freeBytes: Int64?
    public var totalBytes: Int64?
    /// Whether the volume can be unmounted — a hard disk cannot, a reader can.
    public var isRemovable: Bool
    /// `msdos`, `exfat`, `hfs`, `apfs`. Carried because FAT32 cannot hold a
    /// file of 4 GB, which is a thing to say *before* a transfer rather than
    /// after it fails.
    public var fileSystem: String?

    public init(
        url: URL, name: String, freeBytes: Int64? = nil, totalBytes: Int64? = nil,
        isRemovable: Bool = true, fileSystem: String? = nil
    ) {
        self.url = url
        self.name = name
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.isRemovable = isRemovable
        self.fileSystem = fileSystem
    }

    /// Whether files on this volume are limited to just under 4 GB.
    ///
    /// FAT32 stores a file's size in 32 bits, so 4 GiB − 1 is the ceiling.
    /// exFAT, which newer readers use, has no such limit. When the file system
    /// is unknown the answer is *no*: refusing a book because of a guess would
    /// be worse than letting the copy fail and saying why.
    public var hasFAT32FileSizeLimit: Bool {
        guard let fileSystem else { return false }
        return DeviceFileName.fat32FileSystemNames.contains(fileSystem.lowercased())
    }
}

/// A reader Shelf has recognised: a volume and the profile that matched it.
public struct ConnectedDevice: Equatable, Sendable, Identifiable {
    public var volume: MountedVolume
    public var profile: DeviceProfile
    /// Whether the user said so by hand rather than a marker matching
    /// ("Treat this volume as device…"). Kept because it changes what Shelf
    /// may claim: a guessed device is one the person vouched for.
    public var wasChosenByHand: Bool

    public var id: String { volume.url.path }
    public var name: String { volume.name }

    /// Where books live on it, absolute.
    public var booksFolder: URL {
        profile.booksFolder.isEmpty
            ? volume.url : volume.url.appendingPathComponent(profile.booksFolder, isDirectory: true)
    }

    public init(volume: MountedVolume, profile: DeviceProfile, wasChosenByHand: Bool = false) {
        self.volume = volume
        self.profile = profile
        self.wasChosenByHand = wasChosenByHand
    }
}

/// Which profile, if any, a mounted volume is.
///
/// Pure over a "does this path exist" question, so the four layouts are tested
/// without four devices — and so the proof run can hand it disk images
/// (`Scripts/device-images.sh`) and get the same answer a real Kobo would.
public enum DeviceDetection {

    /// The profile this volume matches, or nothing.
    ///
    /// - Parameter exists: whether a path relative to the volume root is there.
    ///   The app passes `FileManager.fileExists`; a test passes a set.
    public static func profile(
        for volume: MountedVolume,
        profiles: [DeviceProfile] = DeviceProfiles.all,
        exists: (String) -> Bool
    ) -> DeviceProfile? {
        // A reader is something you unplug. The check is here rather than only
        // in the app's listing because this function is what answers "is this
        // a device", and the boot disk must not be one whatever is at its root.
        guard volume.isRemovable else { return nil }
        return DeviceProfiles.ordered(profiles).first { matches(volume, $0, exists: exists) }
    }

    /// A volume is a device when **all** of a profile's markers are there, or
    /// when its name is one the profile claims.
    ///
    /// All of them, not any: `system/` alone is a Kindle and a PocketBook and
    /// half the USB sticks in the world. The name is the separate, weaker
    /// route, and only a profile that asks for it has one — a Tolino, because
    /// not every model writes `.tolino/`.
    static func matches(_ volume: MountedVolume, _ profile: DeviceProfile, exists: (String) -> Bool) -> Bool {
        if !profile.markers.isEmpty, profile.markers.allSatisfy(exists) { return true }
        let name = volume.name.lowercased()
        return profile.volumeNames.contains { $0.lowercased() == name }
    }

    /// The same question against a real volume on disk.
    public static func profile(
        forVolumeAt url: URL, name: String, isRemovable: Bool = true,
        profiles: [DeviceProfile] = DeviceProfiles.all
    ) -> DeviceProfile? {
        profile(
            for: MountedVolume(url: url, name: name, isRemovable: isRemovable), profiles: profiles
        ) { relative in
            existsExactly(relative, under: url)
        }
    }

    /// Whether a path exists on this volume **spelt exactly this way**.
    ///
    /// `FileManager.fileExists` is not enough, and this is not a theoretical
    /// worry. APFS is case-insensitive by default, so asking a Mac's boot disk
    /// for `system` and `applications` gets `/System` and `/Applications` and
    /// the volume answers as a PocketBook. The first run of
    /// `shelf-tool devices` printed exactly that:
    ///
    ///     /Volumes/Macintosh HD
    ///       device: PocketBook (pocketbook)
    ///
    /// A marker is a *name*, and a file system that answers to the wrong case
    /// is not evidence that the name is there. So each component is checked
    /// against the directory's own listing.
    ///
    /// **The URL form of `contentsOfDirectory`, never the path form.** They
    /// disagree on FAT, which is what every reader that takes a USB cable is
    /// formatted with. On a FAT32 card holding a folder called `system`:
    ///
    ///     contentsOfDirectory(atPath:)  → ["System", "documents", …]
    ///     contentsOfDirectory(at:)      → ["system", "documents", …]
    ///     readdir(3), ls(1), find(1)    → ["system", "documents", …]
    ///
    /// The path form is the odd one out, and building the check on it made
    /// every Kindle and every PocketBook stop being recognised the moment the
    /// proof run put them on a real FAT32 volume. The URL form agrees with the
    /// kernel, so it is the one that answers a question about a name.
    static func existsExactly(_ relative: String, under root: URL) -> Bool {
        var current = root
        for component in relative.split(separator: "/").map(String.init) {
            guard
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: current, includingPropertiesForKeys: nil),
                contents.contains(where: { $0.lastPathComponent == component })
            else { return false }
            current = current.appendingPathComponent(component)
        }
        return true
    }
}
