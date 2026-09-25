import Foundation

/// Whether `metadata.db` is actually there to be read — Teil B4's own
/// gate before a Calibre folder chosen through the Open dialog is ever
/// handed to `CalibreReader`.
///
/// **Resource *values* only, never the file's contents.** A cloud-sync
/// placeholder (iCloud Drive, Dropbox, a third-party File Provider such as
/// Synology Drive — all of them live under `~/Library/CloudStorage/` since
/// macOS unified them onto one framework) starts a download the moment
/// something actually *reads* it, and CLAUDE.md is explicit that choosing
/// this folder must never trigger one. `URLResourceKey.fileSizeKey` and the
/// ubiquitous-item keys describe a file without opening it, which is the
/// whole reason this check is safe to run on every folder the panel offers.
///
/// The ubiquitous-item keys are Apple's own (`EmptiedFolder.trash` is the
/// same `#if os(macOS)` shape, for the same reason: nothing here has a
/// meaning on Linux, where there is no cloud-storage daemon to ask).
public enum CalibreSourceAvailability {
    public enum Status: Equatable, Sendable {
        /// Fully present, and safe to hand to `CalibreReader`.
        case available
        /// Present in name, but a cloud-sync placeholder — not fully
        /// downloaded, so nothing here reads it.
        case placeholder
        /// No `metadata.db` at this path at all, or its resource values
        /// could not be read.
        case missing
    }

    public static func status(ofMetadataDB folder: URL) -> Status {
        let url = folder.appendingPathComponent("metadata.db")
        #if os(macOS)
            guard
                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                ])
            else { return .missing }
            if values.isUbiquitousItem == true {
                // `.current` is the only status that means "the bytes are
                // already on this disk". `.downloaded` (present, but a newer
                // version exists in the cloud) and `.notDownloaded` are both
                // a placeholder as far as a safe, no-download read is
                // concerned.
                if values.ubiquitousItemDownloadingStatus != .current { return .placeholder }
            }
            guard let size = values.fileSize, size > 0 else { return .missing }
            return .available
        #else
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                let size = values.fileSize, size > 0
            else { return .missing }
            return .available
        #endif
    }
}
