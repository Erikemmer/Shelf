import Foundation
import ShelfCore

/// The app's half of reading a book file.
///
/// `BookFileReader` in the core handles everything that can be read on Linux —
/// EPUB, KEPUB, MOBI, AZW3, CBZ. Two formats cannot be: PDF needs PDFKit and
/// CBR needs libarchive's RAR reader, and both are Apple's. They are filled in
/// here, and the choice is made by the same table the core uses
/// (`BookFileFormat.readerLayer`) rather than by a second list that could drift
/// out of step with it.
///
/// One function, because the importer should not have to know any of this.
enum FileReader {

    static func read(url: URL, format: BookFileFormat, readCover: Bool = true) -> BookFileReader.Result {
        switch format.readerLayer {
        case .core, .none:
            return BookFileReader.read(url: url, format: format, readCover: readCover)
        case .app:
            switch format {
            case .pdf: return PDFFileReader.read(url: url, readCover: readCover)
            case .cbr: return CBRFileReader.read(url: url, readCover: readCover)
            default:
                // A format the table calls `.app` that nothing here answers is
                // a mistake in the table, not a file to guess at. It still
                // yields a book, and it says so out loud.
                return BookFileReader.fromName(
                    url.deletingPathExtension().lastPathComponent,
                    warning: "\(format.label) has no reader in the app layer – the file name is all Shelf has")
            }
        }
    }
}
