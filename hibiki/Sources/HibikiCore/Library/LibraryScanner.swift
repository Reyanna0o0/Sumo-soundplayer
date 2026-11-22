import Foundation

/// 扫描器输入：一个已经枚举出来的文件（不碰文件系统，方便测试）
public struct ScannedFile: Equatable, Sendable {
    /// 相对存储源根目录的路径，例如 `社团名/作品名/01.mp3`
    public var relativePath: String
    public var absolutePath: String
    public var size: Int64
    public var modified: Date

    public init(relativePath: String, absolutePath: String, size: Int64, modified: Date) {
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.size = size
        self.modified = modified
    }

    public var fileName: String { (relativePath as NSString).lastPathComponent }
    public var fileExtension: String { (relativePath as NSString).pathExtension.lowercased() }
    public var kind: MediaKind { MediaExtensions.kind(forExtension: fileExtension) }
    public var directoryRelativePath: String { (relativePath as NSString).deletingLastPathComponent }

    var isSubtitle: Bool { SubtitleFormat.from(fileExtension: fileExtension) != nil }

    /// 路径的所有层级组件
    public var pathComponentsRelative: [String] {
        relativePath.split(separator: "/").map(String.init)
    }
}

// MARK: - 变体

/// 音声作品里同一个内容的"版本"。
///
/// 真实作品几乎都会提供多种组合，比如：
/// ```
/// 本編SEあり/mp3/Tr1.mp3      本編SEあり/wav/Tr1.wav
/// 本編SEなし/mp3/Tr1.mp3      本編SEなし/wav/Tr1.wav
/// ```
/// 这 4 个文件是**同一段内容**。全部列出来只会让用户困惑，
/// 必须归并成一个"逻辑曲目"，再让用户选择用哪个版本。
public struct TrackVariant: Equatable, Sendable, Identifiable {
    public var id: String { filePath }
    public var filePath: String
    public var fileName: String
    public var fileType: String
    public var size: Int64
    /// 是否带音效（nil = 目录里没有标明）
    public var hasSoundEffects: Bool?
    /// 是否无损（wav / flac / aiff / alac）
    public var isLossless: Bool
    /// 该变体所在的分组标签，用于界面显示，例如 "SEあり / wav"
    public var label: String
}

/// 成品的曲目（已选定一个变体）
public struct ScannedTrack: Equatable, Sendable {
    public var fileName: String
    public var filePath: String
    public var relativePath: String
    public var fileType: String
    public var isVideo: Bool
    public var title: String
    public var trackNumber: Int?
    public var size: Int64
    public var modified: Date
    /// 这一首的所有可选版本（含被选中的这个）
    public var variants: [TrackVariant]
    /// 内容类型（正片 / 特典 / 语音消息 / 闲聊 / 效果音）
    public var category: TrackCategory

    public var alternativeCount: Int { max(0, variants.count - 1) }
    public var hasSoundEffects: Bool? {
        variants.first { $0.filePath == filePath }?.hasSoundEffects
    }
    public var isLossless: Bool {
        variants.first { $0.filePath == filePath }?.isLossless ?? false
    }
}

/// 一个作品
public struct ScannedWork: Equatable, Sendable {
    /// Directory identity normally; with filesAsWorks, the complete media file path.
    /// Use LibraryPathResolver.workDirectory to locate companion files in that mode.
    public var folderRelativePath: String
    public var folderAbsolutePath: String
    public var title: String
    public var rjCode: String?
    public var circleName: String?
    public var seiyuuName: String?
    public var coverPath: String?
    public var scriptPath: String?
    /// 相对**作品目录**的封面路径（推荐存这个）
    public var coverRelativePath: String?
    /// 相对**作品目录**的台本路径（推荐存这个）
    public var scriptRelativePath: String?
    /// 所有台本候选（简体/繁体/日文原版）
    public var scriptCandidates: [String]
    public var subtitlePaths: [String]
    public var tracks: [ScannedTrack]

