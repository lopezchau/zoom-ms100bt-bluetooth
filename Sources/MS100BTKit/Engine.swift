import Foundation
import IOBluetooth

/// Snapshot of the pedal, as read by `Engine.readState`.
public struct PedalState: Codable {
    public let address: String
    public let identity: Pedal.Identity
    public let maxWriteSize: Int
    public let totalBytes: Int
    public let freeBytes: Int
    public let files: [Pedal.FileEntry]
    public let index: EffectIndex
    public let indexCRC: UInt32
}

/// A set of changes computed by the GUI (or by hand) and executed by `Engine.apply`.
public struct ChangePlan: Codable {
    public struct Write: Codable {
        public let source: String     // local file path
        public let name: String       // file name on the pedal (8.3)
        public init(source: String, name: String) { self.source = source; self.name = name }
    }
    /// CRC-32 of the index the plan was computed from; apply aborts if the pedal's index differs.
    public let baseIndexCRC: UInt32
    public let deletes: [String]
    public let writes: [Write]
    /// New FLST_SEQ.ZDT, base64. nil = leave the index untouched.
    public let newIndex: String?
    /// Folder where every deleted file and the old index are saved before anything changes.
    public let backupDir: String

    public init(baseIndexCRC: UInt32, deletes: [String], writes: [Write], newIndex: [UInt8]?, backupDir: String) {
        self.baseIndexCRC = baseIndexCRC
        self.deletes = deletes
        self.writes = writes
        self.newIndex = newIndex.map { Data($0).base64EncodedString() }
        self.backupDir = backupDir
    }
}

/// Progress events, printed as JSON lines by the CLI and consumed by the GUI.
public struct EngineEvent: Codable {
    public var type: String          // log | progress | state | done | error
    public var message: String?
    public var step: Int?
    public var total: Int?
    public var state: PedalState?

    public init(type: String, message: String? = nil, step: Int? = nil, total: Int? = nil, state: PedalState? = nil) {
        self.type = type; self.message = message; self.step = step; self.total = total; self.state = state
    }

    public static func log(_ m: String) -> EngineEvent { EngineEvent(type: "log", message: m) }
    public static func progress(_ m: String, _ s: Int, _ t: Int) -> EngineEvent { EngineEvent(type: "progress", message: m, step: s, total: t) }
}

/// Connects to the pedal and performs high-level operations. Runs on the calling thread,
/// which must keep a run loop (the CLI's main thread does).
public final class Engine {
    public let emit: (EngineEvent) -> Void
    public private(set) var pedal: Pedal!
    private var link: RFCOMMLink!
    public private(set) var identity: Pedal.Identity!

    public init(emit: @escaping (EngineEvent) -> Void) { self.emit = emit }

    public func connect(address: String?, channel: UInt8?, pair: Bool = false) throws {
        guard let device = Discovery.findPedal(address: address, log: { self.emit(.log($0)) }) else { throw TransportError.pedalNotFound }
        emit(.log("Pedal: \(device.name ?? "?") [\(device.addressString ?? "?")]"))
        if pair || !device.isPaired() {
            emit(.log("Pairing…"))
            _ = Pairing.pair(device)
        }
        let ch = channel ?? Discovery.serialChannel(device)
        guard let ch else { throw TransportError.noSerialService }
        link = RFCOMMLink(device: device)
        try link.open(channelID: ch)
        pedal = Pedal(link: link) { [emit] in emit(.log($0)) }
        identity = try pedal.identify()
        emit(.log("Connected on RFCOMM channel \(ch): model 0x\(String(identity.modelID, radix: 16, uppercase: true)), firmware \(identity.firmware)"))
    }

    public func disconnect() { link?.close() }

    public func readState() throws -> PedalState {
        emit(.progress("Reading file-system info", 0, 3))
        let maxWrite = try pedal.maxWriteSize()
        let usage = try pedal.diskUsage()
        emit(.progress("Listing files", 1, 3))
        let files = try pedal.listFiles { n in self.emit(.progress("Listing files (\(n))", 1, 3)) }
        emit(.progress("Reading effect index", 2, 3))
        let size = files.first { $0.name == Pedal.indexFile }?.size
        let raw = try pedal.readFile(Pedal.indexFile, expectedSize: size)
        let index = try EffectIndex(data: raw)
        emit(.progress("Done", 3, 3))
        return PedalState(address: link.device.addressString ?? "", identity: identity, maxWriteSize: maxWrite,
                          totalBytes: usage.total, freeBytes: usage.free, files: files, index: index,
                          indexCRC: Codec.crc32(raw))
    }

