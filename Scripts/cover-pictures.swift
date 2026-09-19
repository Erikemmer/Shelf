// Draws the pictures the cover run sets as covers.
//
// Drawn and not borrowed, for the reason every other piece of test material in
// this project is generated: no picture that is not this project's own goes
// into it or into a run of it (CLAUDE.md).
//
// Four, each proving a different half of `CoverImageRule`:
//
//   small.png     600 × 900 PNG      under the ceiling and a format a book
//                                    folder can name, so it is written byte
//                                    for byte
//   huge.png     3200 × 4800 PNG     over the ceiling, so it comes down to
//                                    1 600 px and is written again as JPEG
//   sideways.jpg  900 × 600 JPEG     landscape, so the *long* edge is the one
//                                    measured
//   not-a.txt                        not a picture at all, for the refusal
//
// Usage: swift Scripts/cover-pictures.swift <folder>
import AppKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments.dropFirst()
guard let folder = arguments.first.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
    FileHandle.standardError.write(Data("usage: cover-pictures.swift <folder>\n".utf8))
    exit(2)
}
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

/// A flat picture with a broad diagonal band, so that a downscale is visible
/// as a change of size and never as a change of subject — a screenshot has to
/// show which picture is which.
func draw(width: Int, height: Int, hue: CGFloat) -> CGImage? {
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    let background = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
    let band = NSColor(hue: hue, saturation: 0.75, brightness: 0.35, alpha: 1)
    context.setFillColor(background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    context.setFillColor(band.cgColor)
    context.saveGState()
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    context.rotate(by: .pi / 5)
    let thickness = CGFloat(min(width, height)) / 4
    let length = CGFloat(width + height)
    context.fill(CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness))
    context.restoreGState()

    return context.makeImage()
}

func write(_ image: CGImage?, to name: String, as type: UTType, quality: Double = 0.9) {
    guard let image,
        let destination = CGImageDestinationCreateWithURL(
            folder.appending(path: name) as CFURL, type.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("could not write \(name)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("could not finalise \(name)\n".utf8))
        exit(1)
    }
}

write(draw(width: 600, height: 900, hue: 0.58), to: "small.png", as: .png)
write(draw(width: 3_200, height: 4_800, hue: 0.08), to: "huge.png", as: .png)
write(draw(width: 900, height: 600, hue: 0.33), to: "sideways.jpg", as: .jpeg)
try? Data("This is not a picture.\n".utf8).write(to: folder.appending(path: "not-a.txt"))