    public var trackCount: Int { tracks.count }
    public var totalSize: Int64 { tracks.reduce(0) { $0 + $1.size } }
}

// MARK: - 选项

public struct ScanOptions: Sendable {
    /// 小于这个体积的文件当垃圾忽略。
    /// 默认 32KB —— 音声作品里的短语音消息可能只有几百 KB，
    /// 门槛设太高会把正常内容误杀（实测 256KB 会漏掉合法的短语音）。
    public var minimumFileSize: Int64
    /// 是否把视频文件当曲目收录
    public var includeVideos: Bool
    /// 是否收录特典目录
    public var includeBonus: Bool
    /// 排除的相对目录
    public var excludedFolderPrefixes: [String]
    /// 分类规则
    public var classificationRules: [ClassificationRule]
    /// 优先选带音效的版本（否则优先无音效）
    public var preferSoundEffects: Bool
    /// 优先选无损版本
    public var preferLossless: Bool
    /// 独立管理不同编码；同一编码的音效版本沿用原来的偏好。
    public var separateAudioFormats: Bool
    /// 台本语言偏好
    public enum ScriptPreference: String, Sendable {
        case simplifiedChinese
        case traditionalChinese
        case japanese
        case any
    }
    /// 作品边界策略
    public enum Grouping: String, Sendable {
        /// 自动判断（默认）
        case automatic
        /// 整个所选目录就是一个作品
        case singleWork
        /// 每个子目录是一个作品
        case childrenAsWorks
        /// 递归每个音频/视频文件是一个作品，不归并编码或音效变体。
        case filesAsWorks
    }
    public var grouping: Grouping
    public var scriptPreference: ScriptPreference

    public init(
        minimumFileSize: Int64 = 32 * 1024,
        includeVideos: Bool = false,
        includeBonus: Bool = true,
        excludedFolderPrefixes: [String] = [],
        classificationRules: [ClassificationRule] = [],
        preferSoundEffects: Bool = true,
        preferLossless: Bool = true,
        separateAudioFormats: Bool = false,
        grouping: Grouping = .automatic,
        scriptPreference: ScriptPreference = .simplifiedChinese
    ) {
        self.minimumFileSize = minimumFileSize
        self.includeVideos = includeVideos
        self.includeBonus = includeBonus
        self.excludedFolderPrefixes = excludedFolderPrefixes
        self.classificationRules = classificationRules
        self.preferSoundEffects = preferSoundEffects
        self.preferLossless = preferLossless
        self.separateAudioFormats = separateAudioFormats
        self.grouping = grouping
        self.scriptPreference = scriptPreference
    }
}

// MARK: - 扫描器

/// 把"一堆文件"整理成"作品 + 曲目"。
///
/// 两个关键判断：
///
/// **① 作品边界**：一个作品可能是一整个目录（里面有本編/特典/台本），
/// 也可能一个目录下挂着很多作品。靠"像不像一个作品"来判断：
/// 有 Readme、有台本 PDF、有 `本編` 子目录、有封面图 —— 满足任一条，
/// 就把这个目录整体当成一个作品，不再往下切。
///
/// **② 变体归并**：同一个内容常同时提供 `SEあり/SEなし` × `mp3/wav` 四种组合，
/// 归并成一个逻辑曲目，默认选「带音效 + 无损」，其余作为备选保留。
public enum LibraryScanner {

