import AppKit
import MS100BTKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showApply = false

    var body: some View {
        NavigationSplitView {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            VStack(spacing: 0) {
                PedalHeader(showApply: $showApply)
                Divider()
                if model.state == nil {
                    ConnectPlaceholder()
                } else {
                    PedalBoard()
                }
                Divider()
                StatusBar()
            }
        }
        .sheet(isPresented: $showApply) { ApplySheet() }
        .alert("MS-100BT Manager", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.alert ?? "") }
        .onAppear { model.scanLibrary() }
    }
}

// MARK: - Library (left)

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var source = "All"
    @State private var hideInstalled = true
    @State private var hideRisky = false

    var sources: [String] { ["All"] + Array(Set(model.library.map(\.source))).sorted() }

    var filtered: [LibraryItem] {
        let on = model.onPedal
        return model.library.filter { it in
            let r = it.risk(onPedal: on)
            if hideInstalled && r == .installed { return false }
            if hideRisky && r > .low { return false }
            if r == .broken || r == .needsExpressionPedal { return false }
            if source != "All" && it.source != source { return false }
            if !search.isEmpty {
                let s = search.lowercased()
                return it.displayName.lowercased().contains(s) || it.pedalName.lowercased().contains(s)
                    || EffectCategory.name(it.category).lowercased().contains(s)
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search effects", text: $search).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("Source", selection: $source) { ForEach(sources, id: \.self) { Text($0) } }
                        .labelsHidden().frame(maxWidth: 150)
                    Toggle("Hide installed", isOn: $hideInstalled)
                    Toggle("Low risk only", isOn: $hideRisky)
                }
                .font(.caption)
                Text("\(filtered.count) of \(model.library.count) effects · drag onto a category →")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if model.library.isEmpty {
                EmptyLibrary()
            } else {
                List(filtered) { item in
                    LibraryRow(item: item)
                        .onDrag { NSItemProvider(object: item.id as NSString) }
                        .contextMenu {
                            Button("Add to pedal") { model.add(item) }.disabled(model.state == nil)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Download stock effect library (830 effects)…") { model.downloadStockLibrary() }
                    Button("Download community custom effects…") { model.downloadCommunityEffects() }
                    Button("Add folder of .ZDL files…") { pickFolder() }
                    Button("Open custom-effects folder") {
                        try? FileManager.default.createDirectory(at: AppPaths.customEffects, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppPaths.customEffects)
                    }
                    Divider()
                    Button("Rescan") { model.scanLibrary() }
                } label: { Label("Library", systemImage: "books.vertical") }
            }
        }
    }

    func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Add"
        if p.runModal() == .OK, let u = p.url { model.addFolder(u) }
    }
}

struct EmptyLibrary: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.down.forward").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.scanning ? "Scanning…" : "No effects yet").font(.headline)
            Text("Download the stock-effect corpus (830 ZOOM MultiStomp effects from the MS-50G, MS-60B, MS-70CDR, G1on and B1on families). The files are downloaded from github.com/repeat98/ZoomMultistompZDL and stay on this Mac.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Download effect library") { model.downloadStockLibrary() }.disabled(model.busy != nil)
            Button("Download community custom effects") { model.downloadCommunityEffects() }.disabled(model.busy != nil)
            Text("You can also add any folder of .ZDL files, such as a backup of your pedal.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxHeight: .infinity)
    }
}

struct RiskBadge: View {
    let risk: LibraryItem.Risk
    var color: Color {
        switch risk {
        case .installed: return .blue
        case .low: return .green
        case .community: return .purple
        case .untestedCategory, .untestedHeader, .tooBig: return .orange
        case .needsExpressionPedal, .unsafeName, .broken: return .red
        }
    }
    var body: some View {
        Text(risk.label).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15)).foregroundStyle(color).clipShape(Capsule())
    }
}

struct LibraryRow: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.displayName).fontWeight(.medium)
                Spacer()
                RiskBadge(risk: item.risk(onPedal: model.onPedal))
            }
            HStack(spacing: 6) {
                Text(EffectCategory.name(item.category))
                Text("·")
                Text(item.source)
                Text("·")
                Text(item.pedalName).monospaced()
                Text("·")
                Text("\(item.info.size / 1024) KB")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !item.info.parameters.isEmpty {
                Text(item.info.parameters.joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Pedal (right)

struct PedalHeader: View {
    @EnvironmentObject var model: AppModel
    @Binding var showApply: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.state == nil ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                .foregroundStyle(model.state == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading) {
                Text(model.state == nil ? "Not connected" : "ZOOM MS-100BT · firmware \(model.state!.identity.firmware)").font(.headline)
                if let s = model.state, let n = model.filesAfter, let free = model.bytesAfterEstimate {
                    Text("Files \(n)/\(Pedal.maxFiles) · free ≈ \(free / 1024) KB of \(s.totalBytes / 1024) KB")
                        .font(.caption).foregroundStyle(n > Pedal.maxFiles || free < 0 ? .red : .secondary)
                }
            }
            Spacer()
            Button { model.readPedal() } label: { Label(model.state == nil ? "Connect" : "Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.busy != nil)
            Button { model.backupPedal() } label: { Label("Back up", systemImage: "externaldrive") }
                .disabled(model.busy != nil || model.state == nil)
            Button("Discard") { model.discardChanges() }.disabled(!model.hasChanges || model.busy != nil)
            Button { showApply = true } label: { Label("Apply…", systemImage: "square.and.arrow.down.on.square") }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasChanges || model.busy != nil)
        }
        .padding(10)
    }
}

struct ConnectPlaceholder: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "guitars").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Connect your MS-100BT").font(.title3)
            Text("On the pedal: press knob 1 (MENU) → Bluetooth → PAIRING. Then click Connect.\nReading the effect list takes about a minute.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Button("Connect") { model.readPedal() }.buttonStyle(.borderedProminent)
                Button("Pair again") { model.pair() }
            }
            .disabled(model.busy != nil)
            Text("After an All Initialize the pedal forgets its pairing: remove “ZOOM MS-100BT” in System Settings → Bluetooth, then connect again.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PedalBoard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.columns(), id: \.self) { cat in CategoryColumn(cat: cat) }
            }
            .padding(10)
        }
    }
}

