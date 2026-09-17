import Darwin
import Foundation
import ShelfCore

/// The small part of libarchive Shelf needs, reached at runtime.
///
/// **Why `dlopen` and not a link.** macOS ships libarchive as
/// `/usr/lib/libarchive.2.dylib` and ships **no header for it**: there is no
/// `archive.h` anywhere in the SDK. Linking would therefore mean carrying a
/// hand-written header and a module map for a library whose ABI is Apple's to
/// change. Loading it by name and looking up thirteen symbols has the same cost
/// and one large advantage — it can *fail*, at runtime, in a way the program
/// can say something about. Which is exactly what CONCEPT §13 asks for: check
/// the version at runtime, fall back to the file name, and show the user why.
///
/// Only reading. Nothing here writes an archive, and the only file it ever
/// opens is one the user chose.
///
/// Measured on this Mac: libarchive 3.7.4, with both `rar` and `rar5` readers
/// present. Another Mac may have neither, which is the whole reason this is a
/// question asked at runtime rather than an assumption.
final class LibArchive: @unchecked Sendable {

    /// What this Mac's libarchive turned out to be.
    struct Capabilities: Sendable, Equatable {
        var version: String
        /// 3007004 for 3.7.4 — the form libarchive reports it in.
        var versionNumber: Int
        /// RAR4, the format most CBRs are.
        var readsRAR: Bool
        /// RAR5, which older libarchives do not have.
        var readsRAR5: Bool

        var readsAnyRAR: Bool { readsRAR || readsRAR5 }

        /// The sentence the inspector and the import report use. Never silence:
        /// a CBR that could not be opened has to say why (CONCEPT §13).
        var note: String {
            guard readsAnyRAR else {
                return "This Mac's \(version) cannot read RAR, so CBR files are listed by name only."
            }
            if !readsRAR5 {
                return "\(version) reads RAR but not RAR5. A CBR in RAR5 falls back to its file name."
            }
            return "\(version), reading RAR and RAR5."
        }
    }

    /// Loaded once. `nil` when libarchive is not there at all, which is a state
    /// this program has to survive rather than assume away.
    static let shared: LibArchive? = LibArchive()

    private let handle: UnsafeMutableRawPointer
    let capabilities: Capabilities

    // MARK: The C functions, as Swift types

    private typealias VersionString = @convention(c) () -> UnsafePointer<CChar>?
    private typealias VersionNumber = @convention(c) () -> Int32
    private typealias ReadNew = @convention(c) () -> OpaquePointer?
    private typealias Support = @convention(c) (OpaquePointer?) -> Int32
    private typealias OpenFilename = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    private typealias NextHeader = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    private typealias EntryPathname = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias EntrySize = @convention(c) (OpaquePointer?) -> Int64
    private typealias ReadData = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    private typealias ReadFree = @convention(c) (OpaquePointer?) -> Int32
    private typealias ErrorString = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    private let readNew: ReadNew
    private let supportFilterAll: Support
    private let supportFormatAll: Support
    private let supportFormatRAR: Support?
    private let supportFormatRAR5: Support?
    private let openFilename: OpenFilename
    private let nextHeader: NextHeader
    private let entryPathname: EntryPathname
    private let entrySize: EntrySize
    private let readData: ReadData
    private let readFree: ReadFree
    private let errorString: ErrorString?

    /// libarchive's own return codes. Only the three that matter here.
    private enum Status {
        static let ok: Int32 = 0
        static let endOfFile: Int32 = 1
    }

    /// How much of one entry will ever be read into memory.
    ///
    /// A comic page is a few megabytes; 64 MB is far past any of them and far
    /// short of a size that could hurt. A CBR whose first page is bigger than
    /// this is not a comic.
    static let maximumEntryBytes = 64 * 1024 * 1024

