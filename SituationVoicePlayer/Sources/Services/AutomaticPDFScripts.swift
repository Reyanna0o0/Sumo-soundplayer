import Foundation
import CryptoKit

/// 只自动保存可由作品内录音编号证明归属的正文。手动导入则仍允许选择任意音轨。
enum AutomaticPDFScripts {
    struct Document: Sendable {
        let relativePath: String
        let assignments: [ScriptImportAssignment]
        let edition: ScriptEdition
    }

    struct Result: Sendable {
        var reasons: [String: String] = [:]
        var documents: [Document] = []
        var forReview: Set<String> = []
    }

    struct Input: Sendable {
        let url: URL
        let relativePath: String
        let workRoot: String?

        static func sourceRelativePath(url: URL, sourceRoot: String) -> String? {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let root = URL(fileURLWithPath: sourceRoot).resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }

        static func scanned(path: String, sourceRoot: String, workRoot: String) -> Input? {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard url.pathExtension.lowercased() == "pdf", let relative = sourceRelativePath(url: url, sourceRoot: sourceRoot) else { return nil }
            return Input(url: url, relativePath: relative, workRoot: workRoot)
        }
    }

    static func ownedSourceName(_ record: WorkAttachmentRecord) -> String {
        "手动添加/\(record.id)/\(record.attachment.fileName)"
    }

    /// 旧版单选只保存文件名，批量使用作品内相对路径。只为作品内唯一的同名附件
    /// 提供这些别名；数据库还会核对版本一的全部台词及时间。
    static func legacyNames(for sourceNames: [String], attachments: [WorkAttachmentRecord]) -> [String: Set<String>] {
        let byName = Dictionary(grouping: attachments, by: { $0.attachment.fileName })
        var result: [String: Set<String>] = [:]
        for name in sourceNames where name.contains("/") {
            guard let possible = byName[(name as NSString).lastPathComponent], possible.count == 1,
                  let record = possible.first else { continue }
            let relative = record.attachment.relativePath
            let matches = record.assetRelativePath == nil
                ? name == relative || name.hasSuffix("/" + relative)
                : name == ownedSourceName(record)
            if matches {
                result[name] = Set([relative, record.attachment.fileName]).subtracting([name])
            }
        }
        return result
    }

    /// 与自动扫描使用同一来源名。某些作品把同一份 PDF 放在作品根目录和译本架上；
    /// 只合并能逐字节证实的同名副本，两个不同分盘内的文件仍各自独立。
    static func sourceName(for record: WorkAttachmentRecord, url: URL, lease: WorkAttachmentDirectoryLease,
                           siblings: [WorkAttachmentRecord]) async -> String {
        if record.assetRelativePath != nil { return ownedSourceName(record) }
        let original = Input.sourceRelativePath(url: url, sourceRoot: lease.accessedURL.path) ?? record.attachment.relativePath
        guard record.attachment.kind == .pdf else { return original }
        return await Task.detached(priority: .userInitiated) {
            let atRoot = record.attachment.relativePath == record.attachment.fileName
            let peers = siblings.filter {
                $0.id != record.id && $0.assetRelativePath == nil && $0.attachment.fileName == record.attachment.fileName
                    && ($0.attachment.relativePath == $0.attachment.fileName) != atRoot
                    && $0.attachment.byteCount == record.attachment.byteCount
            }
            let copies = peers.compactMap { peer -> ScriptEdition? in
                guard let other = WorkAttachmentFinder.fileURL(for: peer.attachment, in: lease.directory),
                      let path = Input.sourceRelativePath(url: other, sourceRoot: lease.accessedURL.path),
                      FileManager.default.contentsEqual(atPath: url.path, andPath: other.path) else { return nil }
                return ScriptEdition(path: path, digest: "identical", tracks: [])
            }
            guard copies.count == 1, let other = copies.first else { return original }
            return ScriptEdition.selection(from: [other, ScriptEdition(path: original, digest: "identical", tracks: [])]).first ?? original
        }.value
    }

    static func read(paths: [String], sourceRoot: String, workRoot: String, tracks: [TrackRecord]) -> Result {
        read(inputs: paths.compactMap { Input.scanned(path: $0, sourceRoot: sourceRoot, workRoot: workRoot) }, tracks: tracks)
    }

