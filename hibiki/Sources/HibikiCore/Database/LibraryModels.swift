import Foundation

public enum MediaLibraryKind: String, CaseIterable, Codable, Sendable {
    case collection, personal

    public var displayName: String {
        self == .collection ? InterfaceLocalization.text("社团作品") : InterfaceLocalization.text("个人音声")
    }
}

public enum CreatorCoverMode: String, CaseIterable, Codable, Sendable {
    case none, avatar, image
}

/// Shared creator images belong to this profile, never to an individual work.
public struct CreatorRecord: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var avatarAssetPath: String?
    public var coverMode: CreatorCoverMode
    public var coverAssetPath: String?
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64 = 0, name: String, avatarAssetPath: String? = nil,
                coverMode: CreatorCoverMode = .none, coverAssetPath: String? = nil,
                note: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.avatarAssetPath = avatarAssetPath
        self.coverMode = coverMode
        self.coverAssetPath = coverAssetPath
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var effectiveCoverAssetPath: String? {
        switch coverMode {
        case .none: return nil
        case .avatar: return avatarAssetPath
        case .image: return coverAssetPath
        }
    }
}

/// 编辑表单的封面意图。选择图片与恢复原图都在保存整份资料时才生效。
public enum WorkCoverUpdate: Equatable, Sendable {
    case unchanged
    case replace(assetRelativePath: String)
    case restoreOriginal
}

public enum PlayerCoverMode: String, CaseIterable, Hashable, Sendable {
    case original, fit4x3, fill4x3
}

/// 存储源类型
public enum SourceType: String, Codable, Sendable, CaseIterable {
    case local
    case webdav
    case openlist
    case baidu

    public var displayName: String {
        switch self {
        case .local: return InterfaceLocalization.text("本地文件夹")
        case .webdav: return "WebDAV"
        case .openlist: return "OpenList"
        case .baidu: return InterfaceLocalization.text("百度网盘")
        }
    }

    public var iconName: String {
        switch self {
        case .local: return "folder"
        case .webdav: return "externaldrive.connected.to.line.below"
        case .openlist: return "cloud"
        case .baidu: return "cloud.fill"
        }
    }
}

/// 一个存储源（对应数据库 `source` 表）
public struct LibrarySource: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var type: SourceType
    /// 根路径（本地是文件系统路径；远端是 URL）
    public var rootPath: String?
    /// iOS 的 security-scoped book mark，用于重启后继续访问用户授权的目录
    public var bookmark: Data?
    public var enabled: Bool
    public var createdAt: Date
    /// 导入时用的分组模式（记住用户的选择）
    public var grouping: ScanOptions.Grouping

    public init(
        id: Int64 = 0,
        name: String,
        type: SourceType = .local,
        rootPath: String? = nil,
        bookmark: Data? = nil,
        enabled: Bool = true,
        createdAt: Date = Date(),
        grouping: ScanOptions.Grouping = .automatic
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.rootPath = rootPath
        self.bookmark = bookmark
        self.enabled = enabled
        self.createdAt = createdAt
        self.grouping = grouping
    }
}

