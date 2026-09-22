import AppKit
import ImageIO
import ShelfCore
import UniformTypeIdentifiers

/// Turning whatever a person chose into the bytes that go beside the book.
///
/// **The rule is not here.** `CoverImageRule` decides whether a picture may be
/// written as it arrived and, if not, how long its long edge may be; this file
/// measures the picture and carries that decision out. The same split
/// `EmptiedFolder` has from `FolderDisposal`: the decision is a pure function
/// tested on Linux, and the part that needs ImageIO is a Mac's.
///
/// Nothing here writes anything. It answers with `Data`, which
/// `CoverReplacement` then puts beside the book atomically, through the Trash,
/// in the core.
enum CoverImage {

    /// What the open panel and the drop target accept.
    ///
    /// HEIC and TIFF are in the list although `CoverFile` cannot name either:
    /// a Mac is full of both, refusing a screenshot would be strange, and the
    /// rule turns them into a JPEG on the way in. A table rather than a set of
    /// `if`s, so adding a format is a row.
    static let accepted: [UTType] = [.png, .jpeg, .heic, .heif, .tiff, .gif, .webP]

    /// Reads a picture and prepares it, or says why it cannot.
    ///
    /// Reads **once**: the same `CGImageSource` answers the size and, when the
    /// rule asks for it, produces the scaled image. Opening the file twice for
    /// a 40 MB photograph is the kind of waste that is invisible until
    /// somebody drops twenty of them.
    static func prepare(contentsOf url: URL) -> Result<Data, CoverReplacement.Refusal> {
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.cannotWrite(url.lastPathComponent))
        }
        return prepare(data)
    }

    static func prepare(_ data: Data) -> Result<Data, CoverReplacement.Refusal> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return .failure(.notAnImage) }

        let facts = CoverImageFacts(
            pixelWidth: pixels(of: source, kCGImagePropertyPixelWidth),
            pixelHeight: pixels(of: source, kCGImagePropertyPixelHeight),
            fileExtension: CoverFile.fileExtension(for: data))

        switch CoverImageRule.preparation(for: facts) {
        case .asIs:
            return .success(data)
        case .reencode(let longEdge):
            guard let jpeg = jpeg(from: source, longEdge: longEdge) else { return .failure(.notAnImage) }
            return .success(jpeg)
        }
    }

    /// A short description for the "Write into the Book File" sheet's cover
    /// row: format and pixel size, in words rather than a picture, because
    /// the row compares two images without showing either of them
    /// (`docs/adr/0021-…`, `EPUBWrite.CoverPlan` — the core knows only
    /// bytes, never a pixel size, so this is the app-layer half of that
    /// row, the same split `CoverImageRule`/`CoverImage` already has).
    static func describe(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0
        else {
            return Loc.string("unreadable image")
        }
        let width = pixels(of: source, kCGImagePropertyPixelWidth)
        let height = pixels(of: source, kCGImagePropertyPixelHeight)
        let format = CoverFile.fileExtension(for: data)?.uppercased() ?? "?"
        return "\(format), \(width) × \(height)"
    }

    // MARK: ImageIO

    private static func pixels(of source: CGImageSource, _ key: CFString) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let value = properties[key] as? Int
        else { return 0 }
        return value
    }

    /// The picture as a JPEG, no longer than `longEdge` on its long side.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` for the same reason `CoverDecoder`
    /// uses it: ImageIO reads only as much of the file as the size asks for, so
    /// a 6 000 px photograph never exists whole in memory. `WithTransform`
    /// because a scan or a phone photograph carries its rotation in EXIF, and a
    /// cover that arrives sideways looks like a defect in Shelf.
    private static func jpeg(from source: CGImageSource, longEdge: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: CoverImageRule.jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
