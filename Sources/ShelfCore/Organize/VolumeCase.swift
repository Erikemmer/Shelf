import Foundation

/// Whether a volume treats two names that differ only in case as one name.
///
/// This is **measured, not assumed**, and that is the whole reason the type
/// exists. APFS is case-insensitive by default on the internal disk and
/// case-*sensitive* if it was formatted that way; HFS+ is the same story; an
/// exFAT card is insensitive; a network share is whatever the server is. A
/// library can sit on any of them, and the answer changes what "move this
/// folder there" means:
///
/// * On a folding volume, `Fitzek` and `fitzek` are **one folder**. Moving one
///   onto the other is not a move at all — it is a write into itself, which
///   `FileManager` refuses on some volumes and silently mangles on others. Such
///   a move has to go through a third name.
/// * On a folding volume, two books whose paths differ only in case are a
///   **collision**. On a case-sensitive one they are two folders and no
///   collision at all.
///
/// Guessing from the platform would get the external disk wrong, and getting it
/// wrong means either a refusal where a rename was fine or a rename where a
/// refusal was needed. So it writes one empty file with a mixed-case name,
/// asks for it by the other spelling, and takes the answer away with it.
public enum VolumeCase {

    /// `true` when the volume folds case — `Fitzek` and `fitzek` are one name.
    ///
    /// Falls back to `true` when the question cannot be asked at all (a
    /// read-only folder, a volume that has gone). `true` is the cautious
    /// answer: it treats a case-only difference as dangerous, which costs a
    /// detour through a temporary name and a collision reported that was not
    /// one — where `false` would attempt a move that can destroy a folder.
    public static func folds(at folder: URL) -> Bool {
        let probe = "shelf-Case-\(UUID().uuidString.prefix(8))"
        let upper = folder.appendingPathComponent(probe)
        let lower = folder.appendingPathComponent(probe.lowercased())
        guard FileManager.default.createFile(atPath: upper.path, contents: Data()) else { return true }
        defer { try? FileManager.default.removeItem(at: upper) }
        return FileManager.default.fileExists(atPath: lower.path)
    }

    /// The key two paths are compared by on this volume: itself, or itself
    /// folded. One function, so "are these the same folder?" is answered the
    /// same way by the planner, the collision check and the runner.
    public static func key(_ path: String, folding: Bool) -> String {
        folding ? path.lowercased() : path
    }

    /// Whether two paths name the same folder on this volume.
    public static func same(_ one: String, _ other: String, folding: Bool) -> Bool {
        key(one, folding: folding) == key(other, folding: folding)
    }

    /// Whether this is a move that only changes the spelling's case — the one
    /// that needs a third name on a folding volume.
    public static func isCaseOnly(from: String, to: String, folding: Bool) -> Bool {
        folding && from != to && from.lowercased() == to.lowercased()
    }
}
