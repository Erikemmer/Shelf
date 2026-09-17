// Prints the RGB value of single pixels in an image file.
//
// It exists for one job: comparing a Shelf screenshot with a Selector
// screenshot of the same size, pixel for pixel, so "it looks like Selector" is
// a number and not an opinion. A colour that differs by one step is a
// different colour, and only a reading says so.
//
// Coordinates are in *image* pixels, so a Retina screenshot of a 1440-point
// window is 2880 pixels wide and the sidebar's midpoint is at 2880 / 8, not
// 1440 / 8. `--points <scale>` multiplies the coordinates for you.
//
// Usage: swift Scripts/pixel-probe.swift <image> [--points 2] <x>,<y> [<x>,<y> …]
//        swift Scripts/pixel-probe.swift shot.png --points 2 40,300 700,400
import CoreGraphics
import Foundation
import ImageIO

var arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: pixel-probe.swift <image> [--points <scale>] <x>,<y> …\n".utf8))
    exit(2)
}
arguments.removeFirst()

var scale = 1.0
if let flag = arguments.firstIndex(of: "--points"), flag + 1 < arguments.count {
    scale = Double(arguments[flag + 1]) ?? 1
    arguments.removeSubrange(flag...(flag + 1))
}

let url = URL(fileURLWithPath: path)
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(3)
}

// Redrawn into a known 8-bit RGBA buffer rather than read in place: a
// screenshot carries a colour profile and whatever byte order the encoder felt
// like, and comparing raw bytes across two such files compares the encoders.
let width = image.width
let height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
guard
    let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("cannot redraw \(path)\n".utf8))
    exit(4)
}
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

print("\(url.lastPathComponent): \(width) x \(height) pixels")
for argument in arguments {
    let parts = argument.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else { continue }
    let x = Int(parts[0] * scale)
    let y = Int(parts[1] * scale)
    guard x >= 0, y >= 0, x < width, y < height else {
        print("  \(argument): outside the image")
        continue
    }
    let offset = (y * width + x) * 4
    let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
    let hex = String(format: "#%02X%02X%02X", red, green, blue)
    print("  \(x),\(y): \(hex)  rgb(\(red), \(green), \(blue))")
}
