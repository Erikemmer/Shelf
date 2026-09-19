import Foundation

/// What is already sitting at a path on a device, asked one file at a time.
///
/// The planner needs this for exactly one question, and it is a question that
/// only has an answer on a card a run died on: *is the file already there one
/// this program wrote itself?* A file Shelf put on a device and then lost track
/// of — because the process was killed between two manifest writes — is
/// indistinguishable, by name alone, from somebody else's file of the same
/// name. The bytes tell them apart, and nothing else does.
///
/// Two closures rather than one, so that the expensive question is only ever
/// asked when the cheap one has already said yes. A card holds thousands of
/// files and hashing one is a full read over USB; `byteSize` is a `stat`.
public struct DeviceFileProbe: Sendable {
    /// The size of the file at that path on the volume, or `nil` if there is
    /// no file there. Paths are relative to the volume's root, exactly as
    /// `TransferOperation.destinationPath` writes them.
    public var byteSize: @Sendable (String) -> Int64?
    /// Its SHA-256, read off the device. Only ever called when `byteSize`
    /// already matched, so the cost is bounded by what a killed run left.
    public var sha256: @Sendable (String) -> String?

    public init(
        byteSize: @escaping @Sendable (String) -> Int64?,
        sha256: @escaping @Sendable (String) -> String?
    ) {
        self.byteSize = byteSize
        self.sha256 = sha256
    }

    /// Asks nothing. The planner then behaves exactly as it did before this
    /// existed: a file in the way is the runner's problem, and it refuses to
    /// write over it.
    public static let none = DeviceFileProbe(byteSize: { _ in nil }, sha256: { _ in nil })

    /// Reads the real volume. `makeHasher` is the same factory the runner
    /// takes, so the digest that decides this and the digest that means
    /// "verified" are computed by the same code.
    public static func onVolume(_ volume: URL, makeHasher: @escaping HasherFactory) -> DeviceFileProbe {
        DeviceFileProbe(
            byteSize: { path in
                let url = volume.appendingPathComponent(path)
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                return size.map(Int64.init)
            },
            sha256: { path in
                try? FileDigest.sha256(of: volume.appendingPathComponent(path), makeHasher: makeHasher)
            })
    }
}