    public static func plan(
        files: [ScannedFile],
        sourceRoot: String,
        options: ScanOptions = ScanOptions()
    ) -> [ScannedWork] {
        if options.grouping == .filesAsWorks {
            return individualFileWorks(files: files, sourceRoot: sourceRoot, options: options)
        }
        let roots = workRoots(files: files, sourceRoot: sourceRoot, options: options)
        var works = roots.compactMap { workRoot in
            makeWork(workRoot: workRoot, allFiles: files, sourceRoot: sourceRoot, options: options)
        }
        .sorted { NaturalSort.compare($0.folderRelativePath, $1.folderRelativePath) }
        // 自动模式有时把 wav/ 本身当作作品。它是唯一音频目录时，同级字幕也属于这次导入。
        if options.grouping == .automatic, roots.count == 1, let only = roots.first,
           MediaExtensions.kind(forExtension: only) == .audio, !works.isEmpty {
            works[0].subtitlePaths = files.filter(\.isSubtitle).map(\.absolutePath)
            let siblingPDFs = files.filter { $0.fileExtension == "pdf" }.map(\.absolutePath)
            works[0].scriptCandidates = Array(Set(works[0].scriptCandidates + siblingPDFs)).sorted()
        }
        return works
    }

    // MARK: - 作品边界

    /// 返回每个作品的"根目录相对路径"（空串表示源根目录本身就是一个作品）。
    ///
    /// 判定规则（用真实作品验证过）：
    /// - 用户显式指定策略时听用户的
    /// - 自动模式：如果根目录下**有 ≥2 个各自装着音频的子目录**，
    ///   就认为用户导入的是"资料库根目录"，每个子目录是一个作品；
    ///   否则（根目录自己就有音频、或有 Readme、或有 `本編`/`特典` 这种子目录），
    ///   整个目录算一个作品。
    ///
    /// 为什么不用"像不像作品"的评分制：真实作品里 `【特典】/SEあり/` 这类
    /// 中间层会让评分误判，实测把 1 个作品拆成 13 个。宁可用更笨但更稳的规则。
    static func workRoots(files: [ScannedFile], sourceRoot: String, options: ScanOptions) -> [String] {
        let mediaFiles = files.filter { $0.kind == .audio || $0.kind == .video }
        guard !mediaFiles.isEmpty else { return [] }

        switch options.grouping {
        case .singleWork:
            return [""]
        case .childrenAsWorks:
            return immediateSubdirectories(withAudio: mediaFiles)
        case .filesAsWorks:
            // plan handles this mode without treating file identities as folders.
            return []
        case .automatic:
            break
        }

        let hasAudioDirectlyInRoot = mediaFiles.contains { !$0.relativePath.contains("/") }

        let hasReadmeDirectlyInRoot = files.contains { file in
            !file.relativePath.contains("/") && file.fileName.lowercased().hasPrefix("readme")
        }

        let hasMainOrBonusFolderAtTopLevel = mediaFiles.contains { file in
            let components = file.pathComponentsRelative
            guard components.count >= 2 else { return false }
            let firstLevel = components[0].lowercased()
            return isMainFolder(firstLevel) || isBonusFolder(firstLevel)
        }

        let children = immediateSubdirectories(withAudio: mediaFiles)

        // 根目录自己就有音频 / 有 Readme / 有"本編·特典"这类一级子目录 → 整个目录是一个作品
        if hasAudioDirectlyInRoot || hasReadmeDirectlyInRoot || hasMainOrBonusFolderAtTopLevel {
            return [""]
        }

        // 有多个各自装着音频的子目录 → 用户导入的是资料库根目录
        if children.count >= 2 {
            return children
        }

        // 只有一个子目录装着音频 → 以更具体的那个为准（除非它叫「本編」这类分层目录名）
        if children.count == 1, let only = children.first {
            let name = (only as NSString).lastPathComponent.lowercased()
            if !isMainFolder(name) && !isBonusFolder(name) {
                return [only]
            }
        }

        return [""]
    }

    /// 根目录下"自己（任意深度）装着音频"的一级子目录
    static func immediateSubdirectories(withAudio mediaFiles: [ScannedFile]) -> [String] {
        var result = Set<String>()
        for file in mediaFiles {
            let components = file.pathComponentsRelative
            guard components.count >= 2 else { continue }
            result.insert(components[0])
        }
        return result.sorted()
    }