struct CategoryColumn: View {
    @EnvironmentObject var model: AppModel
    let cat: UInt8
    @State private var targeted = false

    var experimental: Bool { EffectCategory.experimental.contains(cat) }

    var body: some View {
        let names = model.effects(in: cat)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(EffectCategory.name(cat)).font(.headline)
                Spacer()
                Text("\(names.count)").foregroundStyle(.secondary)
            }
            if experimental {
                Text("Untested on the MS-100BT").font(.caption2).foregroundStyle(.orange)
            }
            List {
                ForEach(names, id: \.self) { name in
                    PedalEffectRow(name: name)
                }
                .onMove { model.move(in: cat, from: $0, to: $1) }
                .onInsert(of: [UTType.plainText]) { index, providers in
                    load(providers) { item in model.add(item, at: index, droppedOn: cat) }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(minHeight: 380)
        }
        .frame(width: 230)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
            load(providers) { item in model.add(item, droppedOn: cat) }
            return true
        }
    }

    func load(_ providers: [NSItemProvider], _ action: @escaping (LibraryItem) -> Void) {
        for p in providers {
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let path = obj as? String else { return }
                DispatchQueue.main.async {
                    if let item = model.library.first(where: { $0.id == path }) { action(item) }
                }
            }
        }
    }
}

struct PedalEffectRow: View {
    @EnvironmentObject var model: AppModel
    let name: String
    @State private var hover = false

    var body: some View {
        let added = model.pendingAdds[name] != nil
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.displayName(name)).lineLimit(1)
                Text(name).font(.caption2).foregroundStyle(.secondary).monospaced()
            }
            Spacer()
            if added { Text("new").font(.caption2).foregroundStyle(.green) }
            if hover {
                Button { model.remove(name) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                    .buttonStyle(.plain).help("Remove from the pedal")
            }
        }
        .onHover { hover = $0 }
        .contextMenu { Button("Remove from pedal", role: .destructive) { model.remove(name) } }
    }
}

// MARK: - Status and apply

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            if let b = model.busy {
                if let p = model.progress { ProgressView(value: p).frame(width: 120) } else { ProgressView().controlSize(.small) }
                Text(b).lineLimit(1)
                Button("Cancel") { model.cancel() }.controlSize(.small)
            } else if let n = model.notice {
                Image(systemName: "info.circle")
                Text(n).lineLimit(2)
                Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            } else {
                Text(model.log.last ?? "Ready").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.hasChanges {
                Text("Pending: +\(model.pendingAdds.count) −\(model.pendingRemovals.count)").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

struct ApplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var risky: [LibraryItem] { model.pendingAdds.values.filter { $0.risk(onPedal: []) > .low && !$0.isSharedLibrary } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apply changes to the pedal").font(.title2)
            if let n = model.filesAfter {
                Text("Files after the change: \(n)/\(Pedal.maxFiles)").foregroundStyle(n > Pedal.maxFiles ? .red : .primary)
            }
            GroupBox("Install (\(model.pendingAdds.count))") {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.pendingAdds.values.sorted { $0.pedalName < $1.pedalName }) { it in
                            Text("\(it.displayName) — \(it.pedalName) · \(EffectCategory.name(it.category)) · from \(it.source)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
            GroupBox("Remove (\(model.pendingRemovals.count))") {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.pendingRemovals.sorted(), id: \.self) { Text("\(model.displayName($0)) — \($0)") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 100)
            }
            if !risky.isEmpty {
                Label("Untested on the MS-100BT: \(risky.map(\.displayName).joined(separator: ", ")). Keep the backup handy.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text("Before changing anything the app saves the current index and every file it deletes. Each written file is read back and compared. Firmware is never touched.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Dry run") { model.apply(dryRun: true); dismiss() }
                Button("Apply") { model.apply(dryRun: false); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled((model.filesAfter ?? 0) > Pedal.maxFiles)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
