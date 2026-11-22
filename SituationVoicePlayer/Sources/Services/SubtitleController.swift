import Foundation
import Combine

/// 字幕显示样式（存在 UserDefaults 里）
struct SubtitleStyle: Equatable {
    var fontSize: Double = 17          // 单行字幕字号
    var showOriginal: Bool = true
    var showTranslation: Bool = true
    var autoHideSeconds: Double = 6    // 无字幕时多久后淡出
    var backgroundOpacity: Double = 0.35
    var bottomInset: Double = 6

    static let storageKey = "hibiki.subtitle.style"

    static func load(defaults: UserDefaults = .standard) -> SubtitleStyle {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SubtitleStyle.self, from: data) else {
            return SubtitleStyle()
        }
        return decoded
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension SubtitleStyle: Codable {}

enum SubtitleStyleMode: Equatable {
    case fullScreen
    case call
}

/// 两个模式一起保存，避免只改一套后，另一套下次启动又从旧共享值继承。
struct SubtitleModeStyles: Codable, Equatable {
    static let storageKey = "hibiki.subtitle.modeStyles.v1"
    var fullScreen: SubtitleStyle
    var call: SubtitleStyle

    static func load(defaults: UserDefaults) -> SubtitleModeStyles {
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Self.self, from: data) {
            return saved
        }
        let legacy = SubtitleStyle.load(defaults: defaults)
        // 迁移只在内存中进行；首次实际修改时才固化两份快照，不改旧偏好。
        return Self(fullScreen: legacy, call: legacy)
    }

