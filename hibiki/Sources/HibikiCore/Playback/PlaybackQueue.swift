import Foundation

/// 重复模式
public enum RepeatMode: String, CaseIterable, Codable, Sendable {
    case off
    case all
    case one

    public var displayName: String {
        switch self {
        case .off: return InterfaceLocalization.text("不重复")
        case .all: return InterfaceLocalization.text("列表循环")
        case .one: return InterfaceLocalization.text("单曲循环")
        }
    }

    public var iconName: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// 点击按钮时的循环顺序
    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// 播放队列里的一项
public struct PlaybackQueueItem: Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var workID: Int64
    /// Videos retain their attachment identity; trackID is zero for these items.
    public var attachmentID: Int64?
    public var isVideo: Bool { attachmentID != nil || MediaExtensions.video.contains(fileType.lowercased()) }
    public var mediaID: WorkMediaID? {
        if let attachmentID { return .attachment(attachmentID) }
        return trackID > 0 ? .track(trackID) : nil
    }
    // 列表中独立保存的音频片段使用其条目编号的负值，与媒体库曲目区分。
    public var isSavedClip: Bool { trackID < 0 }
    public var trackID: Int64
    public var workTitle: String
    public var trackTitle: String
    public var subtitle: String?
    /// 解析好的绝对路径（入队时算好，避免播放时再查库）
    public var filePath: String
    /// Network audio is resolved by stable track ID, never by interpreting filePath as a URL.
    public var networkSourceID: UUID?
    public var isNetworkAudio: Bool { networkSourceID != nil && !isVideo && !isSavedClip }
    public var fileType: String
    public var durationMS: Int?
    public var category: TrackCategory

    public init(
        id: UUID = UUID(),
        workID: Int64,
        trackID: Int64,
        workTitle: String,
        trackTitle: String,
        subtitle: String? = nil,
        filePath: String,
        fileType: String,
        durationMS: Int? = nil,
        category: TrackCategory = .main,
        attachmentID: Int64? = nil,
        networkSourceID: UUID? = nil
    ) {
        self.id = id
        self.workID = workID
        self.attachmentID = attachmentID
        self.trackID = trackID
        self.workTitle = workTitle
        self.trackTitle = trackTitle
        self.subtitle = subtitle
        self.filePath = filePath
        self.networkSourceID = networkSourceID
        self.fileType = fileType
        self.durationMS = durationMS
        self.category = category
    }
}

/// 播放队列。
///
/// 纯逻辑：不碰音频引擎，只负责"下一首是谁"。
/// 这样随机、循环、跳转这些容易出错的地方可以完整单元测试。
public struct PlaybackQueue: Equatable, Sendable {

    /// 原始顺序（就是界面上的顺序）
    public private(set) var items: [PlaybackQueueItem]
    /// 实际播放顺序：`items` 下标的排列
    public private(set) var order: [Int]
    /// 当前在 `order` 里的位置
    public private(set) var cursor: Int
    public var repeatMode: RepeatMode
    public private(set) var isShuffled: Bool

    public init(items: [PlaybackQueueItem] = [], repeatMode: RepeatMode = .off) {
        self.items = Self.distinctEntries(items)
        self.order = Array(items.indices)
        self.cursor = 0
        self.repeatMode = repeatMode
        self.isShuffled = false
    }

    public var isEmpty: Bool { items.isEmpty }

    /// 当前曲目
    public var current: PlaybackQueueItem? {
        guard !items.isEmpty, order.indices.contains(cursor) else { return nil }
        let itemIndex = order[cursor]
        guard items.indices.contains(itemIndex) else { return nil }
        return items[itemIndex]
    }

    /// 当前曲目在 `items` 里的下标（界面高亮用）
    public var currentItemIndex: Int? {
        guard !items.isEmpty, order.indices.contains(cursor) else { return nil }
        return order[cursor]
    }

    /// 后面还会播什么（界面"接下来播放"用）
    public var upNext: [PlaybackQueueItem] {
        guard !items.isEmpty, cursor + 1 < order.count else { return [] }
        return order[(cursor + 1)...].compactMap { index in
            items.indices.contains(index) ? items[index] : nil
        }
    }

    public var progressDescription: String {
        guard !items.isEmpty else { return InterfaceLocalization.text("空队列") }
        return "\(cursor + 1)/\(order.count)"
    }

