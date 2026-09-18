import AppKit
import Darwin
import Foundation
import ShelfCore

/// Notices volumes coming and going, and says which of them are readers.
///
/// `NSWorkspace`'s own notifications rather than polling (CONCEPT §8.1):
/// plugging a Kobo in should put it in the sidebar at once, and a loop asking
/// the file system every second would be a background task running for the
/// life of the app to answer a question that is already broadcast.
///
/// **In the app layer** because `NSWorkspace` is AppKit's. What it produces is
/// `MountedVolume` values, and every decision made from them — which profile
/// matches, what may be sent, what a file is called there — is in the core,
/// where it is tested without a device.
@MainActor
final class DeviceWatcher {
    private var observers: [NSObjectProtocol] = []

    /// - Parameter onChange: called on the main actor whenever a volume has
    ///   appeared or gone. `@MainActor` on the parameter rather than a hop
    ///   inside: the notification already arrives on the main queue, and a
    ///   `Task` would let a second mount overtake the first — which on a reader
    ///   with internal storage *and* an SD card is the ordinary case, not a
    ///   corner one.
    func start(_ onChange: @escaping @MainActor () -> Void) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange() }
                })
        }
    }

    /// Takes the observers off again.
    ///
    /// Called from the window's `onDisappear` rather than from a `deinit`: a
    /// `deinit` is not actor-isolated in Swift 6 and cannot touch these, and a
    /// watcher that outlived its model would keep a registration alive with
    /// nothing behind it. The blocks hold `self` weakly, so the worst an
    /// un-stopped watcher costs is a registration, never a call into a freed
    /// object.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: Looking

    /// Every volume that is mounted now.
    ///
    /// The internal disk is left out: it is not a reader, it can never be
    /// ejected, and a profile could in principle match a folder layout
    /// somebody happens to have at the root of it.
    static func mountedVolumes() -> [MountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        ]
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        return urls.compactMap { url -> MountedVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let removable = (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false)
            guard removable, !(values.volumeIsInternal ?? false) else { return nil }
            return MountedVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                freeBytes: values.volumeAvailableCapacity.map(Int64.init),
                totalBytes: values.volumeTotalCapacity.map(Int64.init),
                isRemovable: true,
                fileSystem: fileSystemName(of: url))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The readers among them.
    static func connectedDevices(manual: [String: String] = [:]) -> [ConnectedDevice] {
        mountedVolumes().compactMap { volume in
            if let profile = DeviceDetection.profile(forVolumeAt: volume.url, name: volume.name) {
                return ConnectedDevice(volume: volume, profile: profile)
            }
            // A volume the user vouched for by hand, because its marker is not
            // there: "Treat this volume as device…" (CONCEPT §8.1).
            guard let id = manual[volume.url.path], let profile = DeviceProfiles.profile(id: id) else {
                return nil
            }
            return ConnectedDevice(volume: volume, profile: profile, wasChosenByHand: true)
        }
    }

    /// `msdos`, `exfat`, `apfs`, `hfs`.
    ///
    /// From `statfs`, not from `volumeLocalizedFormatDescriptionKey`: that one
    /// is *localized*, so on a German Mac it reads "MS-DOS (FAT32)" and on a
    /// Japanese one something else again. Deciding whether the 4 GB file-size
    /// limit applies off a translated string is the same class of defect as
    /// the smoke test reading "64,4" — see CLAUDE.md.
    static func fileSystemName(of url: URL) -> String? {
        var buffer = statfs()
        guard statfs(url.path, &buffer) == 0 else { return nil }
        return withUnsafeBytes(of: &buffer.f_fstypename) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Ejects a volume. Only ever called when no transfer is running — the
    /// check is the model's, because it is the model that knows (CONCEPT §8.4).
    static func eject(_ volume: URL) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }
}
