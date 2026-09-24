import Foundation
import ShelfCore

/// The real answer to `FormatQualityProbe` — the one place that actually
/// opens a file to ask B3's tie-break questions, because only the app layer
/// can read every format Shelf has (`FileReader` covers PDF and CBR too,
/// which `BookFileReader` alone cannot).
enum MergeQuality {
    static func probe(url: URL, format: BookFileFormat) -> FormatQuality {
        let result = FileReader.read(url: url, format: format, readCover: true)
        return FormatQuality(
            opensSuccessfully: result.fromTheFile, hasCover: result.cover != nil,
            filledFieldCount: filledFieldCount(of: result.book))
    }

    /// How many of a book's own fields this file's metadata actually filled
    /// in — the same rough count B3 asks for, not a weighted score.
    private static func filledFieldCount(of book: Book) -> Int {
        var count = 0
        if !book.authors.isEmpty { count += 1 }
        if book.series != nil { count += 1 }
        if let publisher = book.publisher, !publisher.isEmpty { count += 1 }
        if book.published != nil { count += 1 }
        if let language = book.language, !language.isEmpty { count += 1 }
        if let description = book.description, !description.isEmpty { count += 1 }
        if !book.tags.isEmpty { count += 1 }
        if book.isbn != nil { count += 1 }
        return count
    }
}
