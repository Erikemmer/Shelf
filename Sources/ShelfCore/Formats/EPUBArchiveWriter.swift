import Foundation

/// The EPUB-specific layer over `ZipArchiveWriter`: the one rule the ZIP
/// format itself knows nothing about, which is that an EPUB's `mimetype`
/// entry must be first.
///
/// Everything else the format asks of `mimetype` – stored, not deflated, no
/// extra field – is already true of *every* entry `ZipArchiveWriter` writes,
/// because it never deflates and never writes an extra field for anything.
/// The one thing left to enforce is position, so that is the one thing this
/// type checks.
///
/// This writes an archive; it does not yet decide what goes into one. The
/// command that will use it – "write this book's metadata into its EPUB" –
/// is not part of this type and does not exist yet (`docs/adr/0021-…`).
public enum EPUBArchiveWriter {
    public static let mimetypePath = "mimetype"

    public enum Failure: Error, Equatable {
        /// `mimetype` was not the first entry, or was not present at all.
        case mimetypeMustBeFirst
        /// `mimetype` appeared more than once.
        case duplicateMimetype
        /// An entry from a source archive is ZIP-encrypted. Copying it
        /// forward without the ability to decrypt or re-encrypt it would
        /// write bytes that look intact and are not; refusing is the only
        /// honest option.
        case encryptedEntry(String)
    }

    /// The archive's bytes, or a named refusal – either this type's own, or
    /// `ZipArchiveWriter.Failure` for a limit at the ZIP level.
    public static func archive(_ entries: [ZipArchiveWriter.Entry]) throws -> Data {
        guard entries.first?.path == mimetypePath else { throw Failure.mimetypeMustBeFirst }
        guard !entries.dropFirst().contains(where: { $0.path == mimetypePath }) else {
            throw Failure.duplicateMimetype
        }
        return try ZipArchiveWriter().archive(entries)
    }

    /// Every entry of an existing archive, verbatim, as input for `archive`.
    ///
    /// This is the round trip this type is proven against: read with
    /// `ZipReader`, decompress each entry, hand the same names and the same
    /// bytes back to `archive`. Nothing here changes a path, reorders an
    /// entry or looks at what an entry contains – that is Sprint 10's job,
    /// once it exists, working with what this returns rather than inside it.
    public static func entries(rewriting archive: ZipReader) throws -> [ZipArchiveWriter.Entry] {
        try archive.entries.map { entry in
            guard !entry.isEncrypted else { throw Failure.encryptedEntry(entry.path) }
            return ZipArchiveWriter.Entry(path: entry.path, data: try archive.data(for: entry))
        }
    }
}
