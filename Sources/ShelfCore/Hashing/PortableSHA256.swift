import Foundation

/// SHA-256 in plain Swift (FIPS 180-4).
///
/// Why this exists next to the app's CryptoKit hasher: the core builds and its
/// tests run on Linux, where CryptoKit does not exist, and the parts of Shelf
/// that hash – the importer, duplicate detection, the rebuilder – are core
/// logic that has to be testable there. `shelf-tool` uses it too, so the
/// command-line proof run needs no Apple framework.
///
/// The app still uses CryptoKit for real imports, because it is roughly ten
/// times faster and a Calibre library is tens of gigabytes. Two
/// implementations of one algorithm is a place for them to disagree, so
/// `HasherAgreementTests` checks on macOS that they produce the same digest,
/// and the proof run checks both against `/usr/bin/shasum`.
public final class PortableSHA256Hasher: ContentHasher {
    /// Handed to `ImportRunner` and `IndexRebuilder`, which need one per file.
    public static let factory: HasherFactory = { PortableSHA256Hasher() }

    private var state: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]
    /// Bytes seen but not yet part of a full 64-byte block.
    private var pending: [UInt8] = []
    private var totalBytes: UInt64 = 0
    private var finished = false

    public init() {}

    public func update(_ bytes: Data) {
        guard !finished else { return }
        totalBytes += UInt64(bytes.count)
        pending.append(contentsOf: bytes)
        // Whole blocks only; the remainder waits for the next chunk or for the
        // padding in `finish`.
        var offset = 0
        while pending.count - offset >= 64 {
            compress(Array(pending[offset..<(offset + 64)]))
            offset += 64
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    public func finish() -> String {
        guard !finished else { return digestHex }
        finished = true

        // Padding: a 1 bit, then zeros, then the length in bits as a 64-bit
        // big-endian number, so that the total is a multiple of 64 bytes.
        let bitLength = totalBytes * 8
        pending.append(0x80)
        while pending.count % 64 != 56 { pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            pending.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }
        var offset = 0
        while offset < pending.count {
            compress(Array(pending[offset..<(offset + 64)]))
            offset += 64
        }
        pending = []
        return digestHex
    }

    private var digestHex: String {
        state.map { String(format: "%08x", $0) }.joined()
    }

    /// One 64-byte block.
    private func compress(_ block: [UInt8]) {
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = index * 4
            schedule[index] =
                (UInt32(block[base]) << 24) | (UInt32(block[base + 1]) << 16)
                | (UInt32(block[base + 2]) << 8) | UInt32(block[base + 3])
        }
        for index in 16..<64 {
            let s0 =
                rotateRight(schedule[index - 15], 7) ^ rotateRight(schedule[index - 15], 18)
                ^ (schedule[index - 15] >> 3)
            let s1 =
                rotateRight(schedule[index - 2], 17) ^ rotateRight(schedule[index - 2], 19)
                ^ (schedule[index - 2] >> 10)
            schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]

        for index in 0..<64 {
            let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let choose = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ choose &+ Self.constants[index] &+ schedule[index]
            let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    private func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    /// The first thirty-two bits of the fractional parts of the cube roots of
    /// the first sixty-four primes, as the standard specifies them.
    private static let constants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]
}
