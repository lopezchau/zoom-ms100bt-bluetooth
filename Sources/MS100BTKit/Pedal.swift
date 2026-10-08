import Foundation

/// ZOOM MS-100BT file-system protocol over SysEx. Every operation here was verified on hardware;
/// see docs/PROTOCOL.md. Firmware (ROM erase/write) commands are deliberately NOT implemented.
public final class Pedal {
    public struct Identity: Codable {
        public let modelID: UInt8
        public let mode: UInt8
        public let firmware: String
    }

    public struct FileEntry: Codable, Hashable {
        public let name: String
        public let size: Int
    }

    public enum PedalError: Error, CustomStringConvertible {
        case noIdentity
        case unexpectedModel(UInt8)
        case noReply(String)
        case refused(String)
        case pedal(String, [UInt8])
        case verifyMismatch(String)
        case fileLimit(Int)

        public var description: String {
            switch self {
            case .noIdentity: return "The pedal did not answer the identity request."
            case .unexpectedModel(let m): return String(format: "Unexpected model ID 0x%02X (expected 0x5E).", m)
            case .noReply(let what): return "No reply from the pedal: \(what)."
            case .refused(let why): return "Refused: \(why)."
            case .pedal(let what, let m): return "The pedal rejected \(what): \(Codec.hex(m))."
            case .verifyMismatch(let n): return "Verification failed for \(n): read-back differs from what was written."
            case .fileLimit(let n): return "The pedal file system holds at most \(Pedal.maxFiles) files; this change needs \(n)."
            }
        }
    }

    /// Hard limit of the pedal's file system, found on hardware: the 201st file cannot be written.
    public static let maxFiles = 200
    /// Files that the tool must never delete or overwrite.
    public static let protectedFiles: Set<String> = ["PAIR.DAT"]
    public static let indexFile = "FLST_SEQ.ZDT"

    public let link: RFCOMMLink
    public var deviceID: UInt8 = 0x5E
    public var log: (String) -> Void
    public var verbose = false

    public init(link: RFCOMMLink, log: @escaping (String) -> Void = { _ in }) {
        self.link = link
        self.log = log
    }

    // MARK: Low level

    /// Sends a ZOOM message (`F0 52 00 <id> body F7`) and waits until a reply matches `until`.
    @discardableResult
    func transact(_ body: [UInt8], timeout: Double = 4, until: ([UInt8]) -> Bool) throws -> [[UInt8]] {
        link.clearReceived()
        let msg = [0xF0, 0x52, 0x00, deviceID] + body + [0xF7]
        if verbose { log("TX \(Codec.hex(msg))") }
        try link.send(msg)
        var msgs: [[UInt8]] = []
        spinRunLoop(timeout) { msgs = Codec.splitSysEx(link.rx); return msgs.contains(where: until) }
        if verbose { for m in msgs { log("RX \(Codec.hex(m))") } }
        return msgs
    }

    static func isFS(_ m: [UInt8], sub: UInt8, fn: UInt8? = nil) -> Bool {
        m.count >= 7 && m[4] == 0x60 && m[5] == sub && (fn == nil || m[6] == fn!)
    }
    static func isStatus(_ m: [UInt8]) -> Bool { isFS(m, sub: 0x03) }
    static func statusValue(_ m: [UInt8]) -> UInt32? { isStatus(m) ? Codec.u35(m, 6) : nil }
    /// 0xFFFFFFFA: "not found / end of list".
    static let notFound: UInt32 = 0xFFFF_FFFA

    func ack() throws {
        let r = try transact([0x60, 0x05, 0x00], until: Pedal.isStatus)
        guard r.contains(where: Pedal.isStatus) else { throw PedalError.noReply("ACK") }
    }

    // MARK: Identity and file-system info

