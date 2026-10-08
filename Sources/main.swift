// MS-100BT Probe — paso 2: prueba de conexión SOLO LECTURA.
//
// Busca el pedal por Bluetooth clásico, abre el canal RFCOMM del perfil
// Serial Port (UUID 0x1101) y envía la consulta de identidad MIDI universal
// (F0 7E 00 06 01 F7). No envía ningún comando de escritura.
//
// Uso: MS100BTProbe [--log RUTA] [--address XX-XX-XX-XX-XX-XX] [--channel N] [--scan SEGUNDOS]

import Foundation
import IOBluetooth

// MARK: - Registro

var logHandle: FileHandle?
var quiet = false

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(s)\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    logHandle?.write(line.data(using: .utf8)!)
}

func hex(_ d: Data) -> String { d.map { String(format: "%02X", $0) }.joined(separator: " ") }

/// Procesa el bucle de eventos hasta que `done` sea verdadero o pase el tiempo.
@discardableResult
func spin(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return done()
}

// MARK: - Delegado Bluetooth

final class Probe: NSObject, IOBluetoothDeviceInquiryDelegate, IOBluetoothRFCOMMChannelDelegate {
    var found: [IOBluetoothDevice] = []
    var inquiryDone = false
    var sdpDone = false
    var sdpStatus: IOReturn = 0
    var rx = Data()
    var channelOpen = false
    var channelClosed = false

    // Búsqueda
    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let device else { return }
        if !found.contains(where: { $0.addressString == device.addressString }) { found.append(device) }
        log("  encontrado: \(device.name ?? "(sin nombre)")  [\(device.addressString ?? "?")]  clase=0x\(String(device.classOfDevice, radix: 16))")
    }
    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        guard let device else { return }
        log("  nombre actualizado: \(device.name ?? "?")  [\(device.addressString ?? "?")]")
    }
    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        log("Búsqueda terminada (error=\(error), abortada=\(aborted))")
        inquiryDone = true
    }

    // SDP (protocolo informal: performSDPQuery llama a este selector)
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        sdpStatus = status
        sdpDone = true
    }

    // RFCOMM
    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        log("Canal RFCOMM abierto (status=\(error))")
        channelOpen = (error == kIOReturnSuccess)
    }
    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let d = Data(bytes: dataPointer, count: dataLength)
        rx.append(d)
        if !quiet { log("RX (\(dataLength) bytes): \(hex(d))") }
    }
    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        log("Canal RFCOMM cerrado")
        channelClosed = true
    }
}

// MARK: - Interpretación de respuestas (según el actualizador oficial)

func describeIdentityReply(_ d: Data) {
    // Esperado: F0 7E <canal> 06 02 52 <ID> 00 <modo> ... F7
    let b = [UInt8](d)
    guard let start = b.firstIndex(of: 0xF0), b.count - start >= 9 else { return }
    let m = Array(b[start...])
    guard m[1] == 0x7E, m[3] == 0x06, m[4] == 0x02 else { return }
    log("== Respuesta de identidad ==")
    log("  fabricante: 0x\(String(format: "%02X", m[5])) \(m[5] == 0x52 ? "(ZOOM)" : "")")
    log("  ID de modelo: 0x\(String(format: "%02X", m[6]))  (el actualizador acepta 0x5D o 0x5E)")
    log("  byte de modo: 0x\(String(format: "%02X", m[8]))  (1 = funcionamiento normal; 0 = probablemente modo actualización)")
    if m.count > 10 {
        let tail = m[9..<(m.count - 1)]
        let ascii = String(bytes: tail.filter { $0 >= 0x20 && $0 < 0x7F }, encoding: .ascii) ?? ""
        log("  resto: \(hex(Data(tail)))  ascii=\"\(ascii)\"")
    }
}

// MARK: - Programa principal

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if let path = arg("--log") {
    FileManager.default.createFile(atPath: path, contents: nil)
    logHandle = FileHandle(forWritingAtPath: path)
}

