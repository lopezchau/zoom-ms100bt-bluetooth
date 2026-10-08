import Foundation
import MS100BTKit

/// One effect file available on this Mac (stock corpus, custom effects, pedal backups, user folders).
struct LibraryItem: Identifiable, Hashable {
    enum Risk: Int, Comparable {
        case installed, low, community, untestedCategory, untestedHeader, tooBig, needsExpressionPedal, unsafeName, broken
        static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .installed: return "On pedal"
            case .low: return "Low risk"
            case .community: return "Community — test before relying on it"
            case .tooBig: return "Larger than 32 KB"
            case .unsafeName: return "Name longer than 8.3"
            case .untestedCategory: return "Not shown by the MS-100BT menu"
            case .untestedHeader: return "Untested header"
            case .needsExpressionPedal: return "Needs expression pedal"
            case .broken: return "Truncated — unusable"
            }
        }
    }

    let id: String               // path
    let url: URL
    let pedalName: String        // 8.3 name it gets on the pedal
    let source: String           // e.g. "MS-60B", "Custom: …", "Backup"
    let info: ZDLInfo

    var displayName: String { info.displayName }
    var category: UInt8 { info.category }
    var isSharedLibrary: Bool { info.category == EffectCategory.sharedLibrary }
    var isCommunity: Bool { source.hasPrefix("Community") }

    func risk(onPedal: Set<String>) -> Risk {
        if info.truncated { return .broken }
        if !info.hasSafeName { return .unsafeName }
        if onPedal.contains(pedalName) { return .installed }
        if info.category == 0x0B { return .needsExpressionPedal }
        if info.extendedTag == "BCAB" { return .untestedHeader }
        if !EffectCategory.confirmed.contains(info.category) && !isSharedLibrary { return .untestedCategory }
        // The 32 KB limit was measured for community-built effects; stock effects up to 42 KB (DualRev) work.
        if isCommunity && info.size > ZDLInfo.sizeLimit { return .tooBig }
        if isCommunity { return .community }
        return .low
    }
}

/// Scans folders of .ZDL files. Stock-corpus names carry a model prefix ("MS-60B_SVT.ZDL"),
/// which is stripped to get the name the effect must have on the pedal.
enum LibraryScanner {
    static let modelPrefixes = ["MS-60B", "MS-50G", "MS-70CDR", "B1Xon", "G1Xon", "B1on", "G1on"]

    static func pedalName(for file: String) -> (String, String?) {
        for p in modelPrefixes where file.hasPrefix(p + "_") {
            return (String(file.dropFirst(p.count + 1)), p)
        }
        return (file, nil)
    }

    static func scan(folder: URL, sourceLabel: String) -> [LibraryItem] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var items: [LibraryItem] = []
        for case let url as URL in e where url.pathExtension.uppercased() == "ZDL" {
            let (name, model) = pedalName(for: url.lastPathComponent)
            guard name.utf8.count <= 12, let info = ZDLInfo.load(url, as: name) else { continue }
            items.append(LibraryItem(id: url.path, url: url, pedalName: name.uppercased() == name ? name : name,
                                     source: model ?? sourceLabel, info: info))
        }
        return items
    }
}

/// Where the app keeps its data: ~/Library/Application Support/MS-100BT Manager
enum AppPaths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MS-100BT Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var stockLibrary: URL { support.appendingPathComponent("stock-library", isDirectory: true) }
    static var customEffects: URL { support.appendingPathComponent("custom-effects", isDirectory: true) }
    static var backups: URL { support.appendingPathComponent("backups", isDirectory: true) }
    static var plans: URL { support.appendingPathComponent("plans", isDirectory: true) }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }
}