    public func identify() throws -> Identity {
        link.clearReceived()
        try link.send([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7])
        spinRunLoop(5) { link.rx.contains(0xF7) }
        guard let m = Codec.splitSysEx(link.rx).first(where: { $0.count >= 9 && $0[1] == 0x7E && $0[3] == 0x06 && $0[4] == 0x02 }) else {
            throw PedalError.noIdentity
        }
        let model = m[6]
        guard m[5] == 0x52, model == 0x5E || model == 0x5D else { throw PedalError.unexpectedModel(model) }
        deviceID = model
        let fw = String(bytes: m[9..<(m.count - 1)].filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
        return Identity(modelID: model, mode: m[8], firmware: fw)
    }

    /// Maximum write block size (`maxFFSWriteSize`), 4096 on the MS-100BT.
    public func maxWriteSize() throws -> Int {
        let r = try transact([0x60, 0x02]) { Pedal.isFS($0, sub: 0x04, fn: 0x02) || Pedal.isStatus($0) }
        try ack()
        guard let m = r.first(where: { Pedal.isFS($0, sub: 0x04, fn: 0x02) }), let v = Codec.u35(m, 20) else { return 4096 }
        return Int(v)
    }

    public func diskUsage() throws -> (total: Int, free: Int) {
        let r = try transact([0x60, 0x29, 0, 0, 0, 0, 0]) { Pedal.isFS($0, sub: 0x04) || Pedal.isStatus($0) }
        guard let m = r.first(where: { Pedal.isFS($0, sub: 0x04) }), let t = Codec.u35(m, 11), let f = Codec.u35(m, 16) else {
            throw PedalError.noReply("disk usage")
        }
        return (Int(t), Int(f))
    }

    public func listFiles(progress: (Int) -> Void = { _ in }) throws -> [FileEntry] {
        var files: [FileEntry] = []
        var op: UInt8 = 0x25
        var retries = 0
        while files.count < Pedal.maxFiles + 20 {
            let r = try transact([0x60, op, 0x00, 0x00, 0x2A, 0x00], timeout: 3) { Pedal.isFS($0, sub: 0x04) || Pedal.isStatus($0) }
            guard let m = r.first(where: { Pedal.isFS($0, sub: 0x04) && $0.count > 35 }) else {
                // Only an explicit "end of list" status ends the listing; a missing reply is retried,
                // because a truncated list would defeat the file-limit check and the pre-delete backup.
                if r.contains(where: { Pedal.statusValue($0) == Pedal.notFound }) { break }
                retries += 1
                if retries > 3 { throw PedalError.noReply("file listing after \(files.count) files") }
                continue
            }
            op = 0x26
            retries = 0
            let name = String(bytes: m[15..<28].prefix { $0 != 0 }, encoding: .ascii) ?? ""
            if name.isEmpty || files.contains(where: { $0.name == name }) { break }
            files.append(FileEntry(name: name, size: Int(Codec.u35(m, 30) ?? 0)))
            progress(files.count)
        }
        try transact([0x60, 0x27], timeout: 2, until: Pedal.isStatus)
        return files
    }

    // MARK: Files

    public func readFile(_ name: String, expectedSize: Int? = nil, chunk: Int = 4096) throws -> [UInt8] {
        let open: [UInt8] = [0x60, 0x20, 0x02] + [UInt8](repeating: 0, count: 9) + Array(name.utf8) + [0x00]
        let r = try transact(open) { Pedal.isFS($0, sub: 0x04, fn: 0x20) || Pedal.isStatus($0) }
        guard let om = r.first(where: { Pedal.isFS($0, sub: 0x04, fn: 0x20) && $0.count > 16 }) else {
            throw PedalError.noReply("open \(name) for reading")
        }
        let handle = Array(om[11..<16])
        try ack()
        defer { close(handle) }

        // Observed sequence: read → short reply; ACK → data message (byte 7 = 01); ACK → status.
        let isData: ([UInt8]) -> Bool = { Pedal.isFS($0, sub: 0x04, fn: 0x22) && $0.count >= 17 && $0[7] == 0x01 }
        var data: [UInt8] = []
        for _ in 0..<10_000 {
            let r1 = try transact([0x60, 0x22] + handle + Codec.u7x5(UInt32(chunk))) { Pedal.isFS($0, sub: 0x04, fn: 0x22) || Pedal.isStatus($0) }
            var m = r1.first(where: isData)
            if m == nil {
                m = try transact([0x60, 0x05, 0x00]) { isData($0) || Pedal.isStatus($0) }.first(where: isData)
            }
            guard let m else {
                if data.isEmpty || (expectedSize.map { data.count < $0 } ?? false) { throw PedalError.noReply("read \(name) at \(data.count)") }
                break
            }
            let length = Int(m[9]) | (Int(m[10]) << 7)
            try ack()
            if length == 0 { break }
            let block = Array(Codec.unpack7(m[11..<(m.count - 6)]).prefix(length))
            guard block.count == length, (Codec.u35(m, m.count - 6) ?? 0) ^ 0xFFFF_FFFF == Codec.crc32(block) else {
                throw PedalError.pedal("block CRC of \(name)", Array(m.prefix(16)))
            }
            data += block
            if let e = expectedSize, data.count >= e { break }
            if length < chunk { break }
        }
        if let e = expectedSize, data.count != e { throw PedalError.verifyMismatch("\(name) (\(data.count) of \(e) bytes)") }
        return data
    }

    func close(_ handle: [UInt8]) {
        _ = try? transact([0x60, 0x21] + handle, timeout: 3, until: Pedal.isStatus)
        _ = try? transact([0x60, 0x09], timeout: 2) { _ in true }
    }

    /// Deletes a file. Returns false if it did not exist.
    @discardableResult
    public func deleteFile(_ name: String) throws -> Bool {
        guard !Pedal.protectedFiles.contains(name.uppercased()) else { throw PedalError.refused("\(name) is protected") }
        let r = try transact([0x60, 0x24] + Array(name.utf8) + [0x00]) { Pedal.isStatus($0) }
        guard let m = r.first(where: Pedal.isStatus), let v = Pedal.statusValue(m) else { throw PedalError.noReply("delete \(name)") }
        if v == Pedal.notFound { return false }
        guard v == 0 else { throw PedalError.pedal("delete \(name)", m) }
        return true
    }

    /// Writes a file (delete → open 01 → [write → ACK]… → close), then reads it back to verify.
    public func writeFile(_ name: String, _ data: [UInt8], chunk: Int = 4096, verify: Bool = true,
                          progress: (Int, Int) -> Void = { _, _ in }) throws {
        guard !Pedal.protectedFiles.contains(name.uppercased()) else { throw PedalError.refused("\(name) is protected") }
        guard name.utf8.count <= 12 else { throw PedalError.refused("file name longer than 12 characters: \(name)") }
        let ok: ([UInt8]) -> Bool = { Pedal.statusValue($0) == 0 }

        _ = try deleteFile(name)
        let open: [UInt8] = [0x60, 0x20, 0x01] + [UInt8](repeating: 0, count: 9) + Array(name.utf8) + [0x00]
        let r1 = try transact(open) { Pedal.isFS($0, sub: 0x04, fn: 0x20) || Pedal.isStatus($0) }
        guard let om = r1.first(where: { Pedal.isFS($0, sub: 0x04, fn: 0x20) && $0.count > 16 }) else {
            throw PedalError.noReply("open \(name) for writing")
        }
        let handle = Array(om[11..<16])   // not always 00×5: use what the pedal returns
        try ack()

        var closed = false
        defer { if !closed { close(handle) } }
        var off = 0
        while off < data.count {
            let n = min(chunk, data.count - off)
            let block = data[off..<(off + n)]
            let body = [0x60, 0x23] + handle + Codec.u7x5(UInt32(n)) + Codec.pack7(Array(block)) + Codec.u7x5(Codec.crc32(block) ^ 0xFFFF_FFFF)
            let rw = try transact(body, timeout: 6) { Pedal.isFS($0, sub: 0x04, fn: 0x23) || Pedal.isStatus($0) || Pedal.isFS($0, sub: 0x05) }
            if rw.isEmpty { throw PedalError.noReply("write block at \(off) of \(name)") }
            if let e = rw.first(where: { Pedal.isStatus($0) && !ok($0) }) { throw PedalError.pedal("write of \(name) at \(off)", e) }
            let ra = try transact([0x60, 0x05, 0x00]) { Pedal.isStatus($0) || Pedal.isFS($0, sub: 0x04, fn: 0x23) }
            if let e = ra.first(where: { Pedal.isStatus($0) && !ok($0) }) { throw PedalError.pedal("ACK of \(name) at \(off)", e) }
            off += n
            progress(off, data.count)
        }
        close(handle)
        closed = true

        if verify {
            let back = try readFile(name, expectedSize: data.count)
            guard back == data else { throw PedalError.verifyMismatch(name) }
        }
    }
}