    /// Move positions in the visible, actual playback order. The loaded entry
    /// stays selected even when it is itself moved; callers must not reload it.
    @discardableResult
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) -> Bool {
        guard !offsets.isEmpty, offsets.allSatisfy(order.indices.contains),
              (0...order.count).contains(destination) else { return false }
        let previousOrder = order
        let playingIndex = currentItemIndex
        let moved = offsets.sorted().map { order[$0] }
        let insertion = destination - offsets.filter { $0 < destination }.count
        var remaining = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moved, at: insertion)
        guard remaining != previousOrder else { return false }
        order = remaining
        if let playingIndex, let position = order.firstIndex(of: playingIndex) { cursor = position }
        return true
    }

    /// An occurrence in a queue has an identity of its own, even when callers
    /// supply the same value twice for repeated playback of one recording.
    private static func distinctEntries(_ input: [PlaybackQueueItem]) -> [PlaybackQueueItem] {
        var used = Set<UUID>()
        return input.map { original in
            var item = original
            while !used.insert(item.id).inserted { item.id = UUID() }
            return item
        }
    }

    /// Re-pair files without rebuilding queue identity, order or playback position.
    public mutating func updateFilePaths(_ paths: [Int64: String]) {
        for index in items.indices {
            guard items[index].attachmentID == nil, !items[index].isSavedClip,
                  let path = paths[items[index].trackID], !path.isEmpty else { continue }
            items[index].filePath = path
        }
    }

    public mutating func renamePersonalAudio(workID: Int64, trackID: Int64, title: String) {
        for index in items.indices where items[index].workID == workID && !items[index].isSavedClip {
            items[index].workTitle = title
            if items[index].attachmentID == nil && items[index].trackID == trackID {
                items[index].trackTitle = title
            }
        }
    }

    /// A newly selected audio file can have a different format and duration.
    /// Keep queue entry identity, shuffle order and cursor, including repeated
    /// occurrences of the same track. Independent saved clips are untouched.
    public mutating func updateAudioSources(_ sources: [Int64: PlaybackQueueItem]) {
        for index in items.indices {
            let old = items[index]
            guard !old.isSavedClip, !old.isVideo,
                  let source = sources[old.trackID], source.workID == old.workID,
                  source.trackID == old.trackID, !source.isVideo,
                  !source.filePath.isEmpty || source.isNetworkAudio else { continue }
            items[index].filePath = source.filePath
            items[index].networkSourceID = source.networkSourceID
            items[index].fileType = source.fileType
            items[index].durationMS = source.durationMS
            items[index].trackTitle = source.trackTitle
        }
    }

    /// Attachment IDs use their own namespace; repairing a video never changes
    /// an audio track with the same numeric ID or an independently saved clip.
    public mutating func updateAttachmentFilePaths(_ paths: [Int64: String]) {
        for index in items.indices {
            guard !items[index].isSavedClip, let attachmentID = items[index].attachmentID,
                  let path = paths[attachmentID], !path.isEmpty else { continue }
            items[index].filePath = path
        }
    }

    // MARK: - 构建

    /// 用一组曲目建立队列并定位到指定下标
    public static func make(
        items: [PlaybackQueueItem],
        startingAt itemIndex: Int = 0,
        shuffled: Bool = false,
        seed: UInt64 = 0
    ) -> PlaybackQueue {
        var queue = PlaybackQueue(items: items)
        let target = items.indices.contains(itemIndex) ? itemIndex : 0
        if shuffled {
            queue.setShuffle(true, seed: seed, keepingCurrent: target)
        } else {
            queue.cursor = items.isEmpty ? 0 : target
        }
        return queue
    }

    /// Keep the current recording (and any shuffled order) when other library tracks disappear.
    public mutating func removeTracks(_ ids: Set<Int64>) {
        removeMedia(Set(ids.map { WorkMediaID.track($0) }))
    }

    public mutating func removeMedia(_ ids: Set<WorkMediaID>) {
        func removed(_ index: Int) -> Bool { items[index].mediaID.map(ids.contains) ?? false }
        let remainingOrder = order.filter { !removed($0) }
        let earlier = order.prefix(cursor).filter { !removed($0) }.count
        let keptIndices = items.indices.filter { !removed($0) }
        let newIndices = Dictionary(uniqueKeysWithValues: keptIndices.enumerated().map { ($0.element, $0.offset) })
        items = keptIndices.map { items[$0] }
        order = remainingOrder.compactMap { newIndices[$0] }
        cursor = min(earlier, max(0, order.count - 1))
    }

    // MARK: - 随机

    /// 开关随机播放。
    ///
    /// 关闭时会**保留当前正在播的这首**，并把顺序恢复成原始顺序；
    /// 打开时把当前这首排到最前，其余随后打乱。
    public mutating func setShuffle(_ enabled: Bool, seed: UInt64 = 0, keepingCurrent itemIndex: Int? = nil) {
        guard !items.isEmpty else {
            isShuffled = enabled
            return
        }
        let anchor = itemIndex ?? currentItemIndex ?? 0
        isShuffled = enabled

        if enabled {
            var generator = SplitMix64(seed: seed)
            var rest = items.indices.filter { $0 != anchor }
            rest.shuffle(using: &generator)
            order = [anchor] + rest
            cursor = 0
        } else {
            order = Array(items.indices)
            cursor = items.indices.contains(anchor) ? anchor : 0
        }
    }

    /// 重新打乱（保持当前曲目不变，但换一个随机顺序）
    public mutating func reshuffle(seed: UInt64) {
        guard isShuffled else { return }
        setShuffle(true, seed: seed, keepingCurrent: currentItemIndex)
    }

    // MARK: - 跳转

    /// 跳到 `items` 里的指定下标
    @discardableResult
    public mutating func jump(toItemIndex index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        guard let position = order.firstIndex(of: index) else { return false }
        cursor = position
        return true
    }

    /// 下一首
    /// - Parameter auto: 是否是"播完了自动进入下一首"
    ///   （单曲循环只在自动时原地重播；手动点"下一首"仍然换歌）
    /// - Returns: 是否有可播放的下一首
    @discardableResult
    public mutating func advance(auto: Bool = false) -> Bool {
        guard !items.isEmpty else { return false }

        if repeatMode == .one, auto {
            // 原地重播：位置不变
            return true
        }

        if cursor + 1 < order.count {
            cursor += 1
            return true
        }

        // 已经到末尾
        switch repeatMode {
        case .off:
            return false
        case .all, .one:
            cursor = 0
            return true
        }
    }

    /// 上一首
    ///
    /// 业界惯例：播放超过 3 秒时"上一首"应该是**回到本曲开头**，
    /// 而不是真的跳上一首。这里把判断交给调用方（传 `elapsedMS`）。
    @discardableResult
    public mutating func retreat(elapsedMS: Int = 0, restartThresholdMS: Int = 3_000) -> Bool {
        guard !items.isEmpty else { return false }
        if elapsedMS > restartThresholdMS {
            return true   // 调用方据此把位置归零，不换曲
        }
        if cursor > 0 {
            cursor -= 1
            return true
        }
        switch repeatMode {
        case .off:
            return false
        case .all, .one:
            cursor = order.count - 1
            return true
        }
    }

    /// 从队列里移除某一项（比如文件被删了）
    @discardableResult
    public mutating func remove(trackID: Int64) -> Bool {
        guard let itemIndex = items.firstIndex(where: { $0.trackID == trackID }) else { return false }
        let playingIndex = currentItemIndex
        items.remove(at: itemIndex)

        // 重建顺序：尽量保持当前曲目不变
        let newAnchor: Int?
        if let playingIndex {
            if playingIndex == itemIndex {
                newAnchor = nil
            } else if playingIndex > itemIndex {
                newAnchor = playingIndex - 1
            } else {
                newAnchor = playingIndex
            }
        } else {
            newAnchor = nil
        }

        if items.isEmpty {
            order = []
            cursor = 0
            return true
        }

        // Both a shuffled order and a manually arranged order must survive
        // removing another recording.
        order = order.compactMap { index -> Int? in
            if index == itemIndex { return nil }
            return index > itemIndex ? index - 1 : index
        }
        if let newAnchor, let position = order.firstIndex(of: newAnchor) {
            cursor = position
        } else {
            cursor = min(cursor, max(0, order.count - 1))
        }
        return true
    }

    /// 整体替换（重新导入媒体库后刷新队列）
    public mutating func replaceItems(_ newItems: [PlaybackQueueItem]) {
        let playingTrackID = current?.trackID
        items = Self.distinctEntries(newItems)
        order = Array(newItems.indices)
        isShuffled = false
        cursor = 0
        if let playingTrackID, let index = newItems.firstIndex(where: { $0.trackID == playingTrackID }) {
            cursor = index
        }
    }
}

/// 可复现的伪随机数发生器（用于"随机播放"的测试）
///
/// 用系统随机源的话同一份队列每次顺序不同，测试就没法断言了。
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
