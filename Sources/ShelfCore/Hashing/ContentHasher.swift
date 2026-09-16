import Foundation

/// Computes a content hash in chunks.
///
/// `ShelfCore` has to build without Apple frameworks – CI runs it on Linux – so
/// the real SHA-256 (CryptoKit) lives in the app and the core only knows this
/// much. Chunked on purpose: a 400 MB comic must never sit in memory whole.
/// Copied from Selector.
public protocol ContentHasher: AnyObject {
    func update(_ bytes: Data)
    /// The finished digest, lower-case hex. Called once.
    func finish() -> String
}

/// Makes a fresh hasher per file.
public typealias HasherFactory = @Sendable () -> any ContentHasher

/// How much room is left on the volume a URL sits on.
///
/// Injected so the "not enough space" path can be tested without filling a
/// disk; the default asks the file system.
public typealias FreeSpaceProbe = @Sendable (URL) -> Int64?

extension FileManager {
    /// Free bytes on the volume holding `url`, or nil when the file system
    /// cannot say. Works the same on macOS and Linux.
    public static let defaultFreeSpaceProbe: FreeSpaceProbe = { url in
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

/// SHA-256 over a file, in chunks, using whatever hasher the caller brings.
///
/// The one place that knows how to read a file for hashing, so the importer and
/// the duplicate check cannot disagree about it. The autorelease pool is not
/// decoration: without a pool of its own the loop holds every chunk until the
/// file ends, which in Selector measured 1.2 GB peak for a 7.4 GB folder.
/// See `withAutoreleasePool` for why it is not `autoreleasepool` directly.
public enum FileDigest {
    /// Big enough that per-read overhead disappears, small enough that a
    /// cancelled run stops promptly and memory stays flat.
    public static let chunkSize = 4 * 1_024 * 1_024

    public enum Failure: Error, Equatable {
        case cannotRead(String)
    }

    public static func sha256(of url: URL, makeHasher: HasherFactory) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw Failure.cannotRead(url.lastPathComponent)
        }
        defer { try? handle.close() }
        let hasher = makeHasher()
        var reachedEnd = false
        while !reachedEnd {
            if Task.isCancelled { throw CancellationError() }
            try withAutoreleasePool {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty {
                    reachedEnd = true
                    return
                }
                hasher.update(chunk)
            }
        }
        return hasher.finish()
    }
}
