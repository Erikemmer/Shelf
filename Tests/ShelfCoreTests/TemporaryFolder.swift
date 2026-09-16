import Foundation

/// A throw-away folder for file-system tests, deleted when the test ends.
///
/// Test data is synthetic throughout: the EPUBs these tests read are built by
/// `SyntheticEPUB` in the test itself. No borrowed book is in this repository,
/// and none needs to be.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes data at a relative path, making folders as needed.
    @discardableResult
    func write(_ relativePath: String, data: Data) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL)
        return fileURL
    }

    @discardableResult
    func write(_ relativePath: String, text: String) throws -> URL {
        try write(relativePath, data: Data(text.utf8))
    }

    func folder(_ relativePath: String) throws -> URL {
        let folderURL = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(relativePath).path)
    }

    func names(in relativePath: String) -> [String] {
        let folderURL = relativePath.isEmpty ? url : url.appendingPathComponent(relativePath)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []).sorted()
    }
}

/// Hex, for the reference vectors the DEFLATE tests are checked against.
enum Hex {
    static func data(_ string: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2, limitedBy: string.endIndex) ?? string.endIndex
            guard let byte = UInt8(string[index..<next], radix: 16) else { break }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
