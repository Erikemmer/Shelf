import Foundation

/// The EPUB-specific layer over `ZipArchiveWriter`: the rules the ZIP format
/// itself knows nothing about, which are that `mimetype` must be the first
/// entry and it must be stored, not deflated.
///
/// `ZipArchiveWriter` no longer stores every entry unconditionally — a
/// `.passthrough` entry carries a source archive's own method forward
/// unchanged, which is what keeps a book's own text and images from being
/// decompressed and stored back at roughly 2.7 times their size. That is
/// also what makes "stored" no longer automatic for `mimetype`: a source
/// archive could, in principle, have written it deflated, and passing that
/// forward unexamined would produce an EPUB no real reader accepts. Both
/// rules are checked here, explicitly, rather than relied on as something
/// the writer beneath happens to always do.
///
/// "No extra field" needs no check of its own: `ZipArchiveWriter` never
/// writes one for any entry, `.raw` or `.passthrough` alike — it does not
/// carry a source entry's extra field forward, it does not have a way to
/// write one for a `.raw` entry, so there is nothing here that could vary.
///
/// This writes an archive; it does not yet decide what goes into one. The
/// command that will use it – "write this book's metadata into its EPUB" –
/// is not part of this type and does not exist yet (`docs/adr/0021-…`).
public enum EPUBArchiveWriter {
    public static let mimetypePath = "mimetype"

    public enum Failure: Error, Equatable {
        /// `mimetype` was not the first entry, or was not present at all.
        case mimetypeMustBeFirst
        /// `mimetype` was first, but not stored.
        case mimetypeMustBeStored
        /// `mimetype` appeared more than once.
        case duplicateMimetype
        /// An entry from a source archive is ZIP-encrypted. Copying it
        /// forward without the ability to decrypt or re-encrypt it would
        /// write bytes that look intact and are not; refusing is the only
        /// honest option.
        case encryptedEntry(String)
        /// An entry's bytes do not match the CRC its own source archive
        /// recorded for it. The source archive is corrupt, and carrying a
        /// mismatched entry forward would just move the corruption into a
        /// second file.
        case corruptSourceEntry(String)
    }

    /// The archive's bytes, or a named refusal – either this type's own, or
    /// `ZipArchiveWriter.Failure` for a limit at the ZIP level.
    public static func archive(_ entries: [ZipArchiveWriter.Entry]) throws -> Data {
        guard let first = entries.first, first.path == mimetypePath else {
            throw Failure.mimetypeMustBeFirst
        }
        guard first.isStored else { throw Failure.mimetypeMustBeStored }
        guard !entries.dropFirst().contains(where: { $0.path == mimetypePath }) else {
            throw Failure.duplicateMimetype
        }
        return try ZipArchiveWriter().archive(entries)
    }

    /// Every entry of an existing archive, carried forward as
    /// `.passthrough` — compressed bytes and all, never decompressed and
    /// never recompressed — as input for `archive`.
    ///
    /// This is the round trip this type is proven against: read with
    /// `ZipReader`, hand every entry straight back to `archive` unchanged,
    /// read the result again. Nothing here changes a path, reorders an entry
    /// or looks at what an entry contains – that is Sprint 10's job, once it
    /// exists, working with what this returns rather than inside it.
    ///
    /// Each entry is still decompressed once, here, but only to check its
    /// CRC against what the source archive's own central directory claims
    /// for it — the same check unpacking used to give for free when this
    /// type wrote decompressed bytes back out. Checking it explicitly is
    /// what keeps that guarantee now that the bytes actually written are the
    /// *compressed* ones, which this check never touches.
    public static func entries(rewriting archive: ZipReader) throws -> [ZipArchiveWriter.Entry] {
        try archive.entries.map { entry in
            guard !entry.isEncrypted else { throw Failure.encryptedEntry(entry.path) }
            let decompressed = try archive.data(for: entry)
            guard ZipCRC32.of(decompressed) == entry.crc32 else {
                throw Failure.corruptSourceEntry(entry.path)
            }
            return ZipArchiveWriter.Entry.passthrough(
                path: entry.path, compressedData: try archive.compressedData(for: entry), method: entry.method,
                uncompressedSize: entry.uncompressedSize, crc32: entry.crc32, modTime: entry.modTime,
                modDate: entry.modDate)
        }
    }
}
