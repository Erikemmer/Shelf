import Foundation
import ShelfCore

/// Writes a PDF nobody wrote, for the tests and the proof run to read.
///
/// **In the core, although PDFs are *read* in the app layer.** That looks
/// backwards and is not: reading one needs PDFKit, which is Apple's, while
/// writing a minimal one needs nothing but bytes — a PDF is a text format with
/// a table of byte offsets at the end. Keeping the writer here means the proof
/// run can generate five hundred of them from `shelf-tool`, which is core-only
/// and has no PDFKit, and it means the Linux CI job builds it too.
///
/// What it writes is a real PDF: a catalogue, one page of a stated size with a
/// coloured rectangle drawn on it, and an Info dictionary holding Title,
/// Author, Subject and Keywords — the four fields `PDFFileReader` reads.
public struct SyntheticPDF: Sendable {
    public var book: Book
    /// Points, not pixels. 300 × 450 is a paperback's proportions.
    public var width: Int
    public var height: Int
    /// Leaves the Info dictionary out entirely, so the reader has to fall back
    /// to the file name — which is what most scanned PDFs look like.
    public var withoutInfo: Bool
    /// Writes the file's own name into the Title field, the way every "Print to
    /// PDF" does. It looks like metadata and is not.
    public var titleIsTheFileName: String?

    public init(
        book: Book, width: Int = 300, height: Int = 450, withoutInfo: Bool = false,
        titleIsTheFileName: String? = nil
    ) {
        self.book = book
        self.width = width
        self.height = height
        self.withoutInfo = withoutInfo
        self.titleIsTheFileName = titleIsTheFileName
    }

    public func data() -> Data {
        // A shade derived from the title, so two books do not look alike and
        // two runs of the generator produce the same file.
        let hash = book.title.utf8.reduce(UInt32(17)) { ($0 &* 31) &+ UInt32($1) }
        let red = Double((hash >> 16) & 0xFF) / 255
        let green = Double((hash >> 8) & 0xFF) / 255
        let blue = Double(hash & 0xFF) / 255

        let content = """
            \(format(red)) \(format(green)) \(format(blue)) rg
            20 20 \(width - 40) \(height - 40) re f
            """
        let contentBytes = Array(content.utf8)

        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] "
                + "/Contents 4 0 R /Resources << >> >>")
        objects.append("<< /Length \(contentBytes.count) >>\nstream\n\(content)\nendstream")
        if !withoutInfo { objects.append(infoDictionary()) }

        // The body, remembering where each object started: the cross-reference
        // table at the end is a list of byte offsets, and a PDF whose offsets
        // are wrong is one most readers will still open and some will not.
        var out = Array("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }

        let xrefOffset = out.count
        let count = objects.count + 1
        out += Array("xref\n0 \(count)\n".utf8)
        // Object 0 is always the head of the free list, exactly this line.
        out += Array("0000000000 65535 f \n".utf8)
        for offset in offsets {
            out += Array(String(format: "%010d 00000 n \n", offset).utf8)
        }

        var trailer = "trailer\n<< /Size \(count) /Root 1 0 R"
        if !withoutInfo { trailer += " /Info \(objects.count) 0 R" }
        trailer += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out += Array(trailer.utf8)
        return Data(out)
    }

    private func infoDictionary() -> String {
        var fields: [String] = []
        fields.append("/Title \(pdfString(titleIsTheFileName ?? book.title))")
        if !book.authors.isEmpty {
            // One string however many authors, joined the way a real PDF does
            // it and the way `AuthorField` splits it back.
            fields.append("/Author \(pdfString(book.authors.joined(separator: " & ")))")
        }
        if let description = book.description { fields.append("/Subject \(pdfString(description))") }
        if !book.tags.isEmpty { fields.append("/Keywords \(pdfString(book.tags.joined(separator: ", ")))") }
        fields.append("/Producer \(pdfString("Shelf synthetic test material"))")
        return "<< \(fields.joined(separator: " ")) >>"
    }

    /// One PDF text string, in whichever of the format's two spellings it needs.
    ///
    /// **This is not decoration, and it was found by reading a generated file
    /// back through PDFKit.** A literal `(…)` string in a PDF is *not* UTF-8:
    /// the format reads it as PDFDocEncoding, a Latin-1 variant. Writing the
    /// UTF-8 bytes of "Lefèvre" into one therefore produces "LefÃ¨vre" when
    /// anything reads it — mojibake that looks like a bug in the reader and is
    /// a bug in the writer.
    ///
    /// The format's own answer is a hex string beginning with the byte-order
    /// mark `FEFF`, whose contents are UTF-16BE. ASCII goes in as a literal,
    /// which keeps the file readable in a text editor; anything else goes in as
    /// hex.
    private func pdfString(_ text: String) -> String {
        let isPlainASCII = text.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 }
        guard isPlainASCII else {
            var bytes: [UInt8] = [0xFE, 0xFF]
            for unit in Array(text.utf16) {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            return "<\(bytes.map { String(format: "%02X", $0) }.joined())>"
        }
        return "(\(escaped(text)))"
    }

    /// `(`, `)` and `\` are the three characters a PDF literal string cannot
    /// hold plainly. Everything else goes in as it is.
    private func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    /// Three decimal places, in the C locale. A German Mac would otherwise
    /// write "0,53" into the page's content stream and no reader would open it
    /// — the same lesson the smoke test learned from `ps`.
    private func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