    /// 判断某个目录（相对前缀）像不像"一个作品"的根。
    ///
    /// 这里所有信号都要看**目录层级**：
    /// - Readme 必须直接躺在根目录里
    /// - `本編` / `特典` 要看**一级子目录名**，而不是文件名
    ///   （否则一个装着多个作品的库根目录会因为每个作品里都有"本編"而被误判）
    static func looksLikeWorkRoot(prefix: String, files: [ScannedFile]) -> Bool {
        var signals = 0
        var countedMainFolders = Set<String>()
        var countedBonusFolders = Set<String>()

        for file in files {
            let relative: String
            if prefix.isEmpty {
                relative = file.relativePath
            } else if file.relativePath == prefix {
                relative = ""
            } else if file.relativePath.hasPrefix(prefix + "/") {
                relative = String(file.relativePath.dropFirst(prefix.count + 1))
            } else {
                continue
            }
            guard !relative.isEmpty else { continue }

            let components = relative.split(separator: "/").map(String.init)
            let depth = components.count - 1
            let fileName = file.fileName.lowercased()

            // 信号 1：根目录下的 Readme
            if depth == 0, fileName.hasPrefix("readme") { signals += 2 }

            // 信号 2：台本 PDF（一级以内）
            if depth <= 1, file.fileExtension == "pdf" { signals += 2 }

            // 信号 3/4：一级子目录名是不是"本編"/"特典"
            if let firstLevelDir = components.first.map({ $0.lowercased() }), components.count >= 2 {
                if isMainFolder(firstLevelDir), !countedMainFolders.contains(firstLevelDir) {
                    countedMainFolders.insert(firstLevelDir)
                    signals += 2
                }
                if isBonusFolder(firstLevelDir), !countedBonusFolders.contains(firstLevelDir) {
                    countedBonusFolders.insert(firstLevelDir)
                    signals += 2
                }
            }

            // 信号 5：封面类图片（一级以内）
            if depth <= 1, file.kind == .image, isCoverLikeName(fileName) { signals += 1 }
        }

        return signals >= 2
    }

    static func relativeDepth(of path: String, under prefix: String) -> Int {
        let trimmed = prefix.isEmpty ? path : String(path.dropFirst(prefix.count + 1))
        return trimmed.split(separator: "/").count - 1
    }

    static func isMainFolder(_ name: String) -> Bool {
        name.contains("本編") || name.contains("本编") || name.contains("main")
            || name.hasPrefix("tr") || name.contains("本篇")
    }

    static func isBonusFolder(_ name: String) -> Bool {
        name.contains("特典") || name.contains("おまけ") || name.contains("omake")
            || name.contains("bonus") || name.contains("限定")
    }

    static func isCoverLikeName(_ name: String) -> Bool {
        ["cover", "folder", "jacket", "package", "キービジュアル", "keyvisual",
         "ジャケット", "パッケージ", "表紙", "表纸", "main"].contains { name.contains($0) }
    }

    // MARK: - 组装一个作品