log("MS-100BT Probe (solo lectura) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

let probe = Probe()

// 1. Dispositivos ya emparejados
let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
log("Dispositivos emparejados: \(paired.count)")
for d in paired { log("  emparejado: \(d.name ?? "?")  [\(d.addressString ?? "?")]") }

func looksLikeZoom(_ d: IOBluetoothDevice) -> Bool {
    let n = (d.name ?? "").uppercased()
    return n.contains("MS-100") || n.contains("ZOOM")
}

var target: IOBluetoothDevice?
if let addr = arg("--address") {
    target = IOBluetoothDevice(addressString: addr)
    log("Usando dirección indicada: \(addr)")
} else {
    target = paired.first(where: looksLikeZoom)
}

// 2. Búsqueda si no está emparejado
if target == nil {
    let secs = Double(arg("--scan") ?? "15") ?? 15
    log("Buscando dispositivos Bluetooth durante \(Int(secs)) s… (en el pedal: MENU → Bluetooth → PAIRING)")
    let inquiry = IOBluetoothDeviceInquiry(delegate: probe)!
    inquiry.inquiryLength = UInt8(min(secs, 48))
    inquiry.updateNewDeviceNames = true
    let r = inquiry.start()
    if r != kIOReturnSuccess { log("No se pudo iniciar la búsqueda (IOReturn \(r)). ¿Bluetooth encendido y permiso concedido?") }
    spin(secs + 10) { probe.inquiryDone || probe.found.contains(where: looksLikeZoom) }
    inquiry.stop()
    target = probe.found.first(where: looksLikeZoom)
}

guard let device = target else {
    log("No se encontró ningún dispositivo ZOOM / MS-100BT. Fin.")
    exit(2)
}
log("Objetivo: \(device.name ?? "?") [\(device.addressString ?? "?")]")

// 3. Consulta SDP para encontrar el canal del Serial Port Profile
var channelID: BluetoothRFCOMMChannelID = 0
if let c = arg("--channel"), let n = UInt8(c) {
    channelID = n
    log("Usando canal RFCOMM indicado: \(n)")
} else {
    log("Consultando servicios SDP…")
    let r = device.performSDPQuery(probe)
    if r == kIOReturnSuccess { spin(10) { probe.sdpDone } }
    log("SDP terminado (status=\(probe.sdpStatus), lanzado=\(r))")
    for rec in (device.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
        var ch: BluetoothRFCOMMChannelID = 0
        let hasCh = rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess
        log("  servicio: \(rec.getServiceName() ?? "(sin nombre)")\(hasCh ? "  canal RFCOMM \(ch)" : "")")
    }
    let spp = IOBluetoothSDPUUID(uuid16: 0x1101)
    if let rec = device.getServiceRecord(for: spp), rec.getRFCOMMChannelID(&channelID) == kIOReturnSuccess {
        log("Serial Port Profile (0x1101) en canal RFCOMM \(channelID)")
    } else {
        log("No se encontró el servicio Serial Port (0x1101). Puedes reintentar con --channel N usando un canal de la lista.")
        exit(3)
    }
    // Abrir el canal justo después del SDP falla con kIOReturnError; soltar el enlace y esperar.
    device.closeConnection()
    spin(2.0)
}

// 4. Abrir canal RFCOMM (con reintentos)
var channel: IOBluetoothRFCOMMChannel?
var openResult: IOReturn = kIOReturnError
for attempt in 1...3 {
    openResult = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: probe)
    if openResult == kIOReturnSuccess { break }
    log("Intento \(attempt) de abrir el canal falló (IOReturn \(openResult)); reintentando…")
    spin(2.0)
}
guard openResult == kIOReturnSuccess, let ch = channel else {
    log("No se pudo abrir el canal RFCOMM (IOReturn \(openResult)).")
    exit(4)
}
log("Conectado. MTU=\(ch.getMTU())")
spin(1.0)