/// 作品（对应数据库 `work` 表）
public struct WorkRecord: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64
    public var libraryKind: MediaLibraryKind
    public var creatorID: Int64?
    public var rjCode: String?
    public var title: String
    public var circleName: String?
    public var seiyuuName: String?
    /// 多位声优分别保存；旧记录保持为一个名字，不猜测名字里的分隔符。
    public var seiyuuNames: [String] = []
    public var coverPath: String?
    public var coverAssetPath: String?
    public var playerCoverMode: PlayerCoverMode = .original
    public var folderPath: String
    /// 相对存储源根目录的路径（推荐用这个，绝对路径在 iOS 上会变）
    public var folderRelativePath: String
    public var sourceID: Int64
    public var rating: Int
    public var favorite: Bool
    public var listened: Bool
    public var playCount: Int
    public var lastPlayedTrackID: Int64?
    public var lastPlayedPositionMS: Int
    public var scriptPath: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// 曲目数量（查询时联表得到的，不落库）
    public var trackCount: Int = 0
    public var videoCount: Int = 0

    public var mediaCountText: String {
        if videoCount == 0 { return InterfaceLocalization.text("\(trackCount) 曲") }
        if trackCount == 0 { return InterfaceLocalization.text("\(videoCount) 个视频") }
        return InterfaceLocalization.text("\(trackCount) 曲 · \(videoCount) 个视频")
    }
    /// 总时长毫秒（查询时聚合得到，不落库）
    public var totalDurationMS: Int = 0
    /// 解析后的封面绝对路径（运行时算出来，不落库）
    public var resolvedCoverPath: String?
    /// 解析后的台本绝对路径（运行时算出来，不落库）
    public var resolvedScriptPath: String?
    /// 用户自定义的分组（不含内置分组）
    public var customCategories: [WorkCategory] = []

    public init(
        id: Int64 = 0,
        title: String,
        rjCode: String? = nil,
        circleName: String? = nil,
        seiyuuName: String? = nil,
        coverPath: String? = nil,
        folderPath: String,
        folderRelativePath: String = "",
        sourceID: Int64,
        rating: Int = 0,
        favorite: Bool = false,
        listened: Bool = false,
        playCount: Int = 0,
        lastPlayedTrackID: Int64? = nil,
        lastPlayedPositionMS: Int = 0,
        scriptPath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        libraryKind: MediaLibraryKind = .collection,
        creatorID: Int64? = nil
    ) {
        self.id = id
        self.libraryKind = libraryKind
        self.creatorID = creatorID
        self.rjCode = rjCode
        self.title = title
        self.circleName = circleName
        self.seiyuuName = seiyuuName
        self.seiyuuNames = seiyuuName.map(FolderClassifier.performerNames) ?? []
        self.coverPath = coverPath
        self.folderPath = folderPath
        self.folderRelativePath = folderRelativePath
        self.sourceID = sourceID
        self.rating = rating
        self.favorite = favorite
        self.listened = listened
        self.playCount = playCount
        self.lastPlayedTrackID = lastPlayedTrackID
        self.lastPlayedPositionMS = lastPlayedPositionMS
        self.scriptPath = scriptPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 是否有未听完的进度
    public var hasResumePoint: Bool {
        lastPlayedTrackID != nil && lastPlayedPositionMS > 0
    }

    /// 显示用副标题：声优 · 社团
    public var subtitle: String {
        [seiyuuName, circleName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// 曲目（对应数据库 `track` 表）
public struct TrackRecord: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64
    public var workID: Int64
    public var fileName: String
    public var filePath: String
    /// 相对作品目录的路径，用于远端源与迁移
    public var relativePath: String?
    public var fileType: String
    public var isVideo: Bool
    public var trackIndex: Int
    public var title: String?
    public var durationMS: Int?
    public var fileSize: Int64?
    public var fileMtime: Date?
    public var createdAt: Date
    /// 自动识别出来的内容类型
    public var category: TrackCategory
    /// 用户手动指定的分组 key（优先于自动识别）
    public var categoryOverride: String?
    /// 手动排序序号（小的在前）
    public var sortOrder: Int
    /// 解析后的绝对路径（运行时算出来，不落库）
    public var resolvedFilePath: String?
    /// 用户单独添加的副本，相对 Application Support/WorkAssets。
    public var assetRelativePath: String?

    public init(
        id: Int64 = 0,
        workID: Int64,
        fileName: String,
        filePath: String,
        relativePath: String? = nil,
        fileType: String,
        isVideo: Bool = false,
        trackIndex: Int = 0,
        title: String? = nil,
        durationMS: Int? = nil,
        fileSize: Int64? = nil,
        fileMtime: Date? = nil,
        createdAt: Date = Date(),
        category: TrackCategory = .main,
        categoryOverride: String? = nil,
        sortOrder: Int = 0,
        assetRelativePath: String? = nil
    ) {
        self.id = id
        self.workID = workID
        self.fileName = fileName
        self.filePath = filePath
        self.relativePath = relativePath
        self.fileType = fileType
        self.isVideo = isVideo
        self.trackIndex = trackIndex
        self.title = title
        self.durationMS = durationMS
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.createdAt = createdAt
        self.category = category
        self.categoryOverride = categoryOverride
        self.sortOrder = sortOrder
        self.assetRelativePath = assetRelativePath
    }

    /// 实际生效的分组 key：手动优先，否则用自动识别的
    public var effectiveCategoryKey: String {
        if let override = categoryOverride, !override.isEmpty { return override }
        return category.rawValue
    }

    /// 列表显示用标题：优先用 title，否则用文件名（去扩展名）
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return (fileName as NSString).deletingPathExtension
    }
}

/// 作品列表的排序方式
public enum WorkSortOrder: String, Sendable, CaseIterable {
    case recentlyPlayed
    case addedRecently
    case title
    case custom
    /// Kept for older Core clients; no longer offered in the app's sort picker.
    @available(*, deprecated, message: "The app now offers custom work ordering instead.")
    case rjCode

    public static var allCases: [WorkSortOrder] { [.recentlyPlayed, .addedRecently, .title, .custom] }

    public var displayName: String {
        switch self {
        case .recentlyPlayed: return InterfaceLocalization.text("最近播放")
        case .addedRecently: return InterfaceLocalization.text("加入时间")
        case .title: return InterfaceLocalization.text("名称")
        case .custom: return InterfaceLocalization.text("自定义")
        case .rjCode: return InterfaceLocalization.text("作品编号")
        }
    }
}

/// 作品列表筛选
public enum WorkFilter: Sendable, Equatable {
    case all
    case favorite
    case listening      // 有续播进度但没听完
    case unlistened
    case listened

    public var displayName: String {
        switch self {
        case .all: return InterfaceLocalization.text("全部")
        case .favorite: return InterfaceLocalization.text("收藏")
        case .listening: return InterfaceLocalization.text("听了一半")
        case .unlistened: return InterfaceLocalization.text("未听")
        case .listened: return InterfaceLocalization.text("已听完")
        }
    }
}
