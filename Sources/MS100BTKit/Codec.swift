import Foundation

// Encodings used by the ZOOM file-system SysEx protocol. See docs/PROTOCOL.md.

public enum Codec {
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Standard CRC-32 (same as zlib.crc32). The pedal transmits `crc32(data) ^ 0xFFFFFFFF`.
    public static func crc32<C: Collection>(_ d: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// 32-bit value as five 7-bit bytes, least significant first.
    public static func u7x5(_ v: UInt32) -> [UInt8] { (0..<5).map { UInt8((v >> (7 * UInt32($0))) & 0x7F) } }

    /// Reads five 7-bit bytes (least significant first) at `at`.
    public static func u35(_ m: [UInt8], _ at: Int) -> UInt32? {
        guard at >= 0, m.count >= at + 5 else { return nil }
        var v: UInt32 = 0
        for i in 0..<5 { v |= UInt32(m[at + i] & 0x7F) << (7 * UInt32(i)) }
        return v
    }

    /// 8→7 bit packing: one byte holding the high bits (bit 6 = first byte), then up to 7 data bytes.
    public static func pack7<C: Collection>(_ d: C) -> [UInt8] where C.Element == UInt8, C.Index == Int {
        var out: [UInt8] = []
        var i = d.startIndex
        while i < d.endIndex {
            let n = min(7, d.endIndex - i)
            var hi: UInt8 = 0
            for j in 0..<n where d[i + j] & 0x80 != 0 { hi |= 0x40 >> UInt8(j) }
            out.append(hi)
            for j in 0..<n { out.append(d[i + j] & 0x7F) }
            i += n
        }
        return out
    }

    /// 7→8 bit unpacking (inverse of `pack7`).
    public static func unpack7(_ p: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var i = p.startIndex
        while i < p.endIndex {
            let hi = p[i]; i += 1
            for j in 0..<7 where i < p.endIndex {
                out.append(p[i] | (((hi >> (6 - j)) & 1) << 7)); i += 1
            }
        }
        return out
    }

    public static func hex<C: Collection>(_ d: C, limit: Int = 64) -> String where C.Element == UInt8 {
        let s = d.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return d.count > limit ? "\(s) … (\(d.count) bytes)" : s
    }

    /// Splits a byte stream into complete SysEx messages (F0 … F7).
    public static func splitSysEx(_ d: Data) -> [[UInt8]] {
        var msgs: [[UInt8]] = [], cur: [UInt8] = []
        for b in d {
            if b == 0xF0 { cur = [] }
            cur.append(b)
            if b == 0xF7 { msgs.append(cur); cur = [] }
        }
        return msgs
    }
}
