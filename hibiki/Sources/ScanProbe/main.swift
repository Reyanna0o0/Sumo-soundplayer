import Foundation
import HibikiCore

// 开发用：拿真实目录跑一遍扫描器，看会规划成什么样
// 用法： swift run ScanProbe <目录路径>

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: ScanProbe <目录路径>")
    exit(2)
}

var rootPath = args[1]
if rootPath.hasSuffix("/") { rootPath.removeLast() }

let fm = FileManager.default
let rootURL = URL(fileURLWithPath: rootPath)
var files: [ScannedFile] = []
let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

if let en = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys,
                          options: [.skipsHiddenFiles, .skipsPackageDescendants],
                          errorHandler: { _, _ in true }) {
    let prefix = rootPath + "/"
    for case let u as URL in en {
        guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
        let abs = u.path
        guard abs.hasPrefix(prefix) else { continue }
        files.append(ScannedFile(relativePath: String(abs.dropFirst(prefix.count)),
                                 absolutePath: abs,
                                 size: Int64(v.fileSize ?? 0),
                                 modified: v.contentModificationDate ?? Date()))
    }
}

print("枚举文件数: \(files.count)")
let kinds = Dictionary(grouping: files, by: { $0.kind })
for k in [MediaKind.audio, .video, .subtitle, .image, .document, .archive, .unknown] {
    if let list = kinds[k], !list.isEmpty { print("  \(k.rawValue): \(list.count)") }
}

let planned = LibraryScanner.plan(files: files, sourceRoot: rootPath, options: ScanOptions())

print("\n扫描器判定作品数: \(planned.count)  ← 这个数字说明问题")
for w in planned {
    print("\n作品: 「\(w.title)」")
    print("  目录: \(w.folderRelativePath)")
    print("  RJ: \(w.rjCode ?? "-")  社团: \(w.circleName ?? "-")  声优: \(w.seiyuuName ?? "-")")
    print("  封面: \(w.coverPath.map { ($0 as NSString).lastPathComponent } ?? "无")")
    print("  台本: \(w.scriptPath.map { ($0 as NSString).lastPathComponent } ?? "无")")
    print("  台本候选: \(w.scriptCandidates.map { ($0 as NSString).lastPathComponent })")
    print("  曲目 \(w.tracks.count) 首（已归并变体）:")
    for t in w.tracks {
        let se = t.hasSoundEffects.map { $0 ? "SE有" : "SE无" } ?? "-"
        print("    - [\(t.trackNumber.map(String.init) ?? "?")] \(t.title.prefix(38))  \(t.fileType)/\(se)  变体\(t.variants.count)")
        if t.variants.count > 1 {
            for v in t.variants { print("         · \(v.label)  \(v.size/1024)KB") }
        }
    }
}
