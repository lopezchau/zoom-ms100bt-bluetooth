import Foundation

/// Community-built custom effects, downloaded at the user's request straight from each author's
/// repository (this project does not redistribute them). None of them has been confirmed on an
/// MS-100BT yet. Note: ZDLs built with the community linker embed small pieces of ZOOM runtime code;
/// see the authors' LICENSE / THIRD_PARTY_NOTICES files.
struct CommunitySource {
    let owner: String
    let repo: String
    let folder: String          // only .ZDL files under this path ("" = whole repo)
    let note: String

    var label: String { "Community: \(owner)/\(repo)" }
    var url: String { "https://github.com/\(owner)/\(repo)" }

    static let all: [CommunitySource] = [
        CommunitySource(owner: "matujuice", repo: "zoom-ms-zdl-effects-pack", folder: "dist/",
                        note: "MIT (see repo SCOPE). Tested on an MS-60B running MS-50G firmware — the closest known setup to the MS-100BT."),
        CommunitySource(owner: "themanro", repo: "ZoomMultistompZDL", folder: "dist/",
                        note: "MIT for src/custom, tools, docs, graphics (see repo LICENSE). Tested on MS-70CDR 2.10; README lists MS-100BT as unsupported (no reason given)."),
        CommunitySource(owner: "repeat98", repo: "ZoomMultistompZDL", folder: "dist/",
                        note: "README: repository code MIT unless a file says otherwise. Tested on MS-70CDR 2.10."),
        CommunitySource(owner: "marcfuentes", repo: "dustbox-zdl", folder: "",
                        note: "MIT. Built with the themanro toolchain."),
        CommunitySource(owner: "marcfuentes", repo: "silverst-zdl", folder: "",
                        note: "MIT. Not hardware-measured by the author."),
    ]
}

enum CommunityDownloader {
    struct Tree: Decodable {
        struct Entry: Decodable { let path: String; let type: String }
        let tree: [Entry]
    }

    /// Downloads every .ZDL of every source into `dest/<owner>-<repo>/`. Returns (files, errors).
    static func downloadAll(to dest: URL, progress: @escaping (String) -> Void) async -> (Int, [String]) {
        var count = 0
        var errors: [String] = []
        for src in CommunitySource.all {
            progress("Listing \(src.owner)/\(src.repo)…")
            let folder = dest.appendingPathComponent("\(src.owner)-\(src.repo)", isDirectory: true)
            do {
                let api = URL(string: "https://api.github.com/repos/\(src.owner)/\(src.repo)/git/trees/HEAD?recursive=1")!
                var req = URLRequest(url: api)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: req)
                let tree = try JSONDecoder().decode(Tree.self, from: data)
                let files = tree.tree.filter {
                    $0.type == "blob" && $0.path.uppercased().hasSuffix(".ZDL") && (src.folder.isEmpty || $0.path.hasPrefix(src.folder))
                        && !$0.path.contains("stock_zdls/") && !$0.path.contains("firmware/")
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for f in files {
                    progress("Downloading \(src.owner)/\(src.repo): \((f.path as NSString).lastPathComponent)")
                    let raw = URL(string: "https://raw.githubusercontent.com/\(src.owner)/\(src.repo)/HEAD/\(f.path)")!
                    let (bytes, resp) = try await URLSession.shared.data(from: raw)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    try bytes.write(to: folder.appendingPathComponent((f.path as NSString).lastPathComponent))
                    count += 1
                }
                let readme = "Source: \(src.url)\nDownloaded: \(Date())\nLicense / status: \(src.note)\n"
                try readme.write(to: folder.appendingPathComponent("SOURCE.txt"), atomically: true, encoding: .utf8)
            } catch {
                errors.append("\(src.owner)/\(src.repo): \(error.localizedDescription)")
            }
        }
        return (count, errors)
    }
}