func send(_ bytes: [UInt8]) {
    var b = bytes
    let r = ch.writeSync(&b, length: UInt16(b.count))
    if !quiet || r != kIOReturnSuccess { log("TX: \(hex(Data(bytes)))  (IOReturn \(r))") }
}

// 5. Consulta de identidad (la misma que envía el actualizador oficial)
send([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7])
spin(5) { probe.rx.contains(0xF7) }

if probe.rx.isEmpty {
    log("Sin respuesta al canal 0x00; probando con canal 'todos' (0x7F)…")
    send([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7])
    spin(5) { probe.rx.contains(0xF7) }
}

let identityOK = !probe.rx.isEmpty
if identityOK {
    describeIdentityReply(probe.rx)
} else {
    log("El pedal no respondió a la consulta de identidad.")
}

// 6. (Opcional, --fs) Consultas de SOLO LECTURA al sistema de archivos.
//    Solo se envían comandos que leen: info FS, espacio en disco y listado.
//    Nada de abrir/escribir/borrar/cerrar archivos ni comandos de firmware.

let dev: UInt8 = 0x5E

/// Envía un mensaje y devuelve los SysEx completos recibidos (hasta `timeout`).
func request(_ label: String, _ body: [UInt8], timeout: Double = 3) -> [[UInt8]] {
    probe.rx.removeAll()
    log("— \(label)")
    send([0xF0, 0x52, 0x00, dev] + body + [0xF7])
    spin(timeout) { probe.rx.last == 0xF7 }
    spin(0.2)  // por si llega un segundo mensaje pegado
    var msgs: [[UInt8]] = []
    var cur: [UInt8] = []
    for b in probe.rx {
        if b == 0xF0 { cur = [] }
        cur.append(b)
        if b == 0xF7 { msgs.append(cur); cur = [] }
    }
    if msgs.isEmpty { log("   (sin respuesta)") }
    for m in msgs {
        let ascii = String(bytes: m.map { ($0 >= 0x20 && $0 < 0x7F) ? $0 : 0x2E }, encoding: .ascii) ?? ""
        log("   RX: \(hex(Data(m)))  |\(ascii)|")
    }
    return msgs
}

func u35(_ m: [UInt8], _ at: Int) -> UInt32? {
    guard m.count >= at + 5 else { return nil }
    var v: UInt32 = 0
    for i in 0..<5 { v |= UInt32(m[at + i] & 0x7F) << (7 * UInt32(i)) }
    return v
}

if identityOK && args.contains("--fs") {
    log("== Consultas de sistema de archivos (solo lectura) ==")
    let ack: [UInt8] = [0x60, 0x05, 0x00]

    // Info FS (lo que el actualizador usa para conocer el tamaño de bloque)
    let info = request("Info FS (60 02)", [0x60, 0x02])
    _ = request("ACK (60 05 00)", ack)
    if let m = info.first(where: { $0.count > 25 && $0[5] == 0x04 && $0[6] == 0x02 }), let sz = u35(m, 20) {
        log("   → tamaño máximo de bloque de escritura (maxFFSWriteSize) = \(sz) bytes")
    }

    // Espacio en disco (comando de zoom-zt2)
    let du = request("Espacio en disco (60 29)", [0x60, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00])
    if let m = du.first(where: { $0.count > 21 && $0[5] == 0x04 }), let total = u35(m, 11), let free = u35(m, 16) {
        log("   → total=\(total) bytes, libre=\(free) bytes")
    }

    // Listado de archivos
    var files: [String] = []
    var first = true
    for _ in 0..<400 {
        let op: UInt8 = first ? 0x25 : 0x26
        let r = request(first ? "Buscar primero (60 25 *)" : "Buscar siguiente (60 26 *)",
                        [0x60, op, 0x00, 0x00, 0x2A, 0x00], timeout: 2)
        first = false
        guard let m = r.first(where: { $0.count > 16 && $0[5] == 0x04 }) else { break }
        let nameBytes = m[15..<min(m.count - 1, 28)].prefix { $0 != 0 }
        let name = String(bytes: nameBytes, encoding: .ascii) ?? ""
        if name.isEmpty || files.contains(name) { break }
        files.append(name)
    }
    _ = request("Terminar búsqueda (60 27)", [0x60, 0x27])
    log("== Archivos encontrados: \(files.count) ==")
    for f in files { log("   \(f)") }
}