    /// Full read-only backup of every file on the pedal, with a MANIFEST.txt (name size crc32).
    public func backup(to dir: URL, only: [String]? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try only.map { names in names.map { Pedal.FileEntry(name: $0, size: 0) } } ?? pedal.listFiles()
        var manifest = "# name size crc32\n"
        for (i, f) in files.enumerated() {
            emit(.progress("Backing up \(f.name)", i, files.count))
            let d = try pedal.readFile(f.name, expectedSize: f.size > 0 ? f.size : nil)
            try Data(d).write(to: dir.appendingPathComponent(f.name))
            manifest += String(format: "%@ %d %08x\n", f.name, d.count, Codec.crc32(d))
        }
        try manifest.write(to: dir.appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
        emit(.progress("Backup complete", files.count, files.count))
    }

    /// Executes a plan: checks, backs up, deletes, writes (each verified), then writes the index (verified).
    public func apply(_ plan: ChangePlan, dryRun: Bool) throws {
        // 1. The pedal must still be in the state the plan was computed from.
        let files = try pedal.listFiles()
        let names = Set(files.map { $0.name })
        let indexSize = files.first { $0.name == Pedal.indexFile }?.size
        let oldIndex = try pedal.readFile(Pedal.indexFile, expectedSize: indexSize)
        guard Codec.crc32(oldIndex) == plan.baseIndexCRC else {
            throw Pedal.PedalError.refused("the pedal's effect index changed since it was read; refresh and try again")
        }
        for n in plan.deletes + plan.writes.map(\.name) where Pedal.protectedFiles.contains(n.uppercased()) || n == Pedal.indexFile {
            throw Pedal.PedalError.refused("\(n) cannot be changed by a plan")
        }
        let newFiles = Set(plan.writes.map(\.name)).subtracting(names)
        let finalCount = names.count - Set(plan.deletes).intersection(names).count + newFiles.count
        guard finalCount <= Pedal.maxFiles else { throw Pedal.PedalError.fileLimit(finalCount) }
        let sources = try plan.writes.map { w -> (String, [UInt8]) in
            (w.name, [UInt8](try Data(contentsOf: URL(fileURLWithPath: w.source))))
        }
        let newIndex = try plan.newIndex.map { b64 -> [UInt8] in
            guard let d = Data(base64Encoded: b64) else { throw Pedal.PedalError.refused("invalid index data") }
            let bytes = [UInt8](d)
            _ = try EffectIndex(data: bytes)   // validates the format
            return bytes
        }

        // An effect listed under a category other than the one in its own header freezes the pedal
        // when the menu reaches it (found on hardware with an MS-60B bass preamp listed under Drive).
        if let newIndex, let idx = try? EffectIndex(data: newIndex) {
            for (name, data) in sources {
                guard let z = ZDLInfo.parse(fileName: name, data: data), z.category != EffectCategory.sharedLibrary,
                      let listed = idx.category(of: name) else { continue }
                guard listed == z.category else {
                    throw Pedal.PedalError.refused(String(format: "%@ is a category %02X effect but the plan lists it under %02X; this froze an MS-100BT", name, z.category, listed))
                }
            }
        }

        let steps = plan.deletes.count + sources.count + (newIndex == nil ? 0 : 1)
        emit(.log("Plan: delete \(plan.deletes.count), write \(sources.count), index \(newIndex == nil ? "unchanged" : "updated"); files after: \(finalCount)/\(Pedal.maxFiles)"))
        if dryRun { emit(.log("Dry run: nothing was sent to the pedal.")); return }

        // 2. Safety copies: the old index and every file that will be deleted or overwritten.
        let backupURL = URL(fileURLWithPath: plan.backupDir)
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        try Data(oldIndex).write(to: backupURL.appendingPathComponent(Pedal.indexFile))
        // Every file to delete is copied first, even if the listing missed it; if it cannot be read it is not deleted.
        for n in Set(plan.deletes).union(Set(plan.writes.map(\.name)).intersection(names)).sorted() {
            emit(.log("Saving a copy of \(n)"))
            do {
                let d = try pedal.readFile(n, expectedSize: files.first { $0.name == n }?.size)
                try Data(d).write(to: backupURL.appendingPathComponent(n))
            } catch {
                if plan.deletes.contains(n) { throw error }   // never delete without a copy
                emit(.log("\(n) is not on the pedal; nothing to save"))
            }
        }

        // 3. Deletes, then writes, then the index (so the menu never lists a missing file).
        var step = 0
        for n in plan.deletes {
            step += 1
            emit(.progress("Deleting \(n)", step, steps))
            try pedal.deleteFile(n)
        }
        for (n, d) in sources {
            step += 1
            emit(.progress("Writing \(n)", step, steps))
            try pedal.writeFile(n, d)
            emit(.log(String(format: "Verified %@ (%d bytes, CRC32 %08x)", n, d.count, Codec.crc32(d))))
        }
        if let newIndex {
            step += 1
            emit(.progress("Writing effect index", step, steps))
            try pedal.writeFile(Pedal.indexFile, newIndex)
            emit(.log(String(format: "Verified effect index (CRC32 %08x)", Codec.crc32(newIndex))))
        }
        emit(.progress("All changes applied and verified", steps, steps))
    }
}
