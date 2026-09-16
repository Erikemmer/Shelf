import CryptoKit
import Foundation
import ShelfCore

/// The fast SHA-256, for imports.
///
/// `ShelfCore` knows only the `ContentHasher` protocol, because it has to build
/// without Apple frameworks – CI runs it on Linux. The core also carries
/// `PortableSHA256Hasher`, which its own tests and `shelf-tool` use; this one
/// exists because it is roughly ten times faster, and a Calibre library is tens
/// of gigabytes.
///
/// Two implementations of one algorithm is a place for them to disagree, so
/// `HasherAgreementTests` in the core checks on macOS that they produce the
/// same digest, and the proof run checks both against `/usr/bin/shasum`.
final class SHA256Hasher: ContentHasher {
    private var digest = SHA256()

    func update(_ bytes: Data) {
        digest.update(data: bytes)
    }

    func finish() -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Handed to `ImportRunner`, which needs a fresh hasher per file.
    static let factory: HasherFactory = { SHA256Hasher() }
}
