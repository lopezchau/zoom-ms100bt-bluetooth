import Foundation
import MS100BTKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // Library
    @Published var library: [LibraryItem] = []
    @Published var scanning = false
    @Published var extraFolders: [URL] = (UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []).map { URL(fileURLWithPath: $0) } {
        didSet { UserDefaults.standard.set(extraFolders.map(\.path), forKey: "extraFolders") }
    }

    // Pedal
    @Published var state: PedalState?
    @Published var draft: EffectIndex?
    @Published var pendingAdds: [String: LibraryItem] = [:]     // pedal name → source
    @Published var pendingRemovals: Set<String> = []
    @Published var address: String? = UserDefaults.standard.string(forKey: "pedalAddress") {
        didSet { UserDefaults.standard.set(address, forKey: "pedalAddress") }
    }

    // Activity
    @Published var busy: String?
    @Published var progress: Double?
    @Published var log: [String] = []
    @Published var alert: String?
    @Published var notice: String?

    private let runner = EngineRunner()

    // MARK: Derived values

    var onPedal: Set<String> { Set(state?.files.map(\.name) ?? []) }

    var filesAfter: Int? {
        guard let s = state else { return nil }
        let names = Set(s.files.map(\.name))
        return names.count - pendingRemovals.intersection(names).count + Set(pendingAdds.keys).subtracting(names).count
    }

    var bytesAfterEstimate: Int? {
        guard let s = state else { return nil }
        // The file system allocates in 4 KB blocks plus a small overhead per file.
        func cost(_ size: Int) -> Int { (size + 4095) / 4096 * 4096 + 512 }
        let removed = s.files.filter { pendingRemovals.contains($0.name) }.reduce(0) { $0 + cost($1.size) }
        let added = pendingAdds.values.reduce(0) { $0 + cost($1.info.size) }
        return s.freeBytes + removed - added
    }

    var hasChanges: Bool { !pendingAdds.isEmpty || !pendingRemovals.isEmpty || (draft != nil && draft != state?.index) }

    func item(named name: String) -> LibraryItem? {
        pendingAdds[name] ?? library.first { $0.pedalName == name && onPedal.contains(name) } ?? library.first { $0.pedalName == name }
    }

    func displayName(_ file: String) -> String { item(named: file)?.displayName ?? file.replacingOccurrences(of: ".ZDL", with: "") }

    func columns() -> [UInt8] {
        var ids = EffectCategory.confirmed + EffectCategory.experimental
        for c in draft?.categories ?? [] where !c.effects.filter({ !$0.isEmpty }).isEmpty && !ids.contains(c.id) && c.id != EffectCategory.sharedLibrary {
            ids.append(c.id)
        }
        return ids
    }

    func effects(in cat: UInt8) -> [String] {
        draft?.categories.first { $0.id == cat }?.effects.filter { !$0.isEmpty } ?? []
    }

    // MARK: Library

    func scanLibrary() {
        scanning = true
        var folders: [(URL, String)] = [(AppPaths.stockLibrary, "Stock"), (AppPaths.backups, "Backup")]
        let community = (try? FileManager.default.contentsOfDirectory(at: AppPaths.customEffects, includingPropertiesForKeys: nil)) ?? []
        for dir in community where dir.hasDirectoryPath {
            let name = dir.lastPathComponent
            let label = CommunitySource.all.first { "\($0.owner)-\($0.repo)" == name }?.label ?? "Custom: \(name)"
            folders.append((dir, label))
        }
        folders += extraFolders.map { ($0, $0.lastPathComponent) }
        Task.detached(priority: .userInitiated) {
            var items: [LibraryItem] = []
            var seen = Set<String>()
            for (folder, label) in folders {
                for it in LibraryScanner.scan(folder: folder, sourceLabel: label) {
                    // Same name + same bytes from several folders: keep one.
                    let key = "\(it.pedalName)|\(it.info.crc32)"
                    if seen.insert(key).inserted { items.append(it) }
                }
            }
            items.sort { ($0.category, $0.displayName.lowercased(), $0.source) < ($1.category, $1.displayName.lowercased(), $1.source) }
            let result = items
            await MainActor.run {
                self.library = result
                self.scanning = false
            }
        }
    }

    func addFolder(_ url: URL) {
        if !extraFolders.contains(url) { extraFolders.append(url) }
        scanLibrary()
    }

    /// Downloads the stock-effect corpus (830 files from the MS-50G/60B/70CDR/G1on/B1on families)
    /// with a sparse git clone of github.com/repeat98/ZoomMultistompZDL. Files stay on this Mac.
    func downloadStockLibrary() {
        let dest = AppPaths.stockLibrary
        busy = "Downloading the stock effect library…"
        progress = nil
        Task.detached {
            let fm = FileManager.default
            try? fm.removeItem(at: dest)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            func git(_ args: [String], in dir: URL) -> Int32 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = args
                p.currentDirectoryURL = dir
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { return -1 }
                p.waitUntilExit()
                return p.terminationStatus
            }
            var ok = git(["clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse",
                          "https://github.com/repeat98/ZoomMultistompZDL.git", "repo"], in: dest) == 0
            if ok { ok = git(["sparse-checkout", "set", "--no-cone", "stock_zdls/*"], in: dest.appendingPathComponent("repo")) == 0 }
            let succeeded = ok
            await MainActor.run {
                self.busy = nil
                if succeeded {
                    self.notice = "Stock effect library downloaded."
                    self.scanLibrary()
                } else {
                    self.alert = "Download failed. Check the internet connection and that git is available (xcode-select --install)."
                }
            }
        }
    }

    func downloadCommunityEffects() {
        busy = "Downloading community effects…"
        progress = nil
        Task {
            let (n, errors) = await CommunityDownloader.downloadAll(to: AppPaths.customEffects) { msg in
                Task { @MainActor in self.busy = msg }
            }
            self.busy = nil
            self.notice = "Downloaded \(n) community effects into \(AppPaths.customEffects.path)."
            if !errors.isEmpty { self.alert = "Some sources failed:\n" + errors.joined(separator: "\n") }
            self.scanLibrary()
        }
    }

    // MARK: Editing

    /// Adds an effect to its own category (the category stored in the file), at `index` if given.
    func add(_ item: LibraryItem, at index: Int? = nil, droppedOn column: UInt8? = nil) {
        guard var d = draft else { alert = "Connect to the pedal first."; return }
        if item.info.truncated { alert = "\(item.pedalName) is truncated and cannot be installed."; return }
        if !item.info.hasSafeName { alert = "\(item.pedalName): file names longer than 8.3 characters have frozen pedals at boot. Rename the file first."; return }
        if item.info.category == 0x0B { alert = "\(item.displayName) needs an expression pedal, which the MS-100BT does not have."; return }
        if !item.isSharedLibrary, item.info.effectID != 0,
           let clash = library.first(where: { onPedal.contains($0.pedalName) && $0.pedalName != item.pedalName
                                              && $0.info.category == item.info.category && $0.info.effectID == item.info.effectID
                                              && !pendingRemovals.contains($0.pedalName) }) {
            // The ID (bytes 64–65) is only unique within a category; stock effects in different categories share numbers.
            alert = "\(item.displayName) uses effect ID \(item.info.effectID) in \(EffectCategory.name(item.category)), which \(clash.displayName) (\(clash.pedalName)) on the pedal already uses. Remove that one first."
            return
        }
        if item.isSharedLibrary { pendingAdds[item.pedalName] = item; return }
        let cat = item.category
        if let column, column != cat {
            notice = "\(item.displayName) is a \(EffectCategory.name(cat)) effect, so it was added to \(EffectCategory.name(cat))."
        }
        d.remove(item.pedalName)
        if let i = d.categories.firstIndex(where: { $0.id == cat }) {
            let visible = d.categories[i].effects
            if let index, column == cat {
                // Map the visible index (blank records hidden) to the real position.
                let nonBlank = visible.enumerated().filter { !$0.element.isEmpty }.map(\.offset)
                let pos = index < nonBlank.count ? nonBlank[index] : visible.count
                d.categories[i].effects.insert(item.pedalName, at: pos)
            } else {
                d.categories[i].effects.append(item.pedalName)
            }
        } else {
            d.append(item.pedalName, to: cat)
        }
        draft = d
        pendingRemovals.remove(item.pedalName)
        if !onPedal.contains(item.pedalName) || item.info.crc32 != library.first(where: { $0.pedalName == item.pedalName && onPedal.contains($0.pedalName) })?.info.crc32 {
            pendingAdds[item.pedalName] = item
        }
        addDependencies(of: item)
    }

    /// Adds the shared libraries (e.g. CMN_BASS.ZDL) that provide symbols the effect imports.
    func addDependencies(of item: LibraryItem) {
        guard !item.info.imports.isEmpty else { return }
        let available = Set(library.filter { onPedal.contains($0.pedalName) || pendingAdds[$0.pedalName] != nil }.flatMap(\.info.exports))
        for sym in item.info.imports where !available.contains(sym) {
            let providers = library.filter { $0.isSharedLibrary && $0.info.exports.contains(sym) }
            guard let p = providers.first(where: { $0.source == item.source }) ?? providers.first else {
                notice = "\(item.displayName) needs \(sym), which no library file provides."
                continue
            }
            if pendingAdds[p.pedalName] == nil && !onPedal.contains(p.pedalName) {
                pendingAdds[p.pedalName] = p
                notice = "\(p.pedalName) was added too: \(item.displayName) needs it."
            }
        }
    }

    func remove(_ name: String) {
        guard var d = draft else { return }
        if name.uppercased().hasPrefix("CMN_") { alert = "\(name) is a shared library used by other effects; it cannot be removed here."; return }
        d.remove(name)
        draft = d
        if pendingAdds.removeValue(forKey: name) == nil, onPedal.contains(name) { pendingRemovals.insert(name) }
    }

    func move(in cat: UInt8, from: IndexSet, to: Int) {
        guard var d = draft, let i = d.categories.firstIndex(where: { $0.id == cat }) else { return }
        var visible = d.categories[i].effects.filter { !$0.isEmpty }
        visible.move(fromOffsets: from, toOffset: to)
        let blanks = d.categories[i].effects.filter { $0.isEmpty }
        d.categories[i].effects = blanks + visible
        draft = d
    }

    func discardChanges() {
        draft = state?.index
        pendingAdds = [:]
        pendingRemovals = []
    }

    // MARK: Pedal operations

    private func engineArgs() -> [String] { address.map { ["--address", $0] } ?? [] }

    private func handle(_ e: EngineEvent) {
        switch e.type {
        case "progress":
            busy = e.message
            if let s = e.step, let t = e.total, t > 0 { progress = Double(s) / Double(t) }
        case "state":
            if let s = e.state {
                state = s
                address = s.address
                draft = s.index
                pendingAdds = [:]
                pendingRemovals = []
            }
        case "error":
            alert = e.message
            log.append("ERROR: \(e.message ?? "")")
        default:
            if let m = e.message { log.append(m) }
        }
    }

    private func runEngine(_ args: [String], title: String, then: (() -> Void)? = nil) {
        guard !runner.isRunning else { return }
        busy = title
        progress = nil
        log.append("— \(title)")
        runner.run(args + engineArgs(), onEvent: { [weak self] in self?.handle($0) }) { [weak self] status in
            self?.busy = nil
            self?.progress = nil
            if status == 0 { then?() }
        }
    }

    func readPedal() { runEngine(["state"], title: "Reading the pedal…") }

    func pair() { runEngine(["pair"], title: "Pairing with the pedal…") }

    func backupPedal() {
        let dir = AppPaths.backups.appendingPathComponent("full-" + AppPaths.timestamp())
        runEngine(["backup", dir.path], title: "Backing up every file on the pedal…") { [weak self] in
            self?.notice = "Backup saved to \(dir.path)"
            self?.scanLibrary()
        }
    }

    func makePlan() throws -> ChangePlan {
        guard let s = state, let d = draft else { throw Pedal.PedalError.refused("not connected") }
        let indexBytes = d == s.index ? nil : try d.build()
        let writes = pendingAdds.values.sorted { $0.pedalName < $1.pedalName }.map { ChangePlan.Write(source: $0.url.path, name: $0.pedalName) }
        return ChangePlan(baseIndexCRC: s.indexCRC, deletes: pendingRemovals.sorted(), writes: writes, newIndex: indexBytes,
                          backupDir: AppPaths.backups.appendingPathComponent("before-change-" + AppPaths.timestamp()).path)
    }

    func apply(dryRun: Bool) {
        do {
            if let n = filesAfter, n > Pedal.maxFiles {
                alert = "The pedal holds at most \(Pedal.maxFiles) files; this change needs \(n). Remove \(n - Pedal.maxFiles) more effect(s)."
                return
            }
            let plan = try makePlan()
            try FileManager.default.createDirectory(at: AppPaths.plans, withIntermediateDirectories: true)
            let url = AppPaths.plans.appendingPathComponent("plan-" + AppPaths.timestamp() + ".json")
            try JSONEncoder().encode(plan).write(to: url)
            runEngine(["apply", url.path] + (dryRun ? ["--dry-run"] : []), title: dryRun ? "Checking the plan…" : "Applying changes…") { [weak self] in
                guard let self else { return }
                if dryRun {
                    self.notice = "Dry run OK — nothing was sent."
                } else {
                    self.notice = "All changes applied and verified. Restart the pedal to see them."
                    self.readPedal()
                }
            }
        } catch {
            alert = "\(error)"
        }
    }

    func cancel() { runner.cancel() }
}
