import Foundation
import MS100BTKit

let usage = """
ms100bt — manage the effects of a ZOOM MS-100BT over Bluetooth.

Put the pedal in MENU → Bluetooth → PAIRING first.

Usage:
  ms100bt identify                       Identity and firmware version (read-only)
  ms100bt state                          File-system info, file list and effect index (read-only)
  ms100bt backup DIR [--only NAME…]      Copy files from the pedal to DIR (read-only)
  ms100bt apply PLAN.json [--dry-run]    Execute a change plan made by the GUI
  ms100bt pair                           Pair again (needed after an All Initialize)
  ms100bt zdl FILE.ZDL…                  Describe effect files (offline)
  ms100bt index FLST_SEQ.ZDT             Print an effect index (offline)

Options:
  --address XX-XX-XX-XX-XX-XX   Skip discovery
  --channel N                   RFCOMM channel (default: from SDP; 2 on the MS-100BT)
  --json                        Print events as JSON lines (used by the GUI)
  --verbose                     Log every SysEx message
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ f: String) -> Bool {
    if let i = args.firstIndex(of: f) { args.remove(at: i); return true }
    return false
}
func option(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let json = flag("--json")
let verbose = flag("--verbose")
let dryRun = flag("--dry-run")
let address = option("--address")
let channel = option("--channel").flatMap { UInt8($0) }
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func emit(_ e: EngineEvent) {
    if json {
        if let d = try? encoder.encode(e), let s = String(data: d, encoding: .utf8) { print(s); fflush(stdout) }
    } else {
        switch e.type {
        case "progress": print("[\(e.step ?? 0)/\(e.total ?? 0)] \(e.message ?? "")")
        case "state": break
        default: print(e.message ?? "")
        }
        fflush(stdout)
    }
}

func fail(_ error: Error) -> Never {
    emit(EngineEvent(type: "error", message: "\(error)"))
    exit(1)
}

guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

// Offline commands
switch command {
case "zdl":
    for path in args {
        guard let z = ZDLInfo.load(URL(fileURLWithPath: path)) else { print("\(path): not a ZDL"); continue }
        print(String(format: "%@  \"%@\"  %d B  cat %02X (%@)  header %d %@  v%@%@", z.fileName, z.displayName, z.size,
                     z.category, EffectCategory.name(z.category), z.headerSize, z.extendedTag, z.version, z.truncated ? "  TRUNCATED" : ""))
        if !z.parameters.isEmpty { print("    knobs: \(z.parameters.joined(separator: ", "))") }
        if !z.imports.isEmpty { print("    needs: \(z.imports.joined(separator: ", "))") }
    }
    exit(0)
case "index":
    guard let path = args.first, let d = FileManager.default.contents(atPath: path) else { print(usage); exit(2) }
    do {
        let idx = try EffectIndex(data: [UInt8](d))
        for c in idx.categories where !c.effects.filter({ !$0.isEmpty }).isEmpty {
            print(String(format: "%02X %@: ", c.id, EffectCategory.name(c.id)) + c.effects.filter { !$0.isEmpty }.joined(separator: " "))
        }
        print("(\(idx.usedBytes) of \(idx.fileSize) bytes used)")
    } catch { fail(error) }
    exit(0)
case "help", "--help", "-h":
    print(usage); exit(0)
default: break
}

// Commands that talk to the pedal
let engine = Engine(emit: emit)
do {
    try engine.connect(address: address, channel: channel, pair: command == "pair")
    engine.pedal.verbose = verbose
    switch command {
    case "identify", "pair":
        let i = engine.identity!
        emit(.log(String(format: "Model 0x%02X, mode %d, firmware %@", i.modelID, i.mode, i.firmware)))
    case "state":
        let s = try engine.readState()
        if json {
            emit(EngineEvent(type: "state", state: s))
        } else {
            print("Files: \(s.files.count)/\(Pedal.maxFiles), free \(s.freeBytes) of \(s.totalBytes) bytes, write block \(s.maxWriteSize)")
            for c in s.index.categories where !c.effects.filter({ !$0.isEmpty }).isEmpty {
                print(String(format: "%02X %@: ", c.id, EffectCategory.name(c.id)) + c.effects.filter { !$0.isEmpty }.joined(separator: " "))
            }
        }
    case "backup":
        guard let dir = args.first else { print(usage); exit(2) }
        let only = args.dropFirst().first == "--only" ? Array(args.dropFirst(2)) : nil
        try engine.backup(to: URL(fileURLWithPath: dir), only: only)
    case "apply":
        guard let path = args.first, let d = FileManager.default.contents(atPath: path) else { print(usage); exit(2) }
        let plan = try JSONDecoder().decode(ChangePlan.self, from: d)
        try engine.apply(plan, dryRun: dryRun)
    default:
        print(usage); exit(2)
    }
    engine.disconnect()
    emit(EngineEvent(type: "done", message: "OK"))
} catch {
    engine.disconnect()
    fail(error)
}