    /// A conservative companion rule shared by import, ZIP and later attachment
    /// refreshes. Never search another directory or turn a document/image into a work.
    /// Exact stem (optionally a language suffix or media extension) wins. A lone
    /// media file may own remaining companions; in a multi-media directory only
    /// explicitly named common cover images are shared, never anonymous scripts.
    public static func files(forIndividualMedia media: ScannedFile, in files: [ScannedFile], retainingCompanions: [String] = []) -> [ScannedFile] {
        let siblings = files.filter { $0.directoryRelativePath == media.directoryRelativePath }
        let mediaFiles = siblings.filter { $0.kind == .audio || $0.kind == .video }
        let retained = Set(retainingCompanions.filter { !$0.contains("/") && $0 != "." && $0 != ".." })
        var ownersByName: [String: Set<String>] = [:]
        for file in mediaFiles {
            for name in [file.fileName, (file.fileName as NSString).deletingPathExtension] {
                ownersByName[normalizedCompanionName(name), default: []].insert(file.relativePath)
            }
        }
        return siblings.filter { candidate in
            if candidate.relativePath == media.relativePath { return true }
            if candidate.kind == .audio || candidate.kind == .video { return false }
            guard candidate.isSubtitle || WorkAttachmentFinder.kind(forExtension: candidate.fileExtension) != nil else { return false }
            // Explicitly paired/stored companions survive a media rename. This
            // never reaches another directory or adopts another media file.
            if retained.contains(candidate.fileName) { return true }
            let rawStem = (candidate.fileName as NSString).deletingPathExtension
            let stem = companionStem(candidate)
            // An exact media stem ending in .en/.ja wins over interpreting that
            // suffix as language for a different recording in the same directory.
            let owners = ownersByName[normalizedCompanionName(rawStem)] ?? ownersByName[normalizedCompanionName(stem)]
            if let owners { return owners.contains(media.relativePath) }
            // A format-specific companion must not fall back onto another format.
            if MediaExtensions.isLibraryMedia(stem) { return false }
            if mediaFiles.count == 1 { return true }
            return candidate.kind == .image && ["cover", "folder", "jacket", "front", "封面", "表紙", "表纸"].contains(rawStem.lowercased())
        }
    }

