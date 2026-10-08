import Foundation
import IOBluetooth

/// Runs the current run loop until `done` returns true or `seconds` elapse.
/// IOBluetooth delivers its callbacks on the run loop of the thread that opened the channel,
/// so all Bluetooth work in this package happens on one thread that keeps spinning here.
@discardableResult
public func spinRunLoop(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if done() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return done()
}

public enum TransportError: Error, CustomStringConvertible {
    case pedalNotFound
    case noSerialService
    case openFailed(IOReturn)
    case writeFailed(IOReturn)

    public var description: String {
        switch self {
        case .pedalNotFound: return "No ZOOM MS-100BT found. Put the pedal in MENU → Bluetooth → PAIRING."
        case .noSerialService: return "The pedal does not advertise the Serial Port service (UUID 0x1101)."
        case .openFailed(let r):
            return "Could not open the RFCOMM channel (IOReturn \(r)). If the pedal was factory-reset, "
                + "remove “ZOOM MS-100BT” in System Settings → Bluetooth and try again with the pedal in PAIRING."
        case .writeFailed(let r): return "Bluetooth write failed (IOReturn \(r))."
        }
    }
}

/// Finds the pedal and its Serial Port channel.
public enum Discovery {
    final class InquiryDelegate: NSObject, IOBluetoothDeviceInquiryDelegate {
        var found: [IOBluetoothDevice] = []
        var done = false
        func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
            if let device, !found.contains(where: { $0.addressString == device.addressString }) { found.append(device) }
        }
        func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) { done = true }
    }

    final class SDPDelegate: NSObject {
        var done = false
        @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) { done = true }
    }

    public static func looksLikePedal(_ d: IOBluetoothDevice) -> Bool {
        let n = (d.name ?? "").uppercased()
        return n.contains("MS-100") || n.contains("ZOOM MS")
    }

    /// Uses `address` if given, then paired devices, then a Bluetooth inquiry.
    public static func findPedal(address: String?, scanSeconds: Double = 15, log: (String) -> Void) -> IOBluetoothDevice? {
        if let address, let d = IOBluetoothDevice(addressString: address) { return d }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        if let d = paired.first(where: looksLikePedal) { return d }
        log("Scanning for the pedal for \(Int(scanSeconds)) s (MENU → Bluetooth → PAIRING)…")
        let delegate = InquiryDelegate()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: delegate) else { return nil }
        inquiry.inquiryLength = UInt8(min(scanSeconds, 48))
        inquiry.updateNewDeviceNames = true
        guard inquiry.start() == kIOReturnSuccess else { return nil }
        spinRunLoop(scanSeconds + 10) { delegate.done || delegate.found.contains(where: looksLikePedal) }
        inquiry.stop()
        return delegate.found.first(where: looksLikePedal)
    }

    /// RFCOMM channel of the SPP record (UUID 0x1101). On the MS-100BT this is the MIDI channel.
    public static func serialChannel(_ device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        let spp = IOBluetoothSDPUUID(uuid16: 0x1101)
        var ch: BluetoothRFCOMMChannelID = 0
        if let rec = device.getServiceRecord(for: spp), rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess { return ch }
        let delegate = SDPDelegate()
        if device.performSDPQuery(delegate) == kIOReturnSuccess { spinRunLoop(10) { delegate.done } }
        if let rec = device.getServiceRecord(for: spp), rec.getRFCOMMChannelID(&ch) == kIOReturnSuccess {
            // Opening the channel right after SDP fails; release the baseband link first.
            device.closeConnection()
            spinRunLoop(2)
            return ch
        }
        return nil
    }
}

/// RFCOMM link carrying raw SysEx bytes.
public final class RFCOMMLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    public let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    public private(set) var rx = Data()
    public private(set) var isOpen = false

    public init(device: IOBluetoothDevice) { self.device = device }

    public func open(channelID: BluetoothRFCOMMChannelID, attempts: Int = 3) throws {
        var result: IOReturn = kIOReturnError
        for attempt in 1...attempts {
            result = device.openRFCOMMChannelSync(&channel, withChannelID: channelID, delegate: self)
            if result == kIOReturnSuccess, channel != nil { isOpen = true; spinRunLoop(0.5); return }
            if attempt < attempts { spinRunLoop(2) }
        }
        throw TransportError.openFailed(result)
    }

    public func clearReceived() { rx.removeAll() }

    /// Sends bytes in MTU-sized pieces, like the official updater (SPPCommunication.sendAsync).
    public func send(_ bytes: [UInt8]) throws {
        guard let ch = channel else { throw TransportError.writeFailed(kIOReturnNotOpen) }
        let mtu = max(Int(ch.getMTU()), 16)
        var off = 0
        while off < bytes.count {
            var piece = Array(bytes[off..<min(off + mtu, bytes.count)])
            let r = ch.writeSync(&piece, length: UInt16(piece.count))
            guard r == kIOReturnSuccess else { throw TransportError.writeFailed(r) }
            off += piece.count
        }
    }

    public func close() {
        channel?.close()
        device.closeConnection()
        isOpen = false
        spinRunLoop(0.5)
    }

    public func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        rx.append(Data(bytes: dataPointer, count: dataLength))
    }

    public func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) { isOpen = false }
}

/// Explicit pairing (needed after an All Initialize on the pedal).
public final class Pairing: NSObject, IOBluetoothDevicePairDelegate {
    public private(set) var finished = false
    public private(set) var result: IOReturn = 0

    public func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin.data) { $0.copyBytes(from: Array("0000".utf8)) }
        (sender as? IOBluetoothDevicePair)?.replyPINCode(4, pinCode: &pin)
    }
    public func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }
    public func devicePairingFinished(_ sender: Any!, error: IOReturn) { result = error; finished = true }

    public static func pair(_ device: IOBluetoothDevice, timeout: Double = 60) -> Bool {
        let delegate = Pairing()
        guard let pair = IOBluetoothDevicePair(device: device) else { return false }
        pair.delegate = delegate
        guard pair.start() == kIOReturnSuccess else { return false }
        spinRunLoop(timeout) { delegate.finished }
        return device.isPaired()
    }
}
