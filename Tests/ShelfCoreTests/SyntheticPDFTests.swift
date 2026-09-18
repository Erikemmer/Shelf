import Foundation
import Testing

@testable import ShelfCore

/// The PDF *writer*, which lives in the core although PDFs are read in the app
/// layer.
///
/// That split is the reason these tests exist at all. The reader needs PDFKit
/// and so cannot be tested here or on Linux; the writer needs nothing but
/// bytes, and it is what five hundred files of the proof run are made with — so
/// if it writes a malformed PDF, the proof run measures the fallback path and
/// reports a success that means nothing.
///
/// What is checked here is structure, because that is what can be checked
/// without a PDF reader. That PDFKit actually opens these files is checked in
/// the proof run, on a Mac, and the numbers are in the CHANGELOG.
@Suite("Writing a PDF")
struct SyntheticPDFTests {

    private func text(of pdf: Data) -> String {
        // Latin-1 rather than UTF-8: a PDF is bytes, and decoding it as UTF-8
        // would fail on the very hex strings these tests are about.
        String(decoding: pdf, as: UTF8.self)
    }

    @Test("it has the header, a catalogue, one page and the trailer")
    func structure() {
        let pdf = SyntheticPDF(book: Book(title: "Emma", authors: ["Jane Austen"])).data()
        let content = text(of: pdf)

        #expect(content.hasPrefix("%PDF-1.4"))
        #expect(content.contains("/Type /Catalog"))
        #expect(content.contains("/Type /Pages"))
        #expect(content.contains("/Count 1"))
        #expect(content.contains("/MediaBox [0 0 300 450]"))
        #expect(content.contains("startxref"))
        #expect(content.hasSuffix("%%EOF\n"))
    }

    /// The cross-reference table is a list of byte offsets, and a PDF whose
    /// offsets are wrong is one most readers open and some do not. Checked by
    /// following each offset and seeing whether the object really starts there.
    @Test("every cross-reference offset points at the object it claims")
    func xrefOffsetsAreRight() throws {
        let pdf = SyntheticPDF(
            book: Book(title: "The Fifth Season", authors: ["N. K. Jemisin"], tags: ["hugo"])
        ).data()
        let bytes = [UInt8](pdf)
        let content = text(of: pdf)

        let startxref = try #require(content.range(of: "startxref\n"))
        let tail = content[startxref.upperBound...]
        let offset = try #require(Int(tail.prefix { $0.isNumber }))
        #expect(offset > 0 && offset < bytes.count)

        // The xref table starts there, and its entries follow "0 n".
        let table = String(decoding: bytes[offset...], as: UTF8.self)
        #expect(table.hasPrefix("xref\n"))

        // Every ten-digit offset in the table, except the free-list head, must
        // land on "<n> 0 obj".
        var seen = 0
        for line in table.split(separator: "\n").dropFirst(2) {
            guard line.count >= 18, line.hasSuffix("n ") || line.hasSuffix("n") else { continue }
            let value = try #require(Int(line.prefix(10)))
            seen += 1
            let at = String(decoding: bytes[value..<min(value + 20, bytes.count)], as: UTF8.self)
            #expect(at.contains(" 0 obj"), "offset \(value) does not start an object: \(at.debugDescription)")
            #expect(at.hasPrefix("\(seen) 0 obj"), "offset \(value) is not object \(seen)")
        }
        #expect(seen == 5)
    }

    /// The bug this caught, and it was caught by reading a generated file back
    /// through PDFKit rather than by thinking: a literal `(…)` string in a PDF
    /// is **not** UTF-8. Putting the UTF-8 bytes of "Lefèvre" in one yields
    /// "LefÃ¨vre" in every reader.
    @Test("a name with an accent is written as a UTF-16 hex string, not as UTF-8 bytes")
    func accentedNamesUseHexStrings() {
        let plain = SyntheticPDF(book: Book(title: "Emma", authors: ["Jane Austen"])).data()
        let accented = SyntheticPDF(book: Book(title: "Blindness", authors: ["José Saramago"])).data()

        // ASCII stays a literal, which keeps the file readable in an editor.
        #expect(text(of: plain).contains("/Author (Jane Austen)"))

        // The accented one becomes a hex string with the byte-order mark in
        // front. "José Saramago" in UTF-16BE is FEFF then one group per
        // character, so "José" is 004A 006F 0073 00E9 — written out in full
        // rather than assembled, because a test that builds its own expectation
        // the way the code does proves only that the code is consistent.
        let content = text(of: accented)
        #expect(content.contains("/Author <FEFF004A006F007300E900200053006100720061006D00610067006F>"))
        // And the raw UTF-8 bytes of "é" (C3 A9) are nowhere in the Info
        // dictionary, which is what the defect looked like.
        #expect(!content.contains("Jos\u{00C3}\u{00A9}"))
    }

    @Test("an author list is joined the way AuthorField splits it back")
    func authorsRoundTrip() {
        let pdf = SyntheticPDF(book: Book(title: "Good Omens", authors: ["Neil Gaiman", "Terry Pratchett"])).data()
        #expect(text(of: pdf).contains("/Author (Neil Gaiman & Terry Pratchett)"))
        #expect(AuthorField.split("Neil Gaiman & Terry Pratchett") == ["Neil Gaiman", "Terry Pratchett"])
    }

    @Test("brackets and backslashes in a title do not break the string")
    func escaping() {
        let pdf = SyntheticPDF(book: Book(title: "Vol. 1/2 (Special) \\ Edition", authors: ["A"])).data()
        let content = text(of: pdf)
        #expect(content.contains("\\(Special\\)"))
        #expect(content.contains("\\\\ Edition"))
    }

    /// Most scanned PDFs have no Info dictionary at all, and the reader has to
    /// fall back to the file name. The fixture can produce that.
    @Test("a PDF without an Info dictionary names no Info in its trailer")
    func withoutInfo() {
        let pdf = SyntheticPDF(book: Book(title: "Scanned", authors: ["Nobody"]), withoutInfo: true).data()
        let content = text(of: pdf)
        #expect(!content.contains("/Info"))
        #expect(!content.contains("/Title"))
        #expect(content.contains("/Root 1 0 R"))
    }

    /// The colour is written in the C locale. A German Mac writing "0,53" into
    /// a content stream produces a file no reader opens — the same lesson the
    /// smoke test learned from `ps`.
    @Test("the page's colours are written with a decimal point, whatever the Mac's language")
    func decimalPoint() {
        let content = text(of: SyntheticPDF(book: Book(title: "Emma", authors: ["A"])).data())
        let colourLine = content.split(separator: "\n").first { $0.hasSuffix(" rg") }
        let line = colourLine.map(String.init) ?? ""
        #expect(line.contains("."))
        #expect(!line.contains(","))
    }

    @Test("two runs of the writer produce the same bytes")
    func deterministic() {
        let book = Book(id: UUID(), title: "Emma", authors: ["Jane Austen"])
        #expect(SyntheticPDF(book: book).data() == SyntheticPDF(book: book).data())
    }
}
