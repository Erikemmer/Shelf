import AppKit
import ImageIO
import ShelfCore
import UniformTypeIdentifiers

/// A decoded cover and what it costs in memory.
struct DecodedCover: Sendable {
    let image: NSImage
    let byteSize: Int
}

/// Turns a cover file into an image at the size that was asked for.
///
/// Pure and stateless, so it can run in a detached task without ceremony.
/// ImageIO is Apple-only, which is why this lives in the app and not in
/// `ShelfCore`.
enum CoverDecoder {

    /// Decodes the cover at `url`, scaled so its long edge is about `pixels`.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than decoding the whole
    /// image and resizing: a 1 600 × 2 400 cover decoded whole is 15 MB, and
    /// the grid wants 400 px. ImageIO reads only as much of the file as it
    /// needs, which is what makes 8 000 covers possible at all.
    static func decode(url: URL, pixels: Int) -> DecodedCover? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            // Covers are rarely rotated, but a scan can be, and a sideways
            // cover in the grid looks like a bug in the app rather than in the
            // file.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return DecodedCover(
            image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)),
            byteSize: cgImage.width * cgImage.height * 4)
    }

    /// Writes a decoded cover for the disk cache, as **JPEG**.
    ///
    /// Selector writes HEIC where it can, because a 3 000 px preview is about a
    /// third the size that way. Shelf does the opposite, and the measurement is
    /// the reason: encoding a 400 px cover as HEIC takes **38.4 ms** against
    /// **1.05 ms** as JPEG, for 8.2 KB against 19.9 KB. HEIC goes through the
    /// hardware video encoder, which sets up an HEVC session per image – fine
    /// for a few hundred large previews, and 36× too slow for thousands of
    /// small covers. Over 5 000 books that trade is 58 MB of disk against three
    /// minutes of encoding.
    ///
    /// Quality 0.85 at 400 px: a cover is looked at, not examined.
    static let cacheQuality = 0.85

    static func encode(_ image: CGImage, to url: URL) -> Bool {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: cacheQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }
}
