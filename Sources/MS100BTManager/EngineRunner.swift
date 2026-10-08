import Foundation
import MS100BTKit

/// Runs the bundled `ms100bt` engine as a child process and streams its JSON events.
/// Bluetooth needs a thread with a spinning run loop; a helper process keeps the UI responsive
/// and reuses exactly the code path that was verified on hardware.
final class EngineRunner {
    private var process: Process?

    static var helperURL: URL? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "ms100bt") { return u }
        // Development fallback: next to the GUI binary (swift run).
        let u = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ms100bt")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func run(_ arguments: [String], onEvent: @escaping (EngineEvent) -> Void, onExit: @escaping (Int32) -> Void) {
        guard let helper = EngineRunner.helperURL else {
            onEvent(EngineEvent(type: "error", message: "The ms100bt helper was not found inside the app bundle."))
            onExit(127)
            return
        }
        let p = Process()
        p.executableURL = helper
        p.arguments = arguments + ["--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        var buffer = Data()
        let decoder = JSONDecoder()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let event = (try? decoder.decode(EngineEvent.self, from: line))
                    ?? EngineEvent(type: "log", message: String(decoding: line, as: UTF8.self))
                DispatchQueue.main.async { onEvent(event) }
            }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { onExit(proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
        } catch {
            onEvent(EngineEvent(type: "error", message: "Could not start the engine: \(error.localizedDescription)"))
            onExit(126)
        }
    }

    func cancel() { process?.terminate() }
}
