import Foundation

/// What Shelf measured about a picture somebody wants to make a cover.
///
/// Filled in by the app layer, which is where ImageIO lives; the rule below is
/// a pure function over it, so the decision is testable on Linux and the only
/// thing that needs a Mac is the measuring and the re-encoding.
public struct CoverImageFacts: Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// What `CoverFile.fileExtension` made of the bytes, or nil when they are
    /// a format a book folder cannot name — HEIC and TIFF above all, which the
    /// open panel offers because a Mac is full of both.
    public var fileExtension: String?

    public init(pixelWidth: Int, pixelHeight: Int, fileExtension: String?) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileExtension = fileExtension
    }

    public var longEdge: Int { max(pixelWidth, pixelHeight) }
}

/// What to do with a picture on its way to becoming a cover.
public enum CoverPreparation: Equatable, Sendable {
    /// Write the bytes exactly as they arrived.
    case asIs
    /// Decode and write again as JPEG, no longer than this on the long edge.
    case reencode(longEdge: Int)
}

/// How large a cover is allowed to be, and when it is left alone.
///
/// Two separate things are being kept from going wrong.
///
/// **A cover is not a photograph.** Somebody dropping a 40 MB picture from
/// their camera beside an 800 KB book has made a library that is mostly
/// pictures of books, and has done it without being told. Every such cover is
/// also decoded, scaled and cached on every open.
///
/// **A cover that is already the right size is not touched.** Re-encoding it
/// loses quality to gain nothing, which is the rule `ImportRunner.writeCover`
/// has followed since Sprint 1 — "the image is never re-encoded". A ceiling is
/// only a ceiling.
public enum CoverImageRule {

    /// The longest edge a cover is stored at.
    ///
    /// **1 600 px, and the reason is the pipeline's own numbers.** The largest
    /// tier Shelf ever decodes a cover to is `.large`, 1 000 px (ADR 0005,
    /// decision 1), and nobody zooms into a cover — there is deliberately no
    /// full-resolution tier. 1 600 is that with room to spare: enough for a
    /// second, sharper large tier if a future display asks for one, without
    /// storing a second copy of the picture at a size nothing will ever ask
    /// for. It is also, conveniently, about the size publishers actually ship
    /// covers at, so a downloaded cover is usually left alone by the rule
    /// above rather than re-encoded.
    ///
    /// What it costs: a 1 600 px JPEG of a book cover is a few hundred
    /// kilobytes, against the tens of megabytes an unscaled photograph is.
    /// One constant in one place, ready to be argued with.
    public static let maxEdgePixels = 1_600

    /// What the re-encode is written at. 0.85 is the usual answer for a
    /// photograph seen at a distance, which is what a cover in a grid is.
    public static let jpegQuality = 0.85

    /// Whether these bytes may go beside the book as they are.
    public static func preparation(for facts: CoverImageFacts) -> CoverPreparation {
        // A size ImageIO could not read. Whatever the picture is, what lands
        // beside the book should be a JPEG of a size this program chose.
        guard facts.longEdge > 0 else { return .reencode(longEdge: maxEdgePixels) }

        // Never enlarge: scaling a 400 px scan up to the ceiling makes a blurry
        // file four times the size of the sharp one.
        let target = min(facts.longEdge, maxEdgePixels)

        // A format the folder cannot name is a cover no other part of Shelf
        // would find: `CoverFile.url` looks for six extensions and neither
        // HEIC nor TIFF is one of them.
        guard facts.fileExtension != nil else { return .reencode(longEdge: target) }
        return facts.longEdge > maxEdgePixels ? .reencode(longEdge: maxEdgePixels) : .asIs
    }
}
