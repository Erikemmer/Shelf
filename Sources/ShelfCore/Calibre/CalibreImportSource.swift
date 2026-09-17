import Foundation

/// Turns a Calibre library into the candidates the ordinary importer already
/// knows how to plan and run.
///
/// There is no second import here, and that is the point. `ImportPlanner`,
/// `ImportRunner` and `ImportReport` were built in Sprint 1 and proved against
/// 5 000 books; a Calibre import is the same copy-verify-then-trust run with a
/// better source of metadata (ADR 0002). What this type adds is the reading —
/// which file belongs to which book, what that book knows about itself, and
/// what could not be found — and nothing else.
public struct CalibreImportSource: Sendable {
    private let makeHasher: HasherFactory

    public init(makeHasher: @escaping HasherFactory) {
        self.makeHasher = makeHasher
    }

    /// What reading the source produced, besides the candidates.
    public struct Result: Sendable {
        public var candidates: [ImportCandidate]
        /// Files the database lists that the disk has not got, as relative
        /// paths. They go into the report; they are never a reason to stop.
        public var missingFiles: [String]
        /// Formats Calibre holds that Shelf does not import, by Calibre's name.
        public var skippedFormats: [String: Int]

        public init(
            candidates: [ImportCandidate] = [], missingFiles: [String] = [],
            skippedFormats: [String: Int] = [:]
        ) {
            self.candidates = candidates
            self.missingFiles = missingFiles
            self.skippedFormats = skippedFormats
        }
    }

    /// Reads every file the library lists, hashing as it goes.
    ///
    /// The hash is taken here rather than in the runner because the *plan*
    /// needs it: duplicate detection is by content first, and the counting
    /// protocol the user agrees to is that plan (ADR 0002, decision 6). It is
    /// the expensive part of a dry run on a large library, and the sheet says
    /// so while it works.
    public func read(
        _ library: CalibreLibrary,
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) -> Result {
        var result = Result()
        let total = library.books.reduce(0) { $0 + $1.files.count }
        var done = 0

        for entry in library.books {
            let cover = coverData(for: entry, in: library.folder)
            for file in entry.files {
                done += 1
                progress(done, total)
                guard let format = file.format else {
                    result.skippedFormats[file.calibreFormat.uppercased(), default: 0] += 1
                    continue
                }
                let url = library.folder.appending(path: file.relativePath)
                guard let facts = FileFacts.of(url) else {
                    result.missingFiles.append(file.relativePath)
                    continue
                }
                guard let digest = try? FileDigest.sha256(of: url, makeHasher: makeHasher) else {
                    result.missingFiles.append(file.relativePath)
                    continue
                }
                var warnings = entry.warnings
                if !entry.claimsCover { warnings.append("no cover in the Calibre library") }
                // Calibre's `data.uncompressed_size` is what the library
                // *believes*. A difference is not an error — Calibre records the
                // size at the time it added the file — but it is worth saying,
                // because it is the one cheap sign that a folder was edited
                // behind Calibre's back.
                if file.claimedSize > 0, file.claimedSize != facts.byteSize {
                    warnings.append(
                        "metadata.db says \(ByteCount.format(file.claimedSize)), the file is "
                            + ByteCount.format(facts.byteSize))
                }

                result.candidates.append(
                    ImportCandidate(
                        source: url,
                        byteSize: facts.byteSize,
                        format: format,
                        sha256: digest,
                        // Calibre's own metadata, not the file's. The database is
                        // what the user has been curating for years; the EPUB
                        // inside it may still say whatever the shop wrote in 2011.
                        book: entry.book,
                        cover: cover,
                        coverName: cover.map(CoverFile.name(for:)),
                        modifiedAt: facts.modifiedAt,
                        warnings: warnings))
            }
        }
        return result
    }

    /// Calibre keeps one `cover.jpg` per book folder, whatever the bytes are.
    ///
    /// Taken from there rather than out of the book file, because it is the
    /// cover the *user* chose: somebody who replaced a bad cover in Calibre did
    /// it here, and reading the EPUB again would quietly undo that.
    /// `CoverFile.name(for:)` then names the file after what the bytes actually
    /// are, which is why a Calibre PNG called `cover.jpg` arrives as `cover.png`.
    func coverData(for entry: CalibreBook, in folder: URL) -> Data? {
        guard entry.claimsCover, !entry.folder.isEmpty else { return nil }
        let url = folder.appending(path: entry.folder).appending(path: "cover.jpg")
        return try? Data(contentsOf: url)
    }
}
