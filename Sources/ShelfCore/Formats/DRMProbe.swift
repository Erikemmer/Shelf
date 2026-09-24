import Foundation

/// Asks one question of a file: is it protected, and by what.
///
/// It exists because of a defect the Sprint 4 proof run found. The importer
/// detected DRM perfectly well and stored it, and then
/// `Library ▸ Rebuild Index from Folders` set it back to nothing: nine
/// protected files in the measuring library, nine badges, and after a rebuild
/// zero. Nothing failed and nothing was logged. The index is a cache and may be
/// thrown away at any time (ADR 0001) — so anything the index knows has to be
/// re-derivable from the folder, and the DRM flag was not.
///
/// The answer therefore comes from the **file**, every time, rather than from
/// something remembered about it. That has a second, better consequence: a file
/// whose protection is gone stops being badged, because the badge is a fact
/// about the bytes and not a note somebody once made.
///
/// It is deliberately cheap. Reading the whole book to find one flag would make
/// a rebuild of 8 000 files minutes longer, so each format is asked in the
/// narrowest way it can be asked: an EPUB for one entry in its central
/// directory, a MOBI for record 0, a PDF for the tail of the file.
public enum DRMProbe {

    /// What protects this file, or nil.
    ///
    /// Never throws. A file that cannot be read is not "protected", it is
    /// unreadable, and saying otherwise would badge every damaged download.
    public static func drm(of url: URL, format: BookFileFormat) -> DRMKind? {
        switch format {
        case .epub, .kepub:
            guard let archive = try? ZipReader(url: url) else { return nil }
            // Its presence is the whole signal. What is inside it names the
            // scheme and the key holder, and Shelf has no use for either.
            return archive.entry(at: EPUBMetadata.encryptionPath) != nil ? .adobeADEPT : nil

        case .mobi, .azw3:
            guard let data = try? Data(contentsOf: url),
                let database = try? PalmDatabase(bytes: Array(data)),
                let record0 = database.record(0),
                let header = try? MobiHeader(record0: record0)
            else { return nil }
            // EXTH 209 is the announcement; the PalmDOC encryption byte is the
            // fact. Either one is enough.
            return header.exth[MobiMetadata.EXTH.tamperProofKeys] != nil || header.encryptionType != 0
                ? .kindle : nil

        case .pdf:
            return pdfIsEncrypted(url) ? .unknown : nil

        case .cbz, .cbr:
            // A comic archive is opened; it carries no protection scheme
            // Shelf recognises. Examined, not skipped – `nil` here is a
            // real answer.
            return nil

        case .kfx:
            // Not opened at all – `BookFileFormat.drmIsExaminable` is false
            // for exactly this reason. This `nil` means "not examined", not
            // "no DRM" (Sprint 17, Teil A).
            return nil
        }
    }

    /// How much of a PDF's tail is read looking for `/Encrypt`.
    ///
    /// The trailer is at the end of the file by construction, and 8 KB is far
    /// more than any trailer. Reading the whole of a 400 MB scan to answer one
    /// question is what this number exists to avoid.
    static let pdfTailBytes = 8 * 1024

    /// Whether a PDF declares an `/Encrypt` dictionary.
    ///
    /// **A heuristic, and named as one.** An encrypted PDF names `/Encrypt` in
    /// its trailer, and the trailer is at the end — so the tail of the file is
    /// where the answer is. What this cannot see is a cross-reference *stream*
    /// whose dictionary is compressed, which is why the app layer asks PDFKit
    /// instead at import time and PDFKit's answer is the one stored. This is
    /// the rebuild's answer, and the rebuild runs where PDFKit may not exist.
    ///
    /// Erring towards "not protected" is deliberate: a badge that is missing is
    /// a smaller wrong than a badge on a file that is perfectly readable.
    static func pdfIsEncrypted(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return false }
        let start = size > UInt64(pdfTailBytes) ? size - UInt64(pdfTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let tail = try? handle.readToEnd(), !tail.isEmpty
        else { return false }

        // Latin-1, because the tail is bytes and may hold anything; the marker
        // being looked for is ASCII either way.
        let text = String(decoding: tail, as: UTF8.self)
        return text.contains("/Encrypt")
    }
}
