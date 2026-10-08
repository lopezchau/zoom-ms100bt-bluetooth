import Foundation

/// FLST_SEQ.ZDT, the pedal's effect menu: 13-byte records (8.3 name + NUL, zero padded).
/// `>>>\0`+u32 opens a category, `<<<\0`+u32 closes it; the file is zero-padded to a fixed size
/// (4108 bytes on the MS-100BT). There is no checksum. `build(parse(x)) == x` for the stock file.
public struct EffectIndex: Codable, Equatable {
    public struct Category: Codable, Equatable {
        public var id: UInt8
        /// Effect file names in menu order. An empty string is a blank record (category 00 has one).
        public var effects: [String]
    }

    public var categories: [Category]
    public var fileSize: Int

    public enum IndexError: Error, CustomStringConvertible {
        case malformed(String)
        case tooBig(Int, Int)
        public var description: String {
            switch self {
            case .malformed(let s): return "Malformed effect index: \(s)"
            case .tooBig(let n, let max): return "Effect index too big: \(n) > \(max) bytes"
            }
        }
    }

    static let record = 13

    public init(data: [UInt8]) throws {
        var cats: [Category] = []
        var cur: Category?
        var end = data.count
        while end > 0 && data[end - 1] == 0 { end -= 1 }
        end += (EffectIndex.record - end % EffectIndex.record) % EffectIndex.record
        var off = 0
        while off + EffectIndex.record <= min(end, data.count) {
            let r = Array(data[off..<(off + EffectIndex.record)])
            let cat = UInt8(r[4])
            if Array(r[0..<4]) == [0x3E, 0x3E, 0x3E, 0] {
                guard cur == nil else { throw IndexError.malformed("category not closed at \(off)") }
                cur = Category(id: cat, effects: [])
            } else if Array(r[0..<4]) == [0x3C, 0x3C, 0x3C, 0] {
                guard let c = cur, c.id == cat else { throw IndexError.malformed("unexpected category end at \(off)") }
                cats.append(c); cur = nil
            } else {
                guard cur != nil else { throw IndexError.malformed("effect outside a category at \(off)") }
                cur!.effects.append(String(bytes: r.prefix { $0 != 0 }, encoding: .ascii) ?? "")
            }
            off += EffectIndex.record
        }
        guard cur == nil else { throw IndexError.malformed("last category not closed") }
        categories = cats
        fileSize = data.count
        guard try build() == data else { throw IndexError.malformed("does not round-trip; unknown format") }
    }

    public func build() throws -> [UInt8] {
        var out: [UInt8] = []
        func rec(_ prefix: [UInt8]) { out += prefix + [UInt8](repeating: 0, count: EffectIndex.record - prefix.count) }
        for c in categories {
            rec([0x3E, 0x3E, 0x3E, 0, c.id, 0, 0, 0])
            for e in c.effects {
                let b = Array(e.utf8)
                guard b.count <= 12 else { throw IndexError.malformed("name too long: \(e)") }
                rec(b)
            }
            rec([0x3C, 0x3C, 0x3C, 0, c.id, 0, 0, 0])
        }
        guard out.count <= fileSize else { throw IndexError.tooBig(out.count, fileSize) }
        return out + [UInt8](repeating: 0, count: fileSize - out.count)
    }

    public var allEffects: [String] { categories.flatMap { $0.effects }.filter { !$0.isEmpty } }

    public func category(of name: String) -> UInt8? {
        categories.first { $0.effects.contains(name) }?.id
    }

    public mutating func remove(_ name: String) {
        for i in categories.indices { categories[i].effects.removeAll { $0 == name } }
    }

    public mutating func append(_ name: String, to cat: UInt8) {
        remove(name)
        if let i = categories.firstIndex(where: { $0.id == cat }) {
            categories[i].effects.append(name)
        } else {
            categories.append(Category(id: cat, effects: [name]))
        }
    }

    public var usedBytes: Int { (try? build())?.reversed().drop { $0 == 0 }.count ?? 0 }
}
