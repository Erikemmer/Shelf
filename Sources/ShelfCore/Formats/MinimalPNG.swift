import Foundation

/// Writes a small grayscale PNG.
///
/// Same purpose as `ZipWriter`: test fixtures and the synthetic library, never
/// the app. The covers of the 5 000-book proof run have to be *real* images,
/// because the app decodes them with ImageIO and scales them – a file of random
/// bytes would fail to decode and the measurement would be of nothing.
///
/// PNG rather than JPEG because a correct PNG needs no DCT and no Huffman
/// tables: the pixel data goes into a zlib stream made of *stored* deflate
/// blocks, which is legal, is what every decoder reads, and is about thirty
/// lines. A JPEG encoder would be several hundred lines of arithmetic whose
/// only job is to make test material.
public enum MinimalPNG {
    /// An image `width` × `height`, 8-bit grayscale, whose pixels come from
    /// `pixel`. The closure keeps this useful for gradients and patterns
    /// without this type knowing what a cover looks like.
    public static func grayscale(
        width: Int, height: Int, pixel: (_ x: Int, _ y: Int) -> UInt8
    ) -> Data {
        var raw = Data()
        raw.reserveCapacity((width + 1) * height)
        for y in 0..<height {
            // Filter type 0 (none) per row. Filters exist to help compression,
            // and nothing here compresses.
            raw.append(0)
            for x in 0..<width { raw.append(pixel(x, y)) }
        }

        var output = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.append(be32(UInt32(width)))
        header.append(be32(UInt32(height)))
        header.append(contentsOf: [8, 0, 0, 0, 0])  // 8-bit, greyscale, deflate, no filter, no interlace
        output.append(chunk("IHDR", header))
        output.append(chunk("IDAT", zlibStored(raw)))
        output.append(chunk("IEND", Data()))
        return output
    }

    /// A cover-shaped image with a visible pattern, so a wrong cover in the
    /// grid is noticeable by eye and not only by a test.
    public static func cover(width: Int = 300, height: Int = 450, seed: UInt8) -> Data {
        grayscale(width: width, height: height) { x, y in
            // A diagonal gradient with a band across it: distinguishable at
            // thumbnail size, and different for every seed.
            let gradient = UInt8((x * 160 / max(width, 1) + y * 60 / max(height, 1)) % 200)
            let band: UInt8 = (y * 8 / max(height, 1)) == 2 ? 240 : 0
            return gradient &+ seed &+ band
        }
    }

    /// One PNG chunk: length, type, payload, CRC over type and payload.
    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var result = be32(UInt32(payload.count))
        let body = Data(type.utf8) + payload
        result.append(body)
        result.append(be32(CRC32.of(body)))
        return result
    }

    /// A zlib stream (RFC 1950) whose deflate payload is nothing but stored
    /// blocks (RFC 1951 §3.2.4).
    ///
    /// Each block carries at most 65 535 bytes, preceded by that length and its
    /// one's complement – the same header `Inflate.stored` reads.
    static func zlibStored(_ data: Data) -> Data {
        // 0x78 0x01: deflate, 32 KB window, no preset dictionary, fastest
        // compression level. The check bits make the two bytes a multiple of 31.
        var output = Data([0x78, 0x01])
        let bytes = Array(data)
        var offset = 0
        let maximum = 0xFFFF
        repeat {
            let length = min(maximum, bytes.count - offset)
            let isLast = offset + length >= bytes.count
            output.append(isLast ? 1 : 0)
            output.append(UInt8(length & 0xFF))
            output.append(UInt8((length >> 8) & 0xFF))
            let complement = ~UInt16(length)
            output.append(UInt8(complement & 0xFF))
            output.append(UInt8((complement >> 8) & 0xFF))
            output.append(contentsOf: bytes[offset..<(offset + length)])
            offset += length
        } while offset < bytes.count
        output.append(be32(Adler32.of(data)))
        return output
    }

    private static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
}

/// Adler-32, the checksum a zlib stream ends with.
enum Adler32 {
    static func of(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        // 5552 is the most iterations that cannot overflow 32 bits, so the
        // modulo can wait until the end of each run instead of every byte.
        var index = 0
        let bytes = Array(data)
        while index < bytes.count {
            let end = min(index + 5_552, bytes.count)
            for position in index..<end {
                a += UInt32(bytes[position])
                b += a
            }
            a %= 65_521
            b %= 65_521
            index = end
        }
        return (b << 16) | a
    }
}