    static func read(inputs: [Input], tracks: [TrackRecord]) -> Result {
        var result = Result()
        let tracks = tracks.filter { !$0.isVideo }
        for input in inputs {
            let url = input.url
            let relative = input.relativePath
            let name = (relative as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            let scriptName = ["台本", "脚本", "script", "シナリオ", "台词", "セリフ"].contains(where: relative.lowercased().contains)
            let namedTrack = WorkScriptMatching.singleTrackNumber(in: name) != nil
                && ScriptSectioner.parseMarker((name as NSString).deletingPathExtension) != nil
            if !scriptName, ["小说", "小説", "漫畫", "漫画", "novel", "artbook"].contains(where: relative.lowercased().contains) {
                result.reasons[relative] = InterfaceLocalization.text("文件名标为小说或画册，保留在作品附件中。")
                continue
            }
            do {
                // 大画册只作为附件提供；用户明确选择的文件不受自动扫描的体积限制。
                let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes <= 64 * 1024 * 1024 else {
                    result.reasons[relative] = InterfaceLocalization.text("文件超过 64 MB，可手动打开并分配。")
                    if scriptName { result.forReview.insert(relative) }
                    continue
                }
                let scoped = input.workRoot.map { scope(tracks, for: url, workRoot: $0, fileName: name) } ?? contentScope(tracks, fileName: name)
                let interpretation = try autoreleasepool { () -> WorkScriptMatching? in
                    let document = try ScriptExtractor.extractDocument(from: url)
                    // 小说也可能有「第1章」。未标明是台本的 PDF 须有明确音轨标记。
                    let musical = document.text.range(of: #"(?im)^\s*[■●◆★☆◎▶►※▽▼\-—–\s]*(track|tr|トラック|とらっく)\s*[.．]?\s*[0-9０-９]{1,3}"#, options: .regularExpression) != nil
                    guard scriptName || musical || namedTrack else { return nil }
                    return WorkScriptMatching(document: document, fileName: name, candidates: scoped)
                }
                guard let interpretation else {
                    result.reasons[relative] = InterfaceLocalization.text("文件名和正文都没有明确的台本或音轨标记。")
                    continue
                }
                let sections = interpretation.assignableSections
                guard !sections.isEmpty, scriptName || namedTrack || sections.contains(where: { $0.trackNumber != nil }) else {
                    result.reasons[relative] = InterfaceLocalization.text("没有读到可分配的台词。")
                    if scriptName { result.forReview.insert(relative) }
                    continue
                }
                let plan = interpretation.suggestedAssignments
                if let unmatched = plan.first(where: { $0.trackID == nil }) {
                    result.forReview.insert(relative)
                    result.reasons[relative] = unmatched.explanation + "。"
                }
                let matches = plan.filter { $0.trackID != nil }
                if !matches.isEmpty {
                    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                    let digest = Data(SHA256.hash(data: bytes)).base64EncodedString()
                    let edition = ScriptEdition(path: relative, digest: digest, tracks: Set(sections.compactMap(\.trackNumber)))
                    result.documents.append(Document(relativePath: relative, assignments: matches, edition: edition))
                }
            } catch {
                result.reasons[relative] = error.localizedDescription
                if scriptName { result.forReview.insert(relative) }
                DebugLog.write("跳过 PDF 台本 \(name)：\(error.localizedDescription)")
            }
        }

        // 在每条音轨自己的候选内去重，分盘放置的台本不会被全局去重误删。
        var editionsByTrack: [Int64: [ScriptEdition]] = [:]
        for document in result.documents {
            for assignment in document.assignments {
                if let id = assignment.trackID { editionsByTrack[id, default: []].append(document.edition) }
            }
        }
        let selected = editionsByTrack.mapValues { ScriptEdition.selection(from: $0) }
        result.documents = result.documents.compactMap { document in
            let safe = document.assignments.filter { assignment in
                guard let id = assignment.trackID, let paths = selected[id] else { return false }
                if paths.isEmpty {
                    result.forReview.insert(document.relativePath)
                    result.reasons[document.relativePath] = InterfaceLocalization.text("多份不同的台本指向同一条音轨，需手动确认。")
                } else if !paths.contains(document.relativePath), result.reasons[document.relativePath] == nil {
                    result.reasons[document.relativePath] = InterfaceLocalization.text("这份台本有内容相同的副本，已合并处理。")
                }
                return paths.contains(document.relativePath)
            }
            return safe.isEmpty ? nil : Document(relativePath: document.relativePath, assignments: safe, edition: document.edition)
        }.sorted { left, right in
            if left.edition.preference != right.edition.preference {
                return left.edition.preference < right.edition.preference
            }
            return NaturalSort.compare(left.relativePath, right.relativePath)
        }
        return result
    }

    static func scope(_ tracks: [TrackRecord], for url: URL, workRoot: String, fileName: String? = nil) -> [TrackRecord] {
        // 台本与整套盘/特典在同一个子目录时，轨号只在那个子树内比较。
        let root = URL(fileURLWithPath: workRoot).resolvingSymlinksInPath().standardizedFileURL.path
        var parent = url.deletingLastPathComponent()
        var candidates = tracks
        while parent.path.hasPrefix(root + "/") {
            let prefix = parent.path + "/"
            let local = tracks.filter {
                URL(fileURLWithPath: $0.resolvedFilePath ?? $0.filePath).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(prefix)
            }
            if !local.isEmpty { candidates = local; break }
            parent.deleteLastPathComponent()
        }
        return contentScope(candidates, fileName: fileName ?? url.lastPathComponent)
    }

    static func contentScope(_ candidates: [TrackRecord], fileName: String) -> [TrackRecord] {
        let name = fileName.precomposedStringWithCanonicalMapping.lowercased()
        if !["後日談", "后日谈", "後日譚"].contains(where: name.contains),
           ["mainstory", "main_story", "本編", "本篇", "正篇", "正片"].contains(where: name.contains) {
            return candidates.filter { TrackCategorizer.classify(relativePath: $0.relativePath ?? $0.fileName) == .main }
        }
        return candidates
    }
}

struct WorkPDFMatchReport {
    struct File: Identifiable {
        let record: WorkAttachmentRecord
        let detail: String
        var id: Int64 { record.id }
    }

    let matchedCount: Int
    let files: [File]

    var summary: String {
        files.isEmpty ? InterfaceLocalization.text("作品内没有 PDF，可从手机「文件」中选择台本。") : InterfaceLocalization.text("找到 \(files.count) 个 PDF 文件，台本已匹配 \(matchedCount) 条音轨。")
    }
}