    func save(defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// 当前播放曲目的字幕状态。
///
/// 只负责"现在该显示哪句"，不关心界面怎么画。
@MainActor
final class SubtitleController: ObservableObject {

    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var currentCue: SubtitleCue?
    @Published private(set) var upcomingCue: SubtitleCue?
    @Published private(set) var trackLabel: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var loadedSubtitleTrackID: Int64?
    /// 只用于重建当前阅读视图，持久位置使用数据库里的来源 ID。
    @Published private(set) var readingRevision = UUID()

    var hasTimedCues: Bool { cues.contains(where: \.hasTiming) }
    var isUntimed: Bool { !cues.isEmpty && !hasTimedCues }
    var readingCueID: UUID? { currentCue?.id ?? locator?.readingCue(at: positionMS)?.id }

    /// 播放位置（毫秒），用来判断滚动列表的高亮
    @Published private(set) var positionMS: Int = 0

    /// 普通播放器与全屏字幕共用；不随作品、曲目或通话切换而改变。
    @Published var style: SubtitleStyle {
        didSet { if style != oldValue { saveModeStyles() } }
    }

    @Published var callStyle: SubtitleStyle {
        didSet { if callStyle != oldValue { saveModeStyles() } }
    }

    /// 是否正在显示（自动淡出用）
    @Published private(set) var lastCueVisibleAt: Date = .distantPast

    private var locator: SubtitleLocator?
    private var repository: SubtitleRepository?
    private(set) var loadedTrackID: Int64?
    private var loadedWork: WorkRecord?
    private var cancelBag = Set<AnyCancellable>()
    private let defaults: UserDefaults

    init(style: SubtitleStyle? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = style.map { SubtitleModeStyles(fullScreen: $0, call: $0) }
            ?? SubtitleModeStyles.load(defaults: defaults)
        self.style = saved.fullScreen
        self.callStyle = saved.call
    }

    func style(for mode: SubtitleStyleMode) -> SubtitleStyle {
        switch mode {
        case .fullScreen: style
        case .call: callStyle
        }
    }

    func setStyle(_ style: SubtitleStyle, for mode: SubtitleStyleMode) {
        switch mode {
        case .fullScreen: self.style = style
        case .call: callStyle = style
        }
    }

    private func saveModeStyles() {
        SubtitleModeStyles(fullScreen: style, call: callStyle).save(defaults: defaults)
    }

    func attach(repository: SubtitleRepository) {
        self.repository = repository
    }

    /// Audio clips use a negative playback track ID but do not own a library
    /// track row. Resolve their independent snapshot before looking up a work.
    func load(item: PlaybackQueueItem, store: LibraryStore) {
        guard !item.isVideo else { clear(); return }
        guard loadedTrackID != item.trackID else { return }
        if item.isSavedClip {
            guard item.trackID != Int64.min else { clear(); return }
            do {
                loadSavedClip(entryID: -item.trackID, cues: try store.savedClipSubtitles(entryID: -item.trackID))
            } catch {
                clear()
                loadedTrackID = item.trackID
                loadError = InterfaceLocalization.text("读取摘选字幕失败：\(error.localizedDescription)")
            }
        } else if let work = try? store.work(id: item.workID) {
            load(trackID: item.trackID, work: work, audioPath: item.filePath)
        } else {
            clear()
        }
    }

    func loadSavedClip(entryID: Int64, cues: [SubtitleCue]) {
        guard entryID > 0, loadedTrackID != -entryID else { return }
        loadedTrackID = -entryID
        loadedWork = nil
        loadedSubtitleTrackID = nil
        isLoading = false
        loadError = nil
        positionMS = 0
        trackLabel = InterfaceLocalization.text("摘选字幕")
        apply(cues: cues)
    }

    /// 切到某个曲目：读它当前生效的字幕；没有就尝试从同目录找外挂字幕并导入
    func load(trackID: Int64, work: WorkRecord, audioPath: String?) {
        guard loadedTrackID != trackID else { return }
        loadedTrackID = trackID
        loadedWork = work
        loadedSubtitleTrackID = nil
        loadError = nil
        isLoading = true
        positionMS = 0
        cues = []
        locator = nil
        currentCue = nil
        upcomingCue = nil
        trackLabel = ""

        defer { isLoading = false }

        guard let repository else { return }

        // 有来源而没有启用项，表示用户关闭了字幕。播放时也保留这项选择。
        guard let tracks = try? repository.tracks(forTrackID: trackID) else { return }
        if !tracks.isEmpty {
            if let active = tracks.first(where: \.isActive),
               let saved = try? repository.activeCues(trackID: trackID) {
                loadedSubtitleTrackID = active.id
                apply(cues: saved)
                trackLabel = active.displayLabel
            }
            return
        }

        // 旧库中从未导入字幕的曲目，仍可在首次播放时发现同目录外挂。
        guard let audioPath else { return }
        let imported = importSidecars(trackID: trackID, audioPath: audioPath, repository: repository)
        if !imported.isEmpty {
            apply(cues: imported)
        }
    }

    /// 强制重新读取（编辑保存后用）
    func forceReload() {
        guard let id = loadedTrackID, let work = loadedWork else { return }
        let playhead = positionMS
        loadedTrackID = nil
        load(trackID: id, work: work, audioPath: nil)
        update(positionMS: playhead)
    }

    /// 编辑器已成功提交的同一来源快照可直接用于播放，避免重读后更换每行 UUID。
    @discardableResult
    func applySavedEditorCues(_ saved: [SubtitleCue], trackID: Int64, subtitleTrackID: Int64) -> Bool {
        guard loadedTrackID == trackID, loadedSubtitleTrackID == subtitleTrackID else { return false }
        let playhead = positionMS
        apply(cues: saved)
        update(positionMS: playhead)
        return true
    }

    /// 清除当前曲目的全部字幕（数据库 + 内存）
    func clearAll(repository: SubtitleRepository) {
        guard let id = loadedTrackID else { return }
        _ = try? repository.clearSubtitles(trackID: id)
        cues = []
        locator = nil
        currentCue = nil
        upcomingCue = nil
        trackLabel = ""
        loadedTrackID = nil
        loadedSubtitleTrackID = nil
    }

    func clear() {
        loadedTrackID = nil
        loadedSubtitleTrackID = nil
        loadedWork = nil
        cues = []
        locator = nil
        currentCue = nil
        upcomingCue = nil
        trackLabel = ""
        loadError = nil
    }

    /// 播放进度更新
    func update(positionMS: Int) {
        self.positionMS = positionMS
        guard let locator else { return }
        let cue = locator.cue(at: positionMS)
        if cue?.id != currentCue?.id {
            currentCue = cue
            if cue != nil { lastCueVisibleAt = Date() }
        }
        upcomingCue = locator.next(after: positionMS)
    }

    /// 当前是否应该显示字幕
    func shouldDisplay(now: Date = Date()) -> Bool {
        guard currentCue != nil else { return false }
        // 只有超过自动隐藏秒数才隐藏；字幕本身有起止时间，通常不会一直显示
        return now.timeIntervalSince(lastCueVisibleAt) < max(0.5, style.autoHideSeconds) || currentCue != nil
    }

    // MARK: - 内部

    private func apply(cues: [SubtitleCue]) {
        readingRevision = UUID()
        self.cues = cues
        self.locator = cues.contains(where: \.hasTiming) ? SubtitleLocator(cues: cues) : nil
        self.currentCue = nil
        self.upcomingCue = locator?.next(after: 0)
        if cues.isEmpty {
            loadError = "没有字幕"
        }
    }

    /// 从音频同目录找出字幕文件并入库
    private func importSidecars(trackID: Int64, audioPath: String, repository: SubtitleRepository) -> [SubtitleCue] {
        let directory = (audioPath as NSString).deletingLastPathComponent
        let audioName = (audioPath as NSString).lastPathComponent

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let candidates = names.map { (directory as NSString).appendingPathComponent($0) }
        let matches = SubtitleSidecarFinder.find(audioFileName: audioName, candidatePaths: candidates)
        guard !matches.isEmpty else { return [] }

        let pairs = SubtitleSidecarFinder.pair(matches, preferPrimary: "ja")
        guard let pair = pairs.first else { return [] }

        guard let primaryCues = parse(path: pair.primary.path) else { return [] }
        var merged = primaryCues
        if let secondary = pair.secondary, let translationCues = parse(path: secondary.path) {
            merged = SubtitleTranslationMerger.merge(primary: primaryCues, secondary: translationCues)
        }

        let label = (pair.primary.path as NSString).lastPathComponent
        let created = try? repository.createTrack(
            trackID: trackID,
            kind: .sidecar,
            language: pair.primary.languageHint,
            label: label,
            cues: merged,
            note: "自动导入",
            activate: true
        )
        loadedSubtitleTrackID = created?.track
        trackLabel = label
        return merged
    }

    private func parse(path: String) -> [SubtitleCue]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let text = SubtitleTextDecoder.decode(data: data) else { return nil }
        let ext = (path as NSString).pathExtension
        let format = SubtitleFormat.from(fileExtension: ext)
        let result = SubtitleParser.parse(text, formatHint: format)
        return result.cues.isEmpty ? nil : result.cues
    }
}