    private init?() {
        guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_LAZY) else { return nil }
        self.handle = handle

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let raw = dlsym(handle, name) else { return nil }
            return unsafeBitCast(raw, to: type)
        }

        // The ones without which nothing works at all.
        guard let readNew = symbol("archive_read_new", as: ReadNew.self),
            let supportFilterAll = symbol("archive_read_support_filter_all", as: Support.self),
            let supportFormatAll = symbol("archive_read_support_format_all", as: Support.self),
            let openFilename = symbol("archive_read_open_filename", as: OpenFilename.self),
            let nextHeader = symbol("archive_read_next_header", as: NextHeader.self),
            let entryPathname = symbol("archive_entry_pathname", as: EntryPathname.self),
            let entrySize = symbol("archive_entry_size", as: EntrySize.self),
            let readData = symbol("archive_read_data", as: ReadData.self),
            let readFree = symbol("archive_read_free", as: ReadFree.self)
        else {
            dlclose(handle)
            return nil
        }
        self.readNew = readNew
        self.supportFilterAll = supportFilterAll
        self.supportFormatAll = supportFormatAll
        self.openFilename = openFilename
        self.nextHeader = nextHeader
        self.entryPathname = entryPathname
        self.entrySize = entrySize
        self.readData = readData
        self.readFree = readFree
        self.errorString = symbol("archive_error_string", as: ErrorString.self)

        // The ones whose *absence* is the answer to a question, rather than a
        // failure: a libarchive without them reads no RAR, and Shelf says so.
        supportFormatRAR = symbol("archive_read_support_format_rar", as: Support.self)
        supportFormatRAR5 = symbol("archive_read_support_format_rar5", as: Support.self)

        let version = symbol("archive_version_string", as: VersionString.self)?().map { String(cString: $0) }
        let number = symbol("archive_version_number", as: VersionNumber.self)?() ?? 0
        capabilities = Capabilities(
            version: version ?? "libarchive (version unknown)",
            versionNumber: Int(number),
            readsRAR: supportFormatRAR != nil,
            readsRAR5: supportFormatRAR5 != nil)
    }

    // MARK: Reading

    enum Failure: Error {
        case cannotOpen(String)
        case noRARSupport
    }

    /// The names of every entry in an archive, in the order it stores them.
    ///
    /// Two passes over the file rather than one, and deliberately: the entries
    /// have to be *sorted* before it is known which one is the first page, and
    /// holding every page of a 400 MB comic in memory to find out is not worth
    /// saving a second open. The second pass reads exactly one entry.
    func entryNames(of url: URL) throws -> [String] {
        try withArchive(url) { archive in
            var names: [String] = []
            var entry: OpaquePointer?
            while nextHeader(archive, &entry) == Status.ok {
                if let raw = entryPathname(entry) { names.append(String(cString: raw)) }
            }
            return names
        }
    }

    /// The bytes of one named entry, or nil when the archive has no such entry.
    func data(of url: URL, entryNamed wanted: String) throws -> Data? {
        try withArchive(url) { archive in
            var entry: OpaquePointer?
            while nextHeader(archive, &entry) == Status.ok {
                guard let raw = entryPathname(entry), String(cString: raw) == wanted else { continue }

                let declared = entrySize(entry)
                // The declared size is a claim, not a promise: read in chunks
                // until libarchive says it is done, and stop at the cap.
                var out = Data()
                if declared > 0, declared < Int64(Self.maximumEntryBytes) {
                    out.reserveCapacity(Int(declared))
                }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while out.count < Self.maximumEntryBytes {
                    let read = buffer.withUnsafeMutableBytes { readData(archive, $0.baseAddress, $0.count) }
                    if read <= 0 { break }
                    out.append(contentsOf: buffer[0..<read])
                }
                return out.isEmpty ? nil : out
            }
            return nil
        }
    }

    /// Opens, runs the body, and frees — whatever the body does.
    private func withArchive<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard let archive = readNew() else { throw Failure.cannotOpen(url.lastPathComponent) }
        defer { _ = readFree(archive) }

        _ = supportFilterAll(archive)
        _ = supportFormatAll(archive)
        // Asked for by name as well, because `support_format_all` in some
        // builds leaves RAR out — it is the one format whose reader is
        // conditionally compiled.
        _ = supportFormatRAR?(archive)
        _ = supportFormatRAR5?(archive)

        let status = url.path.withCString { openFilename(archive, $0, 64 * 1024) }
        guard status == Status.ok else {
            let reason = errorString?(archive).map { String(cString: $0) } ?? "libarchive could not open it"
            throw Failure.cannotOpen(reason)
        }
        return try body(archive)
    }
}

/// Reads a CBR through libarchive, and falls back visibly when it cannot.
///
/// The rules — which page is the cover, what a file name says, what
/// `ComicInfo.xml` means — are `ComicMetadata`'s, in the core. This is the way
/// in, and nothing else.
enum CBRFileReader {

    static func read(url: URL, readCover: Bool = true) -> BookFileReader.Result {
        let stem = url.deletingPathExtension().lastPathComponent

        guard let library = LibArchive.shared else {
            return BookFileReader.fromName(
                stem, warning: "libarchive is not available on this Mac, so this CBR is listed by name only")
        }
        guard library.capabilities.readsAnyRAR else {
            return BookFileReader.fromName(stem, warning: library.capabilities.note)
        }

        let names: [String]
        do {
            names = try library.entryNames(of: url)
        } catch {
            // The commonest real cause is a RAR5 archive on a libarchive that
            // has only the RAR4 reader — so the note says which readers this
            // Mac has, rather than only that something went wrong.
            return BookFileReader.fromName(
                stem, warning: "this CBR could not be opened – \(library.capabilities.note)")
        }

        let comicInfo =
            names
            .first { ($0 as NSString).lastPathComponent.lowercased() == ComicMetadata.comicInfoName.lowercased() }
            .flatMap { try? library.data(of: url, entryNamed: $0) }

        let read = ComicMetadata.read(
            pageNames: names, comicInfo: comicInfo ?? nil, fallbackName: stem,
            readPage: { name in readCover ? (try? library.data(of: url, entryNamed: name)) ?? nil : nil })

        return BookFileReader.Result(
            book: read.book, cover: read.cover, coverName: read.coverName,
            warnings: read.warnings, fromTheFile: read.hadComicInfo)
    }
}
