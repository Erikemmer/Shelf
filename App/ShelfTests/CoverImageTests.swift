import CoreGraphics
import Foundation
import ImageIO
import ShelfCore
import UniformTypeIdentifiers
import XCTest

/// `CoverImage` carrying out what `CoverImageRule` decides. The rule itself is
/// tested in `ShelfCoreTests` on both platforms; this is the half that needs
/// ImageIO, and it runs only on a Mac (docs/adr/0023-…).
///
/// Every picture is drawn here, in memory — no photograph and no borrowed
/// cover is in the repository (CLAUDE.md).
final class CoverImageTests: XCTestCase {

    // MARK: Material

    /// A picture of this size in this format, with a gradient so that a
    /// re-encode has something to compress. `orientation` is the EXIF value.
    private func picture(
        _ width: Int, _ height: Int, as type: UTType, orientation: Int? = nil
    ) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for step in 0..<8 {
            let shade = CGFloat(step) / 8
            context.setFillColor(red: shade, green: 1 - shade, blue: 0.4, alpha: 1)
            context.fill(CGRect(x: width * step / 8, y: 0, width: width / 8 + 1, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil),
            "this Mac cannot write \(type.identifier)")
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "could not write \(type.identifier)")
        return output as Data
    }

    /// Pixel size as ImageIO reports it for these bytes, and the type it
    /// recognises them as.
    private func measure(_ data: Data) throws -> (width: Int, height: Int, type: String?) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            CGImageSourceGetType(source) as String?
        )
    }

    private func prepared(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        switch CoverImage.prepare(data) {
        case .success(let bytes): return bytes
        case .failure(let refusal):
            XCTFail("expected a prepared picture, got \(refusal)", file: file, line: line)
            throw refusal
        }
    }

    private static let all: [(name: String, type: UTType)] = [
        ("JPEG", .jpeg), ("PNG", .png), ("HEIC", .heic), ("TIFF", .tiff),
    ]

    // MARK: Within the ceiling

    func testASmallJPEGOrPNGIsWrittenExactlyAsItArrived() throws {
        for type in [UTType.jpeg, .png] {
            let original = try picture(400, 600, as: type)
            XCTAssertEqual(try prepared(original), original, "\(type.identifier) must not be re-encoded")
        }
    }

    func testAPictureAtTheCeilingIsLeftAlone() throws {
        let original = try picture(CoverImageRule.maxEdgePixels, 900, as: .jpeg)
        XCTAssertEqual(try prepared(original), original)
    }

    func testASmallHEICOrTIFFBecomesAJPEGOfTheSameSize() throws {
        for type in [UTType.heic, .tiff] {
            let result = try measure(try prepared(try picture(400, 600, as: type)))
            XCTAssertEqual(result.type, UTType.jpeg.identifier, type.identifier)
            XCTAssertEqual(result.width, 400, "never enlarged, never shrunk: \(type.identifier)")
            XCTAssertEqual(result.height, 600, type.identifier)
        }
    }

    // MARK: Above the ceiling

    func testALargePictureComesDownToTheCeilingKeepingItsShape() throws {
        for (name, type) in Self.all {
            let result = try measure(try prepared(try picture(3200, 2000, as: type)))
            XCTAssertEqual(result.type, UTType.jpeg.identifier, name)
            XCTAssertEqual(result.width, 1600, name)
            XCTAssertEqual(result.height, 1000, "3200 × 2000 is 8 : 5 and must stay so: \(name)")
        }
    }

    func testALargePortraitIsScaledOnItsLongEdge() throws {
        let result = try measure(try prepared(try picture(1000, 2400, as: .png)))
        XCTAssertEqual(result.height, 1600)
        XCTAssertEqual(result.width, 667, accuracy: 1)
    }

    func testTheResultIsAReadableJPEGAtTheStatedQuality() throws {
        let original = try picture(3200, 2000, as: .png)
        let result = try prepared(original)
        XCTAssertEqual(CoverFile.fileExtension(for: result), "jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "the JPEG must decode")
        XCTAssertLessThan(result.count, original.count * 2, "a re-encode must not balloon")
    }

    // MARK: Orientation

    func testEXIFRotationIsAppliedWhenAPictureIsScaled() throws {
        // Stored 3200 × 2000 with orientation 6 (rotate 90° clockwise to
        // display): it is a portrait, and must leave as one.
        let sideways = try picture(3200, 2000, as: .jpeg, orientation: 6)
        let result = try measure(try prepared(sideways))
        XCTAssertEqual(result.width, 1000)
        XCTAssertEqual(result.height, 1600)
    }

    // MARK: Things that are not pictures

    func testEmptyAndGarbageBytesAreRefusedNotCrashedOn() {
        for bytes in [Data(), Data("not a picture".utf8), Data(repeating: 0xFF, count: 4096)] {
            guard case .failure(.notAnImage) = CoverImage.prepare(bytes) else {
                return XCTFail("\(bytes.count) bytes of nothing must be refused as not an image")
            }
        }
    }

    func testATruncatedPictureIsAnErrorOrAReadableResultNeverACrash() throws {
        let whole = try picture(3200, 2000, as: .jpeg)
        let cut = whole.prefix(whole.count / 3)
        switch CoverImage.prepare(Data(cut)) {
        case .failure: break
        case .success(let bytes):
            XCTAssertNotNil(
                CGImageSourceCreateWithData(bytes as CFData, nil), "a success must be readable")
        }
    }

    // MARK: From a file

    func testAFileIsReadAndPreparedLikeItsBytes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("big.tiff")
        try picture(2000, 1000, as: .tiff).write(to: url)
        guard case .success(let bytes) = CoverImage.prepare(contentsOf: url) else {
            return XCTFail("a readable file must be prepared")
        }
        XCTAssertEqual(try measure(bytes).width, 1600)

        let missing = folder.appendingPathComponent("missing.png")
        guard case .failure(.cannotWrite) = CoverImage.prepare(contentsOf: missing) else {
            return XCTFail("a missing file must be refused")
        }
    }

    // MARK: describe

    func testDescribeNamesFormatAndPixelSize() throws {
        let text = CoverImage.describe(try picture(300, 450, as: .jpeg))
        XCTAssertTrue(text.hasPrefix("JPG, 300 × 450, "), text)
        XCTAssertEqual(CoverImage.describe(Data("x".utf8)), "unreadable image")
    }
}
