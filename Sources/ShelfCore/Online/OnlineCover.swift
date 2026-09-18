import Foundation

/// Putting a cover fetched from the net next to the book.
///
/// **Only on an explicit action, and only when the file has none**
/// (CONCEPT §4, "Could"). Never as a side effect of taking over a field, and
/// never over a cover that is already there — a person who put their own
/// scan in the folder did that on purpose.
///
/// The book file is not opened at all. The cover is a new file beside it,
/// named by `CoverFile` from its own bytes, written through a `.part` and
/// renamed — the same way every other write in Shelf goes.
public enum OnlineCover {
    public enum Refusal: Error, Equatable, Sendable {
        case coverAlreadyThere(String)
        case notAnImage
        case cannotWrite(String)

        public var message: String {
            switch self {
            case .coverAlreadyThere(let name):
                return "This book already has \(name) beside it. Remove it in the Finder first "
                    + "if the one from the net should replace it."
            case .notAnImage:
                return "What came back is not an image Shelf recognises, so nothing was written."
            case .cannotWrite(let why):
                return "The cover could not be written: \(why)"
            }
        }
    }

    /// Whether this book is one the cover action applies to at all — what the
    /// button's enabled state asks.
    public static func isWanted(in folder: URL) -> Bool { CoverFile.url(in: folder) == nil }

    /// Writes the bytes as the book's cover and answers where they went.
    ///
    /// The magic number is checked before anything is written: a service that
    /// answers an HTML error page with a 200 would otherwise leave a file
    /// called `cover.jpg` holding the words "Not Found", and every later
    /// decode would fail on it without saying why.
    @discardableResult
    public static func write(_ data: Data, into folder: URL) throws -> URL {
        if let existing = CoverFile.url(in: folder) {
            throw Refusal.coverAlreadyThere(existing.lastPathComponent)
        }
        guard CoverFile.fileExtension(for: data) != nil else { throw Refusal.notAnImage }

        let target = folder.appendingPathComponent(CoverFile.name(for: data))
        let part = folder.appendingPathComponent(".\(CoverFile.baseName).part")
        do {
            try data.write(to: part, options: .atomic)
            try FileManager.default.moveItem(at: part, to: target)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw Refusal.cannotWrite(error.localizedDescription)
        }
        return target
    }
}