    private static func normalizedCompanionName(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    private static func companionStem(_ candidate: ScannedFile) -> String {
        var stem = (candidate.fileName as NSString).deletingPathExtension
        let suffix = (stem as NSString).pathExtension.lowercased()
        if SubtitleSidecarFinder.languageHints.contains(suffix) { stem = (stem as NSString).deletingPathExtension }
        return stem
    }

    private static func companion(_ candidate: ScannedFile, matches media: ScannedFile) -> Bool {
        let names = Set([media.fileName, (media.fileName as NSString).deletingPathExtension].map(normalizedCompanionName))
        return names.contains(normalizedCompanionName((candidate.fileName as NSString).deletingPathExtension))
            || names.contains(normalizedCompanionName(companionStem(candidate)))
    }

    private static func individualFileWorks(files: [ScannedFile], sourceRoot: String, options: ScanOptions) -> [ScannedWork] {
        let directories = Dictionary(grouping: files, by: \.directoryRelativePath)
        return files.compactMap { media -> ScannedWork? in
            guard media.kind == .audio || (options.includeVideos && media.kind == .video) else { return nil }
            let companions = self.files(forIndividualMedia: media, in: directories[media.directoryRelativePath] ?? [])
            guard var work = makeWork(workRoot: media.directoryRelativePath, allFiles: companions,
                                      sourceRoot: sourceRoot, options: options), work.tracks.count == 1 else { return nil }
            let title = (media.fileName as NSString).deletingPathExtension
            let classification = FolderClassifier.classify(name: title, rules: options.classificationRules)
            work.title = classification.cleanedTitle.isEmpty ? title : classification.cleanedTitle
            work.rjCode = classification.rjCode
            work.circleName = classification.circle.first
            work.seiyuuName = classification.seiyuu.isEmpty ? nil : classification.seiyuu.joined(separator: "、")
            let namedImages = companions.filter { $0.kind == .image && $0.size >= 4 * 1024 && companion($0, matches: media) }
            if let cover = pickCover(images: namedImages) {
                work.coverPath = cover
                work.coverRelativePath = relativeToWork(cover, workAbsolute: work.folderAbsolutePath)
            }
            // Unique identity includes nested path and extension; physical paths
            // already point at the real media and relative paths at its parent.
            work.folderRelativePath = media.relativePath
            work.folderAbsolutePath = media.absolutePath
            return work
        }.sorted { NaturalSort.compare($0.folderRelativePath, $1.folderRelativePath) }
    }

    static func makeWork(
        workRoot: String,
        allFiles: [ScannedFile],
        sourceRoot: String,
        options: ScanOptions
    ) -> ScannedWork? {
        // 1) 取出属于这个作品的文件
        let scoped = allFiles.filter { file in
            if workRoot.isEmpty { return true }
            return file.relativePath == workRoot || file.relativePath.hasPrefix(workRoot + "/")
        }

        // 2) 音频（含可选的视频），过滤掉太小的与排除目录
        let audioFiles = scoped.filter { file in
            let kind = file.kind
            guard kind == .audio || (options.includeVideos && kind == .video) else { return false }
            guard file.size >= options.minimumFileSize else { return false }
            if !options.includeBonus {
                let components = file.pathComponentsRelative
                if components.contains(where: { isBonusFolder($0.lowercased()) }) { return false }
            }
            if isExcluded(file.relativePath, prefixes: options.excludedFolderPrefixes) { return false }
            return true
        }

        guard !audioFiles.isEmpty else { return nil }

        // 3) 目录名 → 作品信息
        let folderAbsolute = workRoot.isEmpty
            ? sourceRoot
            : joinRelative(sourceRoot, workRoot)
        let folderName = workRoot.isEmpty
            ? (sourceRoot as NSString).lastPathComponent
            : (workRoot as NSString).lastPathComponent

        var classification = FolderClassifier.classify(name: folderName, rules: options.classificationRules)
        if classification.cleanedTitle.isEmpty { classification.cleanedTitle = folderName }

        // 4) 变体归并
        let tracks = groupVariants(audioFiles, workRoot: workRoot, options: options)

        // 5) 封面与台本
        let images = scoped.filter { $0.kind == .image && $0.size >= 4 * 1024 }
        let scripts = scoped.filter { file in
            guard ["pdf", "txt", "docx", "epub"].contains(file.fileExtension) else { return false }
            // Readme / 说明文件不是台本
            let name = file.fileName.lowercased()
            if name.hasPrefix("readme") || name.hasPrefix("はじめに") || name.hasPrefix("お読み") {
                return false
            }
            return true
        }

        let coverAbsolute = pickCover(images: images)
        let scriptAbsolute = pickScript(scripts: scripts, preference: options.scriptPreference)

        return ScannedWork(
            folderRelativePath: workRoot,
            folderAbsolutePath: folderAbsolute,
            title: classification.cleanedTitle,
            rjCode: classification.rjCode,
            circleName: classification.circle.first,
            seiyuuName: classification.seiyuu.isEmpty ? nil : classification.seiyuu.joined(separator: "、"),
            coverPath: coverAbsolute,
            scriptPath: scriptAbsolute,
            coverRelativePath: relativeToWork(coverAbsolute, workAbsolute: folderAbsolute),
            scriptRelativePath: relativeToWork(scriptAbsolute, workAbsolute: folderAbsolute),
            scriptCandidates: scripts
                .sorted { NaturalSort.compare($0.relativePath, $1.relativePath) }
                .map(\.absolutePath),
            subtitlePaths: scoped.filter(\.isSubtitle).map(\.absolutePath),
            tracks: tracks
        )
    }

    // MARK: - 变体归并

    static func groupVariants(
        _ files: [ScannedFile],
        workRoot: String,
        options: ScanOptions
    ) -> [ScannedTrack] {
        struct GroupKey: Hashable {
            let name: String
            let fileExtension: String?
        }
        let groups = Dictionary(grouping: files) { file in
            GroupKey(name: logicalTrackKey(file, workRoot: workRoot),
                     fileExtension: options.separateAudioFormats ? file.fileExtension : nil)
        }

        var tracks: [ScannedTrack] = []

        for (key, group) in groups {
            let variants = group.map { makeVariant($0, workRoot: workRoot) }
            guard let chosen = chooseVariant(variants, options: options) else { continue }

            let sortedVariants = variants.sorted { a, b in
                if a.isLossless != b.isLossless { return a.isLossless }
                if a.hasSoundEffects != b.hasSoundEffects { return a.hasSoundEffects == true }
                return NaturalSort.compare(a.fileName, b.fileName)
            }

            let displayName = chosen.fileName
            // 注意：分类只看**作品目录内部**的路径。
            // 作品文件夹本身的名字（如「【早期購入特典付き】」）里可能含"特典"，
            // 如果拿整条路径去分类，会把整个作品的所有曲目都判成特典。
            guard let chosenFile = group.first(where: { $0.absolutePath == chosen.filePath }) else { continue }
            let workRelativePath = workRoot.isEmpty ? chosenFile.relativePath
                : String(chosenFile.relativePath.dropFirst(workRoot.count + 1))
            tracks.append(
                ScannedTrack(
                    fileName: displayName,
                    filePath: chosen.filePath,
                    relativePath: workRelativePath,
                    fileType: chosen.fileType,
                    isVideo: MediaExtensions.video.contains(chosen.fileType),
                    title: FolderNameParser.trackTitle(from: displayName),
                    trackNumber: FolderNameParser.trackNumber(from: displayName)
                        ?? FolderNameParser.trackNumber(from: key.name),
                    size: chosen.size,
                    modified: chosenFile.modified,
                    variants: sortedVariants,
                    // 整个源目录作为作品时沿用原分类依据，外层作品名也可能带有「特典」。
                    category: TrackCategorizer.classify(relativePath: workRoot.isEmpty ? displayName : workRelativePath)
                )
            )
        }

        // 排序：先按类型（正片在最前），同类型内按轨号，再自然排序
        return tracks.sorted { a, b in
            if a.category.sortOrder != b.category.sortOrder {
                return a.category.sortOrder < b.category.sortOrder
            }
            switch (a.trackNumber, b.trackNumber) {
            case let (x?, y?) where x != y:
                return x < y
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return NaturalSort.compare(a.fileName, b.fileName)
            }
        }
    }

    /// 逻辑曲目键：去掉扩展名与"变体标记"后的名字
    static func logicalTrackKey(_ file: ScannedFile, workRoot: String) -> String {
        let base = (file.fileName as NSString).deletingPathExtension
        var cleaned = base

        // 去掉形如 【SEなし_xxx】/【SEなし】 的前缀
        cleaned = cleaned.replacingOccurrences(
            of: "^【?\\s*(SEなし|SE無し|SEあり|SE付き|ノーマル|通常版)[_＿]?",
            with: "",
            options: .regularExpression
        )
        // 去掉剩下的成对括号与标点、空白
        cleaned = cleaned.replacingOccurrences(of: "[【】\\[\\]（）()\\s_＿・,、。]", with: "", options: .regularExpression)
        cleaned = cleaned.lowercased()

        // 目录层的变体标记也要忽略（SEあり/ 与 SEなし/ 下的同名文件应归并）
        return cleaned.isEmpty ? file.fileName.lowercased() : cleaned
    }

    static func makeVariant(_ file: ScannedFile, workRoot: String) -> TrackVariant {
        let components = file.pathComponentsRelative
        var hasSE: Bool?
        for component in components {
            let lower = component.lowercased()
            if lower.contains("seなし") || lower.contains("se無し") || lower.contains("nose")
                || lower.contains("なし") && lower.contains("se") {
                hasSE = false
            } else if lower.contains("seあり") || lower.contains("se付き") || lower.contains("se有り") {
                hasSE = true
            }
        }
        // 文件名里的标记优先
        let name = file.fileName.lowercased()
        if name.contains("seなし") || name.contains("se無し") {
            hasSE = false
        } else if name.contains("seあり") || name.contains("se付き") {
            hasSE = true
        }

        let losslessTypes: Set<String> = ["wav", "flac", "aiff", "aif", "alac", "ape", "wv", "dsf", "dff"]
        let isLossless = losslessTypes.contains(file.fileExtension)

        var parts: [String] = []
        if let hasSE { parts.append(hasSE ? "SEあり" : "SEなし") }
        parts.append(file.fileExtension)
        let label = parts.joined(separator: " / ")

        return TrackVariant(
            filePath: file.absolutePath,
            fileName: file.fileName,
            fileType: file.fileExtension,
            size: file.size,
            hasSoundEffects: hasSE,
            isLossless: isLossless,
            label: label
        )
    }

    static func chooseVariant(_ variants: [TrackVariant], options: ScanOptions) -> TrackVariant? {
        guard !variants.isEmpty else { return nil }
        return variants.max { a, b in
            score(a, options: options) < score(b, options: options)
        }
    }

    static func score(_ variant: TrackVariant, options: ScanOptions) -> Int {
        var score = 0
        if options.preferSoundEffects {
            if variant.hasSoundEffects == true { score += 100 }
            else if variant.hasSoundEffects == false { score += 0 }
        } else {
            if variant.hasSoundEffects == false { score += 100 }
        }
        if options.preferLossless, variant.isLossless { score += 50 }
        // 同等条件下取更大的文件（通常码率更高）
        score += Int(min(40, variant.size / 20_000_000))
        return score
    }

    // MARK: - 封面 / 台本

    static func pickCover(images: [ScannedFile]) -> String? {
        guard !images.isEmpty else { return nil }
        // 优先"封面类"命名
        let preferred = images.filter { isCoverLikeName($0.fileName.lowercased()) }
        let pool = preferred.isEmpty ? images : preferred
        // 同分时取文件名自然排序第一，且体积较大者优先（避免小图标）
        return pool
            .sorted { a, b in
                if a.size != b.size { return a.size > b.size }
                return NaturalSort.compare(a.relativePath, b.relativePath)
            }
            .first?
            .absolutePath
    }

    static func pickScript(scripts: [ScannedFile], preference: ScanOptions.ScriptPreference) -> String? {
        guard !scripts.isEmpty else { return nil }

        func matches(_ file: ScannedFile, _ keywords: [String]) -> Bool {
            let name = file.fileName.lowercased()
            return keywords.contains { name.contains($0) }
        }

        let simplified = ["簡体字", "简体字", "简体", "簡体", "_zh", "zh-cn", "chs", "sc"]
        let traditional = ["繁体字", "繁體字", "繁体", "繁體", "zh-tw", "cht", "tc"]
        let japanese = ["台本", "script", "シナリオ", "せりふ", "セリフ"]

        let order: [[String]]
        switch preference {
        case .simplifiedChinese:
            order = [simplified, japanese, traditional]
        case .traditionalChinese:
            order = [traditional, japanese, simplified]
        case .japanese:
            order = [japanese, simplified, traditional]
        case .any:
            order = [japanese, simplified, traditional]
        }

        for keywords in order {
            if let hit = scripts.first(where: { matches($0, keywords) }) {
                return hit.absolutePath
            }
        }
        return scripts.sorted { NaturalSort.compare($0.relativePath, $1.relativePath) }.first?.absolutePath
    }

    // MARK: - 工具

    static func isExcluded(_ relativePath: String, prefixes: [String]) -> Bool {
        guard !prefixes.isEmpty else { return false }
        return prefixes.contains { prefix in
            relativePath == prefix || relativePath.hasPrefix(prefix + "/")
        }
    }

    static func joinRelative(_ root: String, _ relative: String) -> String {
        guard !relative.isEmpty else { return root }
        if root.hasSuffix("/") { return root + relative }
        return root + "/" + relative
    }

    /// 把绝对路径转成"相对作品目录"的路径
    static func relativeToWork(_ absolutePath: String?, workAbsolute: String) -> String? {
        guard let absolutePath else { return nil }
        let prefix = workAbsolute.hasSuffix("/") ? workAbsolute : workAbsolute + "/"
        if absolutePath.hasPrefix(prefix) {
            return String(absolutePath.dropFirst(prefix.count))
        }
        return (absolutePath as NSString).lastPathComponent
    }

}
