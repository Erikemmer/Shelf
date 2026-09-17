import AppKit
import Foundation
import PDFKit
import ShelfCore

/// Reads a PDF: `documentAttributes` for the metadata, page 1 rendered for the
/// cover.
///
/// **In the app layer, and not in the core**, because PDFKit is Apple's and the
/// core builds on Linux — the CI job is what enforces that rather than good
/// intentions (CONCEPT §10). What is *not* here is the rules: what an empty
/// title means, what happens when the author field holds a producer's name, and
/// the fall back to the file name are all `BookFileReader`'s and
/// `FileNameMetadata`'s, in the core, where they are tested on both platforms.
/// This file is the part that needs a Mac and nothing else.
enum PDFFileReader {

    /// How big the rendered cover is, on its longest side.
    ///
    /// 1 000 px, which is `CoverCacheKey.large` — the size the inspector wants.
    /// Rendering the page at its natural size would give a 3 500 px bitmap for
    /// an A4 scan, which is four times the pixels for no visible gain and four
    /// times the memory during an import of a thousand of them.
    static let coverPixels: CGFloat = 1_000

    /// What PDF metadata calls the fields Shelf models. A table, because
    /// PDFKit's keys are not the ones the rest of the program uses.
    static let titleKey = PDFDocumentAttribute.titleAttribute
    static let authorKey = PDFDocumentAttribute.authorAttribute
    static let subjectKey = PDFDocumentAttribute.subjectAttribute
    static let keywordsKey = PDFDocumentAttribute.keywordsAttribute
    static let creationKey = PDFDocumentAttribute.creationDateAttribute

    /// Producer names that turn up in the Author field of scanned and exported
    /// PDFs. Taking one of these as the author files a thousand books under
    /// "Microsoft Word", which is worse than filing them under nothing.
    ///
    /// Reference data: a new one is a row. Matched case-insensitively against
    /// the whole field, not as a substring — "Adobe Kirkpatrick" is a person.
    static let producerNames: Set<String> = [
        "microsoft word", "microsoft® word", "word", "adobe acrobat", "acrobat distiller",
        "adobe indesign", "indesign", "pdflatex", "latex", "libreoffice", "openoffice",
        "pages", "quartz pdfcontext", "unknown", "administrator", "user", "scanner",
        "canon", "hp scan", "epson scan", "calibre", "ghostscript", "tcpdf", "fpdf",
    ]

    static func read(url: URL, readCover: Bool = true) -> BookFileReader.Result {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let document = PDFDocument(url: url) else {
            return BookFileReader.fromName(
                stem, warning: "the PDF could not be opened – the metadata comes from the file name")
        }

        var warnings: [String] = []

        // A PDF can be encrypted, and that is DRM as far as Shelf is concerned:
        // it is recognised, badged and left alone. Nothing here unlocks
        // anything, not even with an empty password (CONCEPT §12, ADR 0012).
        let drm: DRMKind? = document.isEncrypted || document.isLocked ? .unknown : nil
        if drm != nil {
            warnings.append("the PDF is encrypted – it is badged and otherwise left alone")
        }

        let attributes = document.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String? {
            let value = (attributes[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }

        // The file name wins over an empty title, and over a title that is just
        // the file name with a `.pdf` on it — which is what every "Print to
        // PDF" writes, and which would otherwise look like metadata.
        var book: Book
        var fromTheFile = false
        if let title = text(titleKey), !isJustTheFileName(title, stem: stem) {
            book = Book(title: title)
            fromTheFile = true
        } else {
            book = Book(title: FileNameMetadata.title(from: stem))
            warnings.append("no usable title in the PDF – taken from the file name")
        }

        if let author = text(authorKey), !producerNames.contains(author.lowercased()) {
            // A PDF's Author field is one string, however many people wrote the
            // book. The separators are the same ones a MOBI uses.
            book.authors = AuthorField.split(author)
            fromTheFile = true
        } else {
            let guessed = FileNameMetadata.authors(from: stem)
            if !guessed.isEmpty {
                book.authors = guessed
            } else if text(authorKey) != nil {
                warnings.append("the PDF's author field names the program that made it, not a person")
            }
        }

        book.titleSort = TitleSort.of(book.title)
        book.description = text(subjectKey)
        book.published = attributes[creationKey] as? Date
        if let keywords = text(keywordsKey) {
            book.tags = Set(
                keywords.split(whereSeparator: { $0 == "," || $0 == ";" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            ).sorted()
        }

        var cover: Data?
        var coverName: String?
        if readCover {
            cover = renderFirstPage(of: document)
            coverName = cover.map { CoverFile.name(for: $0) }
            if cover == nil {
                warnings.append(
                    drm == nil
                        ? "page 1 could not be rendered – the book has no cover"
                        : "page 1 could not be rendered – the PDF is encrypted")
            }
        }

        return BookFileReader.Result(
            book: book, cover: cover, coverName: coverName, drm: drm, warnings: warnings,
            fromTheFile: fromTheFile)
    }

    /// Whether a PDF's Title is really just its file name.
    ///
    /// "Print to PDF" and half the export paths on a Mac write the file's own
    /// name into the Title field, sometimes with the extension still on it. It
    /// looks like metadata and is not, and taking it means the file-name rules
    /// — which strip the shop's prefix and split author from title — never run.
    static func isJustTheFileName(_ title: String, stem: String) -> Bool {
        let fold: (String) -> String = {
            $0.lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ").joined(separator: " ")
        }
        let folded = fold(title)
        return folded == fold(stem) || folded == fold(stem + ".pdf")
    }

    /// Page 1, rendered to PNG.
    ///
    /// PNG rather than JPEG, unlike the cover *cache*: this is the original a
    /// book's `cover.png` is written from and it is written once, where the
    /// cache is written per book per size. A page of black text on white is
    /// also exactly the image JPEG is worst at.
    static func renderFirstPage(of document: PDFDocument) -> Data? {
        guard document.pageCount > 0, let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale = coverPixels / max(bounds.width, bounds.height)
        let size = NSSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return nil }

        let image = page.thumbnail(of: size, for: .cropBox)
        guard let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }
}
