import Foundation

/// One book file found on a device.
public struct DeviceFile: Equatable, Sendable, Identifiable {
    /// Relative to the volume root.
    public var path: String
    public var format: BookFileFormat
    public var byteSize: Int64
    public var modifiedAt: Date
    /// The library book it belongs to, once matching has run.
    public var bookID: UUID?
    /// How that was decided. Shown in the delete confirmation, because
    /// "matched by name" and "matched by digest" are different claims.
    public var matchedBy: Match?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public enum Match: String, Equatable, Sendable {
        /// The manifest Shelf wrote when it sent the file. The digest in it
        /// was read back off the device, so this is as strong as it gets.
        case manifest
        /// The file is called exactly what Shelf would have called this book.
        /// Weaker, and the only thing available for a book somebody else put
        /// on the card.
        case name

        public var label: String {
            switch self {
            case .manifest: return "sent by Shelf"
            case .name: return "matched by name"
            }
        }
    }

    public init(
        path: String, format: BookFileFormat, byteSize: Int64, modifiedAt: Date = Date(),
        bookID: UUID? = nil, matchedBy: Match? = nil
    ) {
        self.path = path
        self.format = format
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
        self.bookID = bookID
        self.matchedBy = matchedBy
    }
}

/// What is on a device, and which of the library's books it is.
///
/// Two rules, strongest first, and **no hashing**. Hashing a 32 GB card to draw
/// a badge in the grid would make plugging a reader in a two-minute operation;
/// the manifest already holds a digest that was read back off the device when
/// the file was written, which is better evidence than a hash taken now would
/// be and costs nothing. What the manifest does not cover — a book somebody
/// else put on the card — is matched by the name Shelf would have given it.
public enum DeviceContents {

    /// Lists the book files under a device's books folder.
    ///
    /// Only formats the profile claims, so a `.txt` note and the reader's own
    /// dictionaries are not offered as books. Shelf's own `.shelf/` folder is
    /// skipped; so are the reader's hidden folders, which on a Kobo hold tens
    /// of thousands of files.
    public static func list(on device: ConnectedDevice) -> [DeviceFile] {
        let manager = FileManager.default
        let root = device.booksFolder
        // `enumerator(atPath:)` rather than `enumerator(at:)`, because it
        // yields paths **relative to the folder it was given** and the URL
        // form does not.
        //
        // Deriving the relative path by taking the volume's path off the front
        // of an absolute one looks obvious and does not work: the URL
        // enumerator resolves symlinks, so a volume under `/var` comes back as
        // `/private/var/…`, and `resolvingSymlinksInPath()` cannot be used to
        // meet it half way because Foundation strips the `/private` prefix
        // again as a special case. The first version of this listed every file
        // on the device and then discarded all of them, and a test is where
        // that was found.
        guard let walker = manager.enumerator(atPath: root.path) else { return [] }

        var found: [DeviceFile] = []
        while let relative = walker.nextObject() as? String {
            // A reader's own folders hold tens of thousands of files and not
            // one book: `.kobo/` alone has the database, the covers and the
            // dictionaries. Nothing hidden is descended into, which also keeps
            // Shelf's own `.shelf/` out of the listing.
            if (relative as NSString).lastPathComponent.hasPrefix(".") {
                walker.skipDescendants()
                continue
            }
            let url = root.appendingPathComponent(relative)
            guard let format = BookFileFormat.of(url), device.profile.accepts(format) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            found.append(
                DeviceFile(
                    path: onVolume(relative, in: device.profile.booksFolder), format: format,
                    byteSize: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate ?? Date()))
        }
        return found.sorted { $0.path < $1.path }
    }

    /// A path inside the books folder, said as a path on the volume — which is
    /// what the manifest stores and what deleting takes.
    static func onVolume(_ relative: String, in booksFolder: String) -> String {
        booksFolder.isEmpty ? relative : "\(booksFolder)/\(relative)"
    }

    /// Attaches a library book to each file it can.
    ///
    /// Pure, so the whole rule is tested without a device.
    public static func matched(
        _ files: [DeviceFile], to entries: [LibraryEntry], manifest: DeviceManifest,
        profile: DeviceProfile
    ) -> [DeviceFile] {
        // The names Shelf would give every book of the library, for the weaker
        // of the two rules. Built once: doing it per file would be a full pass
        // over the library for each of a few thousand files.
        var byName: [String: UUID] = [:]
        for entry in entries {
            for format in Set(entry.formats.map(\.format)) where profile.accepts(format) {
                let name = DeviceFileName.of(entry.book, format: format, pattern: profile.fileNamePattern)
                // First one wins and is not overwritten: two library books that
                // would be called the same on the card cannot be told apart by
                // name, and guessing between them would put the wrong badge on
                // one of them. The manifest is what resolves such a pair.
                if byName[name.lowercased()] == nil { byName[name.lowercased()] = entry.id }
            }
        }

        return files.map { file in
            var file = file
            if let row = manifest.entry(at: file.path) {
                file.bookID = row.bookID
                file.matchedBy = .manifest
            } else if let id = byName[file.name.lowercased()] {
                file.bookID = id
                file.matchedBy = .name
            }
            return file
        }
    }

    /// The books of the library that are on this device — what the grid badges.
    public static func booksOnDevice(_ files: [DeviceFile]) -> Set<UUID> {
        Set(files.compactMap(\.bookID))
    }
}