// 7. (Opcional, --backup DIR [--only NOMBRE] [--chunk N]) Respaldo: descarga archivos del pedal.
//    Solo usa apertura en modo LECTURA (60 20 02), lectura (60 22), ACK (60 05 00) y cierre (60 21 / 60 09),
//    igual que zoom-zt2. Nunca escribe ni borra.

let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}
/// CRC32 estándar (zlib).
func crc32(_ d: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

func u7x5(_ v: UInt32) -> [UInt8] { (0..<5).map { UInt8((v >> (7 * UInt32($0))) & 0x7F) } }

/// 7→8 bits: byte de bits altos (bit 6 = 1.er byte) seguido de hasta 7 bytes.
func unpack7(_ p: ArraySlice<UInt8>) -> [UInt8] {
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

func splitMsgs(_ d: Data) -> [[UInt8]] {
    var msgs: [[UInt8]] = [], cur: [UInt8] = []
    for b in d {
        if b == 0xF0 { cur = [] }
        cur.append(b)
        if b == 0xF7 { msgs.append(cur); cur = [] }
    }
    return msgs
}

/// Envía un mensaje ZOOM y espera hasta recibir uno que cumpla `until`.
func transact(_ body: [UInt8], timeout: Double = 4, until: ([UInt8]) -> Bool) -> [[UInt8]] {
    probe.rx.removeAll()
    send([0xF0, 0x52, 0x00, dev] + body + [0xF7])
    var msgs: [[UInt8]] = []
    spin(timeout) { msgs = splitMsgs(probe.rx); return msgs.contains(where: until) }
    if !quiet { for m in msgs { log("   RX: \(hex(Data(m.prefix(48))))\(m.count > 48 ? " … (\(m.count) bytes)" : "")") } }
    return msgs
}

func isFs(_ m: [UInt8], sub: UInt8, fn: UInt8? = nil) -> Bool {
    m.count >= 7 && m[4] == 0x60 && m[5] == sub && (fn == nil || m[6] == fn!)
}
let isAckReply: ([UInt8]) -> Bool = { isFs($0, sub: 0x03) }
func ack() -> Bool { transact([0x60, 0x05, 0x00], until: isAckReply).contains(where: isAckReply) }

/// Lista los archivos del pedal (nombre, tamaño).
func listFiles() -> [(String, Int)] {
    var files: [(String, Int)] = []
    var op: UInt8 = 0x25
    for _ in 0..<500 {
        let r = transact([0x60, op, 0x00, 0x00, 0x2A, 0x00], timeout: 3) { isFs($0, sub: 0x04) || isFs($0, sub: 0x03) }
        op = 0x26
        guard let m = r.first(where: { isFs($0, sub: 0x04) && $0.count > 35 }) else { break }
        let name = String(bytes: m[15..<28].prefix { $0 != 0 }, encoding: .ascii) ?? ""
        let size = Int(u35(m, 30) ?? 0)
        if name.isEmpty || files.contains(where: { $0.0 == name }) { break }
        files.append((name, size))
    }
    _ = transact([0x60, 0x27], timeout: 2, until: isAckReply)
    return files
}

enum ReadError: Error { case openFailed(String), noData(Int), badCRC(Int), sizeMismatch(Int, Int) }

func readFile(_ name: String, expected: Int?, chunk: Int) throws -> [UInt8] {
    // Abrir en modo lectura (02)
    let openBody: [UInt8] = [0x60, 0x20, 0x02] + [UInt8](repeating: 0, count: 9) + Array(name.utf8) + [0x00]
    let r = transact(openBody) { isFs($0, sub: 0x04, fn: 0x20) || isFs($0, sub: 0x03) }
    guard let om = r.first(where: { isFs($0, sub: 0x04, fn: 0x20) && $0.count > 16 }) else {
        throw ReadError.openFailed(r.map { hex(Data($0)) }.joined(separator: " / "))
    }
    let handle = Array(om[11..<16])
    _ = ack()

    var data: [UInt8] = []
    defer {
        // Cerrar siempre
        _ = transact([0x60, 0x21] + handle, timeout: 3, until: isAckReply)
        _ = transact([0x60, 0x09], timeout: 2) { _ in true }
    }
    for _ in 0..<10_000 {
        // Secuencia observada: lectura → respuesta corta (sub 04 fn 22, 22 bytes);
        // ACK → mensaje de datos (sub 04 fn 22, con datos 8→7 y CRC); ACK → sub 03.
        let isDataMsg: ([UInt8]) -> Bool = { isFs($0, sub: 0x04, fn: 0x22) && $0.count >= 17 && $0[7] == 0x01 }
        let r1 = transact([0x60, 0x22] + handle + u7x5(UInt32(chunk))) { isFs($0, sub: 0x04, fn: 0x22) || isFs($0, sub: 0x03) }
        var m = r1.first(where: isDataMsg)
        if m == nil {
            let r2 = transact([0x60, 0x05, 0x00]) { isDataMsg($0) || isAckReply($0) }
            m = r2.first(where: isDataMsg)
        }
        guard let m else {
            if data.isEmpty || expected.map({ data.count < $0 }) == true { throw ReadError.noData(data.count) }
            break
        }
        let length = Int(m[9]) | (Int(m[10]) << 7)
        _ = ack()
        if length == 0 { break }
        let packed = m[11..<(m.count - 6)]
        let block = Array(unpack7(packed).prefix(length))
        let sum = u35(m, m.count - 6) ?? 0
        guard block.count == length, sum ^ 0xFFFFFFFF == crc32(block) else { throw ReadError.badCRC(data.count) }
        data += block
        if let e = expected, data.count >= e { break }
        if length < chunk { break }
    }
    if let e = expected, data.count != e { throw ReadError.sizeMismatch(data.count, e) }
    return data
}

if identityOK, let backupDir = arg("--backup") {
    let chunk = Int(arg("--chunk") ?? "512") ?? 512
    try? FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
    var targets: [(String, Int?)]
    if let only = arg("--only") {
        targets = [(only, nil)]
    } else {
        quiet = true
        log("Listando archivos…")
        targets = listFiles().map { ($0.0, Optional($0.1)) }
        log("\(targets.count) archivos para respaldar")
    }
    var manifest = "# nombre tamaño crc32\n"
    var failed: [String] = []
    let t0 = Date()
    for (i, (name, size)) in targets.enumerated() {
        let t = Date()
        do {
            let d = try readFile(name, expected: size, chunk: chunk)
            try Data(d).write(to: URL(fileURLWithPath: backupDir).appendingPathComponent(name))
            let line = String(format: "%@ %d %08x", name, d.count, crc32(d))
            manifest += line + "\n"
            log(String(format: "[%d/%d] OK  %@  (%.1f s)", i + 1, targets.count, line, Date().timeIntervalSince(t)))
        } catch {
            failed.append(name)
            log("[\(i + 1)/\(targets.count)] FALLÓ \(name): \(error)")
        }
    }
    try? manifest.write(toFile: (backupDir as NSString).appendingPathComponent("MANIFEST.txt"), atomically: true, encoding: .utf8)
    log(String(format: "Respaldo terminado en %.0f s. OK=%d, fallidos=%d %@", Date().timeIntervalSince(t0),
               targets.count - failed.count, failed.count, failed.joined(separator: " ")))
}

// 8. Cerrar limpiamente
ch.close()
device.closeConnection()
spin(1.0)
log("Fin de la prueba.")
exit(identityOK ? 0 : 5)
