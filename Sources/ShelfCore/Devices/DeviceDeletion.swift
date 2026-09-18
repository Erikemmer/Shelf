import Foundation

/// Deleting files from a device — the one destructive thing Shelf does, and
/// the only one that needs a sentence of its own
/// ([ADR 0014](../../../docs/adr/0014-deleting-on-a-device-needs-a-named-confirmation.md)).
///
/// Three rules, and they are structural rather than a matter of care:
///
/// * **Only from a menu item of its own.** Nothing here is reachable from a
///   transfer, a refresh or a reconnect. A deletion that is a side effect of a
///   sync is how people lose books they never chose to lose (CONCEPT §8.3).
/// * **Only after a confirmation that names every file.** `Confirmation` is
///   that text, it is built here, and it is what the test checks — a dialog
///   saying "Delete 214 files?" names nothing and can be agreed to by accident.
/// * **The library is never touched.** This type cannot reach it: it takes
///   device paths and a volume, and has no library to touch.
public enum DeviceDeletion {

    /// What the dialog says, built from the files themselves.
    public struct Confirmation: Equatable, Sendable {
        public var deviceName: String
        public var files: [DeviceFile]
        /// Title per book id, so a file can be named by its book as well as by
        /// its file name.
        public var titles: [UUID: String]

        public init(deviceName: String, files: [DeviceFile], titles: [UUID: String] = [:]) {
            self.deviceName = deviceName
            self.files = files
            self.titles = titles
        }

        public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteSize } }

        public var question: String {
            "Delete \(files.count) file\(files.count == 1 ? "" : "s") from “\(deviceName)”?"
        }

        /// The sentence under the question. It says what will *not* happen as
        /// plainly as what will: the fear this dialog has to answer is "will
        /// this take the book out of my library too".
        public var explanation: String {
            "\(ByteCount.format(totalBytes)) will be removed from the device. "
                + "Your library is not touched — the books stay in it, and can be sent again."
        }

        /// Every file, by name, with the book it belongs to when that is
        /// known. This is the list the dialog shows in full; it is not
        /// summarised and it is not truncated, because a name nobody can see
        /// is a file nobody agreed to.
        public var lines: [String] {
            files.map { file in
                guard let id = file.bookID, let title = titles[id] else { return file.path }
                return "\(file.path)  —  \(title)"
            }
        }
    }

    /// What happened.
    public struct Outcome: Equatable, Sendable {
        public var deleted: [String]
        /// Path → why not.
        public var failed: [String: String]

        public init(deleted: [String] = [], failed: [String: String] = [:]) {
            self.deleted = deleted
            self.failed = failed
        }

        public var summary: String {
            failed.isEmpty
                ? "Deleted \(deleted.count) file\(deleted.count == 1 ? "" : "s") from the device."
                : "Deleted \(deleted.count) of \(deleted.count + failed.count) files; \(failed.count) could not be removed."
        }
    }

    /// Removes the named files from the volume, and takes them out of the
    /// manifest.
    ///
    /// A path that tries to leave the volume is refused rather than followed:
    /// the paths come from a listing of the device, but a manifest is a file
    /// on a card somebody else may have written, and `..` in it must not reach
    /// the library.
    public static func delete(
        _ files: [DeviceFile], fromVolume volume: URL, manifest: inout DeviceManifest
    ) -> Outcome {
        var outcome = Outcome()
        for file in files {
            guard let url = safeURL(for: file.path, on: volume) else {
                outcome.failed[file.path] = "the path points outside the device"
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                outcome.deleted.append(file.path)
            } catch {
                outcome.failed[file.path] = (error as NSError).localizedDescription
            }
        }
        manifest.forget(paths: outcome.deleted)
        return outcome
    }

    /// A path on the volume, or nothing when it would escape it.
    static func safeURL(for path: String, on volume: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let url = volume.appendingPathComponent(path).standardizedFileURL
        let root = volume.standardizedFileURL.path
        guard url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return url
    }
}
