import Foundation

/// A ZOOM MultiStomp effect file (.ZDL): a small header followed by a TI C6000 ELF.
///
/// Layout: `00000000` · `SIZE` u32(8) u32 headerSize u32 elfSize · `INFO` … · ELF at 20 + headerSize.
/// Byte 60 is the effect-index category, byte 61 a type, bytes 68… the version string.
/// Header size 56 is standard; 312 (`CABI`) is used by the MS-100BT's own amp models;
/// 232 (`BCAB`) appears in bass amps from the MS-60B / B1Xon.
public struct ZDLInfo: Codable, Hashable {
    public let fileName: String
    public let size: Int
    public let headerSize: Int
    public let extendedTag: String
    public let category: UInt8
    public let type: UInt8
    /// Bytes 64–65. Custom effects must not reuse an ID already on the pedal.
    public let effectID: UInt16
    public let version: String
    public let truncated: Bool
    public let displayName: String
    public let parameters: [String]
    public let imports: [String]
    public let exports: [String]
    public let crc32: UInt32

    public static func parse(fileName: String, data d: [UInt8]) -> ZDLInfo? {
        guard d.count > 80, Array(d[4..<8]) == Array("SIZE".utf8), Array(d[20..<24]) == Array("INFO".utf8) else { return nil }
        let headerSize = Int(le32(d, 12)), elfSize = Int(le32(d, 16))
        let elfOff = 20 + headerSize
        let tag = headerSize > 56 ? String(bytes: d[0x4C..<0x50], encoding: .ascii) ?? "" : ""
        let version = String(bytes: d[68..<72].prefix { $0 != 0 }, encoding: .ascii) ?? ""
        let truncated = d.count < elfOff + elfSize
        var imports: [String] = [], exports: [String] = []
        if !truncated, elfOff + 4 <= d.count, Array(d[elfOff..<(elfOff + 4)]) == [0x7F, 0x45, 0x4C, 0x46] {
            (exports, imports) = dynamicSymbols(Array(d[elfOff..<(elfOff + elfSize)]))
        }
        let (name, params) = descriptor(d)
        return ZDLInfo(fileName: fileName, size: d.count, headerSize: headerSize, extendedTag: tag,
                       category: d[60], type: d[61], effectID: UInt16(d[64]) | UInt16(d[65]) << 8, version: version, truncated: truncated,
                       displayName: name ?? fileName.replacingOccurrences(of: ".ZDL", with: "", options: .caseInsensitive),
                       parameters: params, imports: imports.sorted(), exports: exports.sorted(),
                       crc32: Codec.crc32(d))
    }

    /// Community finding: file base names longer than 8 characters have frozen pedals at boot.
    public var hasSafeName: Bool {
        let parts = fileName.split(separator: ".")
        return parts.count == 2 && parts[0].count <= 8 && parts[1].uppercased() == "ZDL"
    }
    /// Largest custom ZDL known to load (MS-70CDR); 32,998 bytes froze a pedal.
    public static let sizeLimit = 32_126

    public static func load(_ url: URL, as name: String? = nil) -> ZDLInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(fileName: name ?? url.lastPathComponent, data: [UInt8](data))
    }

    static func le32(_ d: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    static func le16(_ d: [UInt8], _ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o + 1]) << 8 : 0 }

    static func cstring(_ d: [UInt8], _ o: Int, max: Int) -> String {
        guard o < d.count else { return "" }
        return String(bytes: d[o..<min(o + max, d.count)].prefix { $0 != 0 }, encoding: .isoLatin1) ?? ""
    }

    /// The firmware's descriptor table: 0x30-byte entries starting with "OnOff" (word 3 = 1);
    /// entry 1 is the effect's display name (word 3 = 0xFFFFFFFF), the rest are its knobs.
    static func descriptor(_ d: [UInt8]) -> (String?, [String]) {
        let needle = Array("OnOff\0".utf8)
        var off = 0
        while off + 0x60 <= d.count {
            if d[off] == 0x4F, Array(d[off..<(off + 6)]) == needle, le32(d, off + 12) == 1, le32(d, off + 0x30 + 12) == 0xFFFF_FFFF {
                let name = cstring(d, off + 0x30, max: 12)
                var params: [String] = []
                var e = off + 0x60
                while e + 0x30 <= d.count, params.count < 16 {
                    let p = cstring(d, e, max: 12)
                    if p.isEmpty || !(p.first?.isLetter ?? false) || !p.allSatisfy({ $0.isASCII && !$0.isNewline }) { break }
                    params.append(p)
                    e += 0x30
                }
                return (name.isEmpty ? nil : name, params)
            }
            off += 1
        }
        return (nil, [])
    }

    /// Defined and undefined names of the ELF's .dynsym table.
    static func dynamicSymbols(_ elf: [UInt8]) -> ([String], [String]) {
        let shoff = Int(le32(elf, 0x20)), shentsize = le16(elf, 0x2E), shnum = le16(elf, 0x30)
        guard shoff > 0, shentsize >= 40, shoff + shnum * shentsize <= elf.count else { return ([], []) }
        func sh(_ i: Int, _ field: Int) -> Int { Int(le32(elf, shoff + i * shentsize + field * 4)) }
        var defined = Set<String>(), undefined = Set<String>()
        for i in 0..<shnum where sh(i, 1) == 11 {   // SHT_DYNSYM
            let symOff = sh(i, 4), symSize = sh(i, 5), link = sh(i, 6)
            guard link < shnum else { continue }
            let strOff = sh(link, 4)
            var o = symOff
            while o + 16 <= min(symOff + symSize, elf.count) {
                let nameOff = Int(le32(elf, o)), shndx = le16(elf, o + 14)
                if nameOff > 0 {
                    let n = cstring(elf, strOff + nameOff, max: 128)
                    if !n.isEmpty { if shndx == 0 { undefined.insert(n) } else { defined.insert(n) } }
                }
                o += 16
            }
        }
        return (Array(defined), Array(undefined))
    }
}

/// Category IDs of FLST_SEQ.ZDT / ZDL byte 60, with names from the firmware's own table.
public enum EffectCategory {
    public static let names: [UInt8: String] = [
        0x01: "Dynamics", 0x02: "Filter/EQ", 0x03: "Drive", 0x04: "Amp", 0x05: "Bass Amp",
        0x06: "Modulation", 0x07: "SFX", 0x08: "Delay", 0x09: "Reverb", 0x0B: "Pedal",
        0x0C: "Bass Drive", 0x0D: "Bass Preamp", 0x0F: "Shared library",
        0x14: "Bass Drive (B1Xon)", 0x16: "Bass Preamp (B1Xon)",
    ]
    /// Categories the MS-100BT menu is known to show.
    public static let confirmed: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x08, 0x09]
    /// Present in the firmware's category table but never tested on the MS-100BT.
    public static let experimental: [UInt8] = [0x05, 0x0C, 0x0D]
    public static let sharedLibrary: UInt8 = 0x0F

    public static func name(_ c: UInt8) -> String { names[c] ?? String(format: "Category %02X", c) }
}
