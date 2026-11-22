import Foundation
import AVFoundation
import MediaPlayer
import Combine

enum SimulatedCallPhase: String { case inactive, connecting, connected }

/// 播放控制器：队列 + 时钟 + 音频引擎 + 系统集成的总协调。
///
/// 界面只跟这个对象打交道。
@MainActor
final class PlayerController: ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var callPhase: SimulatedCallPhase = .inactive
    @Published private(set) var callWorkID: Int64?
    @Published private(set) var audioOutputName = InterfaceLocalization.text("音频输出")
    @Published var callUsesVideo = false
    @Published var callShowsLocalImage = false
    private var callConnection: Task<Void, Never>?
    private var callGeneration = UUID()
    var isInCall: Bool { callPhase != .inactive }
    var isPresentingVideoPreview: Bool { videoPreviewToken != nil }

    func beginCall() {
        guard !isInCall, videoPreviewToken == nil, let item = currentItem,
              !item.isSavedClip, item.workID > 0,
              (try? libraryStore?.repository?.work(id: item.workID)) != nil else { return }
        OpeningVoicePlayer.shared.stop()
        pause(immediately: true)
        remoteCommandGate.transition(allowsAudio: true)
        callGeneration = UUID()
        let expected = callGeneration
        callWorkID = item.workID
        callUsesVideo = false
        callShowsLocalImage = false
        callPhase = .connecting
        isPlayerSheetPresented = true
        callConnection = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.callGeneration == expected,
                  self.callPhase == .connecting, self.currentItem?.id == item.id else { return }
            self.callConnection = nil
            self.callPhase = .connected
            self.resume()
        }
    }

    func endCall() {
        remoteCommandGate.transition(allowsAudio: true)
        callGeneration = UUID()
        callConnection?.cancel(); callConnection = nil
        callPhase = .inactive
        callWorkID = nil
        callShowsLocalImage = false
        pause(immediately: true)
    }

    func cancelCallConnectionIfNeeded() {
        if callPhase == .connecting { endCall() }
    }

    @Published private(set) var waveform: WaveformData = .empty
    private var waveformTask: Task<Void, Never>?

    // 收起播放器仍保留起点；换曲时清除，避免用错原音频。
    @Published private(set) var clipStartMS: Int?
    func markClipStart() {
        guard let currentItem, !currentItem.isSavedClip, !currentItem.isVideo else { return }
        clipStartMS = capturePositionMS
    }
    func clearClipStart() { clipStartMS = nil }
    var capturePositionMS: Int {
        // iOS 可能先停渲染，才通知 App 被打断。这时节点只能报出上次 seek 的起点。
        min(durationMS, max(0, isPlaying ? (isVideo ? (videoSeeking ? positionMS : movie.positionMS) : max(positionMS, engine.currentPositionMS)) : positionMS))
    }

    @Published private(set) var isLoadingMedia = false
    @Published var videoScale: CGFloat = 1
    var isVideo: Bool { currentItem?.isVideo == true }
    var videoPlayer: AVPlayer { movie.player }
    private var pendingVideoAutoplay = false
    private var needsMediaReload = false
    private var videoSeeking: Bool { movie.isSeeking }
    private var videoLease: WorkAttachmentDirectoryLease?
    private let movie = VideoPlaybackEngine()
    private var attachmentRemovalSubscription: AnyCancellable?

    @Published private(set) var currentItem: PlaybackQueueItem?
    @Published private(set) var currentWorkTitle = ""
    @Published private(set) var currentCoverPath: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var positionMS: Int = 0
    @Published private(set) var durationMS: Int = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var queuePositionText: String = ""
    @Published private(set) var hasQueue = false
    @Published private(set) var sleepTimer: PlaybackSleepTimer = .off
    @Published private(set) var sleepTimerNotice: String?
    private var sleepTask: Task<Void, Never>?
    /// 是否展示全屏播放页（迷你条和调试入口都用它）
    @Published var isPlayerSheetPresented = false

    @Published var repeatMode: RepeatMode = .off {
        didSet { queue.repeatMode = repeatMode }
    }
    /// 播放速度（1.0 = 原速）
    @Published var rate: Double = 1.0 {
        didSet {
            engine.rate = Float(AudioMath.clampRate(rate))
            movie.rate = Float(AudioMath.clampRate(rate))
            updateNowPlaying()
        }
    }
    // MARK: - 依赖

    private let engine = AudioPlaybackEngine()
    @Published private(set) var queue = PlaybackQueue()
    private(set) var queueCollection: SavedPlaylistGroup?
    private var clock = PlaybackClock()
    private var ticker: Timer?
    private weak var libraryStore: LibraryStore?
    private var relinkSubscription: AnyCancellable?
    private var audioReplacementSubscription: AnyCancellable?
    private var audioRenameSubscription: AnyCancellable?
    private var attachmentRelinkSubscription: AnyCancellable?
    private let lockScreenCover = LockScreenCover()
    private var coverWorkID: Int64?
    private var revisionSubscription: AnyCancellable?
    private var removalSubscription: AnyCancellable?

    /// 淡入淡出时长
    private let fadeDuration: Double = 0.18
    /// 续播保存节流
    private var lastSavedAt: Date = .distantPast
    private var listening = ListeningTimeRecorder()
    private var nextListeningSave: TimeInterval = 0
    private var lastAudibleUptime: TimeInterval = 0
    private var interruptedItemID: UUID?
    private var ownsAudioSession = false
    private var pictureInPictureAudioSessionActive = false
    let requestsStopPictureInPicture = PassthroughSubject<Void, Never>()
    private var audioSessionGeneration: UInt64 = 0
    private(set) var videoPreviewToken: UUID?
    private var videoPreviewStop: (() -> Void)?
    private var ownsVideoAudioSession = false
    private let remoteCommandGate = AudioRemoteCommandGate()

    /// An attachment preview temporarily owns playback. Keep the audio queue and
    /// its saved position, but never let a queued remote/interruption resume it.
    func beginVideoPreview(onReplaced: @escaping () -> Void = {}) -> UUID {
        OpeningVoicePlayer.shared.stop()
        videoPreviewStop?()
        if let previous = videoPreviewToken { endVideoPreview(previous) }
        if isInCall { endCall() }
        requestsStopPictureInPicture.send()
        remoteCommandGate.transition(allowsAudio: false)
        pause(immediately: true)
        ownsAudioSession = false
        audioSessionGeneration &+= 1
        interruptedItemID = nil
        let token = UUID()
        videoPreviewToken = token
        videoPreviewStop = onReplaced
        updateNowPlaying()
        return token
    }

    func activateVideoPreview(_ token: UUID) throws {
        guard videoPreviewToken == token else { throw CancellationError() }
        guard !ownsVideoAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        try session.setActive(true)
        ownsVideoAudioSession = true
    }

    /// The preview must pause its AVPlayer before releasing the shared session.
    func suspendVideoPreview(_ token: UUID) {
        guard videoPreviewToken == token, ownsVideoAudioSession else { return }
        ownsVideoAudioSession = false
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { DebugLog.write("视频交还音频会话失败：\(error.localizedDescription)") }
    }

    func endVideoPreview(_ token: UUID) {
        guard videoPreviewToken == token else { return }
        suspendVideoPreview(token)
        videoPreviewToken = nil
        videoPreviewStop = nil
        remoteCommandGate.transition(allowsAudio: true)
        interruptedItemID = nil
        audioSessionGeneration &+= 1
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: []) }
        catch { DebugLog.write("恢复音频会话配置失败：\(error.localizedDescription)") }
        // The previous audio remains paused. Only a later explicit Play resumes it.
        updateNowPlaying()
    }

    init() {
        engine.onTrackFinished = { [weak self] in
            self?.handleTrackFinished()
        }
        movie.onReady = { [weak self] duration in self?.videoBecameReady(durationMS: duration) }
        movie.onStateChanged = { [weak self] in self?.videoPlaybackChanged() }
        movie.onFinished = { [weak self] in self?.handleTrackFinished() }
        movie.onFailure = { [weak self] message in
            guard let self, self.isVideo else { return }
            self.cancelSleepTimerForUnplayableTarget()
            if self.isInCall { self.endCall() }
            else { self.pause(immediately: true) }
            self.isLoadingMedia = false
            self.errorMessage = message
        }
        configureAudioSession()
        configureRemoteCommands()
    }

    func attach(store: LibraryStore) {
        libraryStore = store
        relinkSubscription = store.relinkedTrackPaths.sink { [weak self] paths in
            guard let self else { return }
            self.queue.updateFilePaths(paths)
            // Keep the already-open audio, exact clock and clip selection intact.
            // The next load uses the repaired location without applying resume policy now.
            if var item = self.currentItem, item.attachmentID == nil, !item.isSavedClip,
               let path = paths[item.trackID], !path.isEmpty {
                item.filePath = path
                self.currentItem = item
            }
        }
        audioReplacementSubscription = store.replacedAudioSources.sink { [weak self] sources in
            self?.replaceAudioSources(sources)
        }
        audioRenameSubscription = store.renamedPersonalAudio.sink { [weak self] change in
            guard let self else { return }
            self.objectWillChange.send()
            self.queue.renamePersonalAudio(workID: change.workID, trackID: change.trackID, title: change.title)
            guard var item = self.currentItem, !item.isSavedClip, item.workID == change.workID else { return }
            item.workTitle = change.title
            if item.attachmentID == nil, item.trackID == change.trackID { item.trackTitle = change.title }
            self.currentItem = item
            self.currentWorkTitle = change.title
            self.updateNowPlaying()
        }
        attachmentRelinkSubscription = store.relinkedAttachmentPaths.sink { [weak self] paths in
            guard let self else { return }
            self.queue.updateAttachmentFilePaths(paths)
            // The existing AVPlayer item keeps its current file lease and exact
            // clock. Only the recording location used for later loads changes.
            if var item = self.currentItem, !item.isSavedClip, let attachmentID = item.attachmentID,
               let path = paths[attachmentID], !path.isEmpty {
                item.filePath = path
                self.currentItem = item
            }
        }
        removalSubscription = store.removedTrackIDs.sink { [weak self] ids in
            self?.pruneQueue(Set(ids.map { WorkMediaID.track($0) }))
        }
        attachmentRemovalSubscription = store.removedAttachmentIDs.sink { [weak self] ids in
            self?.pruneQueue(Set(ids.map { WorkMediaID.attachment($0) }))
        }
        revisionSubscription = store.$contentRevision.sink { [weak self, weak store] _ in
            guard let self, let store, let item = self.currentItem else { return }
            let title = store.displayWorkTitle(for: item)
            let cover = store.coverPath(forWorkID: item.workID)
            let subtitle = store.displayWorkSubtitle(for: item)
            guard title != self.currentWorkTitle || self.currentCoverPath != cover || subtitle != item.subtitle else { return }
            var updatedItem = item
            updatedItem.subtitle = subtitle
            self.currentItem = updatedItem
            self.coverWorkID = item.workID
            self.currentCoverPath = cover
            self.currentWorkTitle = title
            self.updateNowPlaying()
        }
    }

    // MARK: - 队列

    /// 开始播放一组曲目
    func play(items: [PlaybackQueueItem], startingAt index: Int = 0, collection: SavedPlaylistGroup? = nil) {
        guard videoPreviewToken == nil, !items.isEmpty else { return }
        OpeningVoicePlayer.shared.stop()
        if isInCall { endCall() }
        switch sleepTimer {
        case .endOfTrack, .endOfQueueItem: cancelSleepTimer()
        case .off, .deadline: break
        }
        queueCollection = collection
        queue = PlaybackQueue.make(items: items, startingAt: index)
        queue.repeatMode = repeatMode
        hasQueue = true
        loadAndPlayCurrent()
    }

    private func pruneQueue(_ ids: Set<WorkMediaID>) {
        guard queue.items.contains(where: { $0.mediaID.map(ids.contains) ?? false }) else { return }
        let removedCurrent = currentItem?.mediaID.map(ids.contains) ?? false
        if removedCurrent && isInCall { endCall() }
        let shouldContinue = isPlaying
        queue.removeMedia(ids)
        reconcileSleepTimer(notice: InterfaceLocalization.text("停止音轨已不在剩余队列中，定时已取消。"))
        queuePositionText = queue.progressDescription
        guard removedCurrent else { return }
        checkpointListening(ending: true)
        interruptedItemID = nil
        stopTicker()
        engine.stop()
        movie.stop(); videoLease = nil; isLoadingMedia = false
        waveformTask?.cancel()
        waveform = .empty
        currentItem = nil
        currentWorkTitle = ""
        clearClipStart()
        isPlaying = false
        positionMS = 0
        durationMS = 0
        hasQueue = !queue.isEmpty
        if hasQueue { loadAndPlayCurrent(autoplay: shouldContinue) }
        else {
            cancelSleepTimer()
            releaseAudioSession()
            queueCollection = nil
            isPlayerSheetPresented = false
            updateNowPlaying()
        }
    }

    /// Replacing an audio source is different from repairing the location of
    /// the same file: release the old decoder and load the new file, paused.
    /// Other queue entries keep their IDs/order, and saved CAF clips stay independent.
    private func replaceAudioSources(_ sources: [Int64: PlaybackQueueItem]) {
        let previous = currentItem
        let replacesCurrent = previous.map { item in
            guard !item.isSavedClip, !item.isVideo,
                  let source = sources[item.trackID] else { return false }
            return source.trackID == item.trackID && source.workID == item.workID
                && !source.isVideo && !source.filePath.isEmpty
        } ?? false
        let savedPosition = replacesCurrent ? capturePositionMS : 0
        if replacesCurrent {
            if isInCall { endCall() }
            else { pause(immediately: true) }
        }
        queue.updateAudioSources(sources)
        guard replacesCurrent else { return }
        loadAndPlayCurrent(autoplay: false, advanceOnFailure: false)
        if currentItem?.id == previous?.id {
            seek(to: savedPosition)
        }
    }

    /// 单曲播放（把当前队列替换成只有这一首）
    func playSingle(_ item: PlaybackQueueItem) {
        play(items: [item], startingAt: 0)
    }

    func togglePlayPause() {
        if callPhase == .connecting { endCall(); return }
        if isPlaying || pendingVideoAutoplay {
            pause()
        } else {
            resume()
        }
    }

    func pause(immediately: Bool = false) {
        guard videoPreviewToken == nil else { return }
        if callPhase == .connecting { endCall(); return }
        // 即使系统已把播放暂停，来自界面、耳机或锁屏的暂停仍然撤销自动恢复。
        interruptedItemID = nil
        pausePlayback(fadeOut: immediately ? 0 : fadeDuration)
    }

    private func pausePlayback(fadeOut: Double) {
        pendingVideoAutoplay = false
        let wasPlaying = isPlaying
        checkpointListening(ending: true)
        if wasPlaying { positionMS = capturePositionMS }
        isPlaying = false
        stopTicker()
        if isVideo {
            movie.pause()
            releaseAudioSession()
            clock.pause()
            persistPosition()
            updateNowPlaying()
            return
        }
        guard wasPlaying || engine.isEngineRunning || ownsAudioSession else { return }
        let generation = audioSessionGeneration
        engine.pause(fadeOut: fadeOut) { [weak self] in
            guard let self, self.audioSessionGeneration == generation, self.videoPreviewToken == nil else { return }
            self.releaseAudioSession()
        }
        clock.pause()
        persistPosition()
        updateNowPlaying()
    }

    func resume() {
        guard videoPreviewToken == nil, callPhase != .connecting else { return }
        OpeningVoicePlayer.shared.stop()
        interruptedItemID = nil
        // A deliberate Play after the app was suspended is a fresh user action.
        _ = expireSleepTimerIfNeeded()
        guard currentItem != nil, !isPlaying else { return }
        if needsMediaReload { loadAndPlayCurrent(); return }
        if isLoadingMedia { pendingVideoAutoplay = true; return }
        if isVideo, movie.player.currentItem == nil || movie.player.currentItem?.status == .failed {
            loadAndPlayCurrent(); return
        }
        if positionMS >= durationMS { positionMS = 0 }
        do {
            try startMedia(at: positionMS)
        } catch {
            cancelSleepTimerForUnplayableTarget()
            errorMessage = error.localizedDescription
            return
        }
        isPlaying = true
        clock.play()
        startTicker()
        updateNowPlaying()
    }

    func next() {
        guard videoPreviewToken == nil else { return }
        let previousID = currentItem?.id
        if isInCall {
            cancelCallConnectionIfNeeded()
            if isInCall {
                var candidate = queue
                candidate.repeatMode = .off
                guard candidate.advance(auto: false), candidate.current?.workID == callWorkID,
                      candidate.current?.isSavedClip == false else { endCall(); return }
                // Preserve the user's loop setting; only the call's progression is bounded.
                candidate.repeatMode = queue.repeatMode
                persistPosition()
                queue = candidate
                reconcileSleepTimer(previousItemID: previousID, manualSelection: true,
                                    notice: InterfaceLocalization.text("已跳过所选停止音轨，定时已取消。"))
                loadAndPlayCurrent()
                return
            }
            return
        }
        persistPosition()
        if queue.advance(auto: false) {
            reconcileSleepTimer(previousItemID: previousID, manualSelection: true,
                                notice: InterfaceLocalization.text("已跳过所选停止音轨，定时已取消。"))
            loadAndPlayCurrent()
        } else {
            pause()
        }
    }

    func previous() {
        guard videoPreviewToken == nil else { return }
        if callPhase == .connecting { endCall(); return }
        persistPosition()
        let elapsed = capturePositionMS
        let previousID = currentItem?.id
        if isInCall {
            var candidate = queue
            candidate.repeatMode = .off
            guard candidate.retreat(elapsedMS: elapsed), candidate.current?.workID == callWorkID,
                  candidate.current?.isSavedClip == false else { return }
            candidate.repeatMode = queue.repeatMode
            queue = candidate
            reconcileSleepTimer(previousItemID: previousID, manualSelection: true,
                                notice: InterfaceLocalization.text("已离开所选停止音轨，定时已取消。"))
            if elapsed > 3_000 { seek(to: 0) }
            else { loadAndPlayCurrent() }
            return
        }
        if queue.retreat(elapsedMS: elapsed) {
            reconcileSleepTimer(previousItemID: previousID, manualSelection: true,
                                notice: InterfaceLocalization.text("已离开所选停止音轨，定时已取消。"))
            if elapsed > 3_000 {
                // 回到本曲开头
                seek(to: 0)
            } else {
                loadAndPlayCurrent()
            }
        }
    }

    func seek(to positionMS: Int) {
        guard videoPreviewToken == nil else { return }
        let target = min(max(0, positionMS), durationMS)
        if isVideo {
            guard !isLoadingMedia else { return }
            checkpointListening(ending: true)
            movie.seek(to: target, playing: isPlaying)
        } else if isPlaying { engine.seek(toMilliseconds: target, playing: true) }
        clock.seek(to: target)
        self.positionMS = target
        updateNowPlaying()
    }

    func seek(toProgress progress: Double) {
        guard durationMS > 0 else { return }
        seek(to: Int(Double(durationMS) * min(max(progress, 0), 1)))
    }

    /// 跳到队列里的某一项
    func jump(toItemIndex index: Int) {
        guard videoPreviewToken == nil else { return }
        guard queue.items.indices.contains(index) else { return }
        if callPhase == .connecting { endCall(); return }
        if isInCall, queue.items[index].workID != callWorkID || queue.items[index].isSavedClip { endCall(); return }
        persistPosition()
        let previousID = currentItem?.id
        if queue.jump(toItemIndex: index) {
            reconcileSleepTimer(previousItemID: previousID, manualSelection: true,
                                notice: InterfaceLocalization.text("已跳过所选停止音轨，定时已取消。"))
            loadAndPlayCurrent()
        }
    }

    /// Reordering does not touch the decoder, clock, playback or call state.
    func moveQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard videoPreviewToken == nil, queue.move(fromOffsets: source, toOffset: destination) else { return }
        queuePositionText = queue.progressDescription
        reconcileSleepTimer(notice: InterfaceLocalization.text("停止音轨已移到当前项之前，定时已取消。"))
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    // MARK: - 睡眠定时

    func setSleepTimer(minutes: Int) {
        guard currentItem != nil,
              let value = PlaybackSleepTimer.deadline(minutes: minutes, from: .now),
              case .deadline(let deadline) = value else { return }
        cancelSleepTimer()
        sleepTimer = value
        sleepTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let self, self.sleepTimer == .deadline(deadline) else { return }
            _ = self.expireSleepTimerIfNeeded()
        }
    }

    func setSleepTimerForCurrentTrack() {
        guard let item = currentItem else { return }
        cancelSleepTimer()
        sleepTimer = .endOfTrack(item.id)
    }

    func setSleepTimer(afterQueueItemID id: UUID) {
        guard currentItem != nil,
              let position = queue.order.firstIndex(where: { queue.items[$0].id == id }),
              position >= queue.cursor else { return }
        cancelSleepTimer()
        sleepTimer = .endOfQueueItem(id)
    }

    private func reconcileSleepTimer(previousItemID: UUID? = nil, manualSelection: Bool = false, notice: String) {
        let corrected = manualSelection
            ? sleepTimer.afterManualSelection(from: previousItemID, in: queue)
            : sleepTimer.retainingValidTarget(in: queue)
        guard corrected != sleepTimer else { return }
        let hadQueueTarget = sleepTimer.queueTargetID != nil
        cancelSleepTimer()
        if hadQueueTarget { sleepTimerNotice = notice }
    }

    private func cancelSleepTimerForUnplayableTarget() {
        guard let target = sleepTimer.queueTargetID, target == currentItem?.id else { return }
        cancelSleepTimer()
        sleepTimerNotice = InterfaceLocalization.text("所选停止音轨无法播放，定时已取消。")
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        if sleepTimer != .off { sleepTimer = .off }
        sleepTimerNotice = nil
    }

    private func expireSleepTimerIfNeeded() -> Bool {
        guard sleepTimer.shouldStop(at: .now) else { return false }
        cancelSleepTimer()
        pause(immediately: true)
        return true
    }

    private var mediaIsActuallyPlaying: Bool {
        isVideo ? movie.isActuallyPlaying : (engine.isEngineRunning && engine.isPlaying)
    }

    private func loadVideo(_ original: PlaybackQueueItem, autoplay: Bool) throws {
        needsMediaReload = false
        var item = original
        if let attachmentID = item.attachmentID, let store = libraryStore {
            guard let work = try store.work(id: item.workID),
                  let record = store.attachmentRecords(for: work).first(where: { $0.id == attachmentID }) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let opened = try store.openAttachment(record, in: work)
            videoLease = opened.lease
            item.filePath = opened.url.path
        }
        item.subtitle = libraryStore?.displayWorkSubtitle(for: item) ?? item.subtitle
        currentItem = item
        currentWorkTitle = libraryStore?.displayWorkTitle(for: item) ?? item.workTitle
        errorMessage = nil
        clearClipStart()
        waveformTask?.cancel(); waveform = .empty
        durationMS = 0; positionMS = 0
        queuePositionText = queue.progressDescription
        pendingVideoAutoplay = autoplay
        isLoadingMedia = true
        reconcileSleepTimer(notice: InterfaceLocalization.text("停止音轨已不在剩余队列中，定时已取消。"))
        movie.load(URL(fileURLWithPath: item.filePath))
        updateNowPlaying()
    }

    private func videoBecameReady(durationMS: Int) {
        guard isVideo, let item = currentItem else { return }
        self.durationMS = durationMS
        positionMS = resumePosition(for: item)
        clock.reset(positionMS: positionMS, durationMS: durationMS)
        isLoadingMedia = false
        let autoplay = pendingVideoAutoplay
        pendingVideoAutoplay = false
        if autoplay { resume() }
        else { movie.seek(to: positionMS, playing: false); updateNowPlaying() }
    }

    private func startMedia(at position: Int) throws {
        OpeningVoicePlayer.shared.stop()
        if !isVideo { try startAudio(at: position); return }
        audioSessionGeneration &+= 1
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            ownsAudioSession = true
            movie.rate = Float(AudioMath.clampRate(rate))
            movie.seek(to: position, playing: true)
        } catch { releaseAudioSession(); throw error }
    }

    private func videoPlaybackChanged() {
        guard isVideo else { return }
        if isPlaying && movie.isActuallyPlaying {
            lastAudibleUptime = ProcessInfo.processInfo.systemUptime
            if !listening.isRunning { beginListening() }
        } else if listening.isRunning { checkpointListening(ending: true) }
    }

    // MARK: - 加载与播放

    /// 切换曲目时重新读波形（后台进行，不阻塞播放）
    private func reloadWaveform(path: String) {
        waveformTask?.cancel()
        waveform = .empty
        waveformTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> WaveformData in
                (try? WaveformLoader.load(url: URL(fileURLWithPath: path), buckets: 700)) ?? .empty
            }.value
            guard !Task.isCancelled else { return }
            self?.waveform = data
        }
    }

    private func loadAndPlayCurrent(autoplay: Bool = true, advanceOnFailure: Bool = true) {
        guard !autoplay || videoPreviewToken == nil else { return }
        if autoplay { OpeningVoicePlayer.shared.stop() }
        checkpointListening(ending: true)
        interruptedItemID = nil
        persistPosition()
        stopTicker()
        isPlaying = false
        pendingVideoAutoplay = false
        isLoadingMedia = false
        engine.stop(); movie.stop(); videoLease = nil
        releaseAudioSession()
        videoScale = 1
        needsMediaReload = false
        // 删除或离线的文件可能仍在已打开的队列里；循环模式下也只尝试一轮。
        for _ in queue.items.indices {
            guard let item = queue.current else { break }
            reconcileSleepTimer(notice: InterfaceLocalization.text("停止音轨已不在剩余队列中，定时已取消。"))
            if let callWorkID, item.workID != callWorkID || item.isSavedClip {
                stopCallAfterFailedLoad()
                return
            }
            do {
                if item.isVideo {
                    try loadVideo(item, autoplay: autoplay)
                    return
                }
                try engine.load(url: URL(fileURLWithPath: item.filePath))
                playLoaded(item, autoplay: autoplay)
                return
            } catch {
                needsMediaReload = true
                errorMessage = error.localizedDescription
                DebugLog.write("无法打开 \(item.trackTitle)：\(error.localizedDescription)")
                if sleepTimer.queueTargetID == item.id {
                    cancelSleepTimer()
                    sleepTimerNotice = InterfaceLocalization.text("所选停止音轨无法播放，定时已取消。")
                }
                if !advanceOnFailure {
                    // A confirmed source replacement must not select another
                    // recording if reopening this one fails. Keep the repaired
                    // queue item available for an explicit later retry.
                    waveformTask?.cancel()
                    waveform = .empty
                    clearClipStart()
                    currentItem = item
                    currentWorkTitle = libraryStore?.displayWorkTitle(for: item) ?? item.workTitle
                    durationMS = max(0, item.durationMS ?? 0)
                    positionMS = min(max(0, positionMS), durationMS)
                    clock.reset(positionMS: positionMS, durationMS: durationMS)
                    hasQueue = !queue.isEmpty
                    queuePositionText = queue.progressDescription
                    updateNowPlaying()
                    return
                }
                if let callWorkID {
                    var candidate = queue
                    candidate.repeatMode = .off
                    guard candidate.advance(auto: false), candidate.current?.workID == callWorkID,
                          candidate.current?.isSavedClip == false else {
                        stopCallAfterFailedLoad()
                        return
                    }
                    candidate.repeatMode = queue.repeatMode
                    queue = candidate
                    continue
                }
                if !queue.advance(auto: false) { break }
            }
        }
        engine.stop()
        releaseAudioSession()
        cancelSleepTimer()
        currentItem = nil
        currentWorkTitle = ""
        clearClipStart()
        hasQueue = false
        positionMS = 0
        durationMS = 0
        updateNowPlaying()
    }

    private func stopCallAfterFailedLoad() {
        // Retain queue order/identity and the failed selection for an explicit retry.
        needsMediaReload = true
        currentItem = queue.current
        positionMS = queue.current.map(resumePosition) ?? 0
        durationMS = queue.current?.durationMS ?? 0
        currentWorkTitle = queue.current.map { libraryStore?.displayWorkTitle(for: $0) ?? $0.workTitle } ?? ""
        currentCoverPath = queue.current.flatMap { libraryStore?.coverPath(forWorkID: $0.workID) }
        hasQueue = !queue.isEmpty
        queuePositionText = queue.progressDescription
        endCall()
        updateNowPlaying()
    }

    private func playLoaded(_ item: PlaybackQueueItem, autoplay: Bool) {
        needsMediaReload = false
        var item = item
        if let libraryStore { item.subtitle = libraryStore.displayWorkSubtitle(for: item) }
        reconcileSleepTimer(notice: InterfaceLocalization.text("停止音轨已不在剩余队列中，定时已取消。"))
        reloadWaveform(path: item.filePath)
        clearClipStart()
        currentItem = item
        currentWorkTitle = libraryStore?.displayWorkTitle(for: item) ?? item.workTitle
        durationMS = engine.durationMS > 0 ? engine.durationMS : (item.durationMS ?? 0)
        errorMessage = nil

        // 从库里取续播位置
        let resumeMS = resumePosition(for: item)
        engine.rate = Float(AudioMath.clampRate(rate))
        positionMS = resumeMS
        clock.reset(positionMS: resumeMS, durationMS: durationMS)
        queuePositionText = queue.progressDescription

        do {
            if autoplay { try startAudio(at: resumeMS) }
            else { releaseAudioSession() }
            DebugLog.write("engine.play 成功，isPlaying=\(engine.isPlaying)")
        } catch {
            DebugLog.write("engine.play 失败: \(error.localizedDescription)")
            cancelSleepTimerForUnplayableTarget()
            errorMessage = error.localizedDescription
            updateNowPlaying()
            return
        }

        if autoplay { clock.play(); startTicker() }
        isPlaying = autoplay
        updateNowPlaying()
    }

    private func handleTrackFinished() {
        guard videoPreviewToken == nil, isPlaying, isVideo || engine.isEngineRunning else { return }
        persistPosition(finalPositionReached: true)
        // 拦在推进队列之前，单曲循环也应在此处停住。
        if sleepTimer.shouldStop(at: .now, finishedItemID: currentItem?.id) {
            cancelSleepTimer()
            positionMS = durationMS
            pause(immediately: true)
            return
        }
        if isInCall {
            var candidate = queue
            candidate.repeatMode = .off
            guard candidate.advance(auto: true), candidate.current?.workID == callWorkID,
                  candidate.current?.isSavedClip == false else {
                positionMS = durationMS
                endCall()
                return
            }
            candidate.repeatMode = queue.repeatMode
            queue = candidate
            loadAndPlayCurrent()
            return
        }
        // A selected later endpoint temporarily advances past single-track
        // repeat. The user's repeat preference itself stays unchanged.
        if queue.advance(auto: sleepTimer.queueTargetID == nil) {
            loadAndPlayCurrent()
        } else {
            if sleepTimer.queueTargetID != nil { cancelSleepTimer() }
            positionMS = durationMS
            pause(immediately: true)
        }
    }

    // MARK: - 进度刷新

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard isPlaying else { return }
        if expireSleepTimerIfNeeded() { return }
        positionMS = capturePositionMS
        clock.reconcile(enginePositionMS: positionMS)

        let uptime = ProcessInfo.processInfo.systemUptime
        if mediaIsActuallyPlaying {
            lastAudibleUptime = uptime
            if !listening.isRunning { beginListening() }
        } else if listening.isRunning {
            checkpointListening(ending: true)
        }
        if uptime >= nextListeningSave { flushListeningStatistics() }

        // 每 5 秒记一次续播，掉电也不丢太多
        if Date().timeIntervalSince(lastSavedAt) > 5 {
            persistPosition()
        }
    }

    // MARK: - 实际收听时长

    private func beginListening() {
        guard let store = libraryStore, let item = currentItem else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        lastAudibleUptime = uptime
        nextListeningSave = uptime + 5
        let date = Date()
        let work = store.listeningAttribution(for: item)
        let detail = ListeningSessionDelta(startedAt: date, workID: work.workID, trackID: item.trackID,
                                           workTitle: work.title ?? item.workTitle, trackTitle: item.trackTitle,
                                           isSavedClip: item.isSavedClip, libraryKind: work.libraryKind,
                                           creatorID: work.creatorID, creatorName: work.creatorName)
        listening.start(work: work, detail: detail, uptime: uptime)
    }

    /// 统计页打开或 App 退到后台时立即结算，正在响的音频仍会继续计时。
    func flushListeningStatistics() {
        checkpointListening(ending: false)
    }

    private func checkpointListening(ending: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        nextListeningSave = now + 5
        let audible = mediaIsActuallyPlaying
        // 外部打断可能在 App 恢复执行前已停掉引擎，不能把这段静音时间记进去。
        listening.checkpoint(date: Date(), uptime: audible ? now : lastAudibleUptime,
                             continuing: audible && !ending, calendar: PlaybackStatSplitter.listeningCalendar)
        guard let store = libraryStore else { return }
        do { try listening.save(using: store.recordListening(_:sessions:)) }
        catch { DebugLog.write("收听统计暂未保存，将在下次重试：\(error.localizedDescription)") }
    }

    // MARK: - 续播持久化

    private func resumePosition(for item: PlaybackQueueItem) -> Int {
        if let attachmentID = item.attachmentID, let store = libraryStore {
            return ResumePolicy.resumePosition(savedMS: (try? store.repository?.videoPlaybackPosition(attachmentID: attachmentID)) ?? 0,
                                               durationMS: durationMS)
        }
        guard !item.isSavedClip, let store = libraryStore,
              let work = try? store.work(id: item.workID),
              work.lastPlayedTrackID == item.trackID
        else { return 0 }
        return ResumePolicy.resumePosition(savedMS: work.lastPlayedPositionMS, durationMS: durationMS)
    }

    private func persistPosition(finalPositionReached: Bool = false) {
        guard let store = libraryStore, let item = currentItem, !item.isSavedClip else { return }
        let position = finalPositionReached ? durationMS : capturePositionMS
        if let attachmentID = item.attachmentID {
            guard !isLoadingMedia else { return }
            do { try store.repository?.saveVideoPlaybackPosition(attachmentID: attachmentID, workID: item.workID, positionMS: position) }
            catch { DebugLog.write("视频位置保存失败：\(error.localizedDescription)") }
            lastSavedAt = Date()
            return
        }
        guard position > 0 else { return }

        if finalPositionReached || ResumePolicy.shouldSavePosition(positionMS: position, durationMS: durationMS) {
            store.savePlaybackPosition(
                workID: item.workID,
                trackID: item.trackID,
                positionMS: position,
                durationMS: durationMS
            )
        }
        lastSavedAt = Date()
    }

    // MARK: - 音频会话

    private func startAudio(at position: Int) throws {
        guard videoPreviewToken == nil else { throw CancellationError() }
        OpeningVoicePlayer.shared.stop()
        audioSessionGeneration &+= 1
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            ownsAudioSession = true
            try engine.play(fromMilliseconds: position, fadeIn: fadeDuration)
            beginListening()
        } catch {
            engine.pause()
            releaseAudioSession()
            throw error
        }
    }

    /// PiP shares the player's playback session; it never starts another audio source.
    func setPictureInPictureAudioSessionActive(_ active: Bool) throws {
        guard pictureInPictureAudioSessionActive != active else { return }
        if active {
            guard videoPreviewToken == nil else { throw CancellationError() }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            ownsAudioSession = true
            pictureInPictureAudioSessionActive = true
        } else {
            pictureInPictureAudioSessionActive = false
            if !isPlaying { releaseAudioSession() }
        }
    }

    private func releaseAudioSession() {
        guard videoPreviewToken == nil, ownsAudioSession, !pictureInPictureAudioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        } catch {
            DebugLog.write("交还音频会话失败：\(error.localizedDescription)")
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // spokenAudio 模式针对人声优化（音声作品正合适）
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
            errorMessage = InterfaceLocalization.text("音频会话配置失败：\(error.localizedDescription)")
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        }
        refreshAudioOutputRoute()
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if videoPreviewToken != nil {
            interruptedItemID = nil
            ownsAudioSession = false
            if type == .began { ownsVideoAudioSession = false }
            return
        }

        switch type {
        case .began:
            cancelCallConnectionIfNeeded()
            // 系统已停用本应用会话。保留重复 began 之前记录的那一次播放。
            ownsAudioSession = false
            if isPlaying { interruptedItemID = currentItem?.id }
            pausePlayback(fadeOut: 0)
        case .ended:
            // 中断期间进程可能被系统挂起；先检查期限，再决定是否自动续播。
            if expireSleepTimerIfNeeded() { return }
            let interrupted = interruptedItemID
            interruptedItemID = nil
            guard let interrupted, interrupted == currentItem?.id,
                  let options = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            else { return }
            resume()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        refreshAudioOutputRoute()
        guard videoPreviewToken == nil else { return }
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        if reason == .oldDeviceUnavailable {
            // 断连前已经排队的锁屏/耳机播放指令不能在暂停后重新启动。
            remoteCommandGate.transition(allowsAudio: true)
            // 立即停止，也取消连接等待、视频待播和中断结束后的自动恢复。
            pause(immediately: true)
        }
    }

    private func refreshAudioOutputRoute() {
        var names: [String] = []
        for output in AVAudioSession.sharedInstance().currentRoute.outputs {
            let name: String
            switch output.portType {
            case .builtInSpeaker: name = InterfaceLocalization.text("扬声器")
            case .builtInReceiver: name = InterfaceLocalization.text("听筒")
            default: name = output.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        let name = names.isEmpty ? InterfaceLocalization.text("音频输出") : names.joined(separator: "、")
        if audioOutputName != name { audioOutputName = name }
    }

    // MARK: - 锁屏 / 控制中心

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.play) ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.pause) ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.toggle) ?? .commandFailed
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.next) ?? .commandFailed
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.enqueueRemoteCommand(.previous) ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.enqueueRemoteCommand(.seek(Int(event.positionTime * 1000))) ?? .commandFailed
        }
    }

    nonisolated func captureRemoteCommandTicket() -> AudioRemoteCommandGate.Ticket {
        remoteCommandGate.capture()
    }

    private nonisolated func enqueueRemoteCommand(_ command: AudioRemoteCommand) -> MPRemoteCommandHandlerStatus {
        let ticket = captureRemoteCommandTicket()
        guard ticket.allowsAudio else { return .commandFailed }
        Task { @MainActor [weak self] in _ = self?.executeRemoteCommand(command, ticket: ticket) }
        return .success
    }

    @discardableResult
    func executeRemoteCommand(_ command: AudioRemoteCommand, ticket: AudioRemoteCommandGate.Ticket) -> Bool {
        guard remoteCommandGate.accepts(ticket), videoPreviewToken == nil else { return false }
        switch command {
        case .play: resume()
        case .pause: pause()
        case .toggle: togglePlayPause()
        case .next: next()
        case .previous: previous()
        case .seek(let position): seek(to: position)
        }
        return true
    }

    func refreshLockScreenPrivacy() {
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        let remoteEnabled = videoPreviewToken == nil && currentItem != nil
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = remoteEnabled
        commands.pauseCommand.isEnabled = remoteEnabled
        commands.togglePlayPauseCommand.isEnabled = remoteEnabled
        commands.nextTrackCommand.isEnabled = remoteEnabled
        commands.previousTrackCommand.isEnabled = remoteEnabled
        commands.changePlaybackPositionCommand.isEnabled = remoteEnabled
        guard videoPreviewToken == nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        guard let item = currentItem else {
            lockScreenCover.clear()
            coverWorkID = nil
            currentCoverPath = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        if coverWorkID != item.workID {
            coverWorkID = item.workID
            currentCoverPath = libraryStore?.coverPath(forWorkID: item.workID)
        }
        let obscured = UserDefaults.standard.bool(forKey: CoverPrivacy.settingKey)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: obscured ? CoverPrivacy.publicTitle : item.trackTitle,
            MPMediaItemPropertyPlaybackDuration: Double(durationMS) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(capturePositionMS) / 1000.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyMediaType: (isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue
        ]
        if !obscured {
            info[MPMediaItemPropertyAlbumTitle] = currentWorkTitle
            if let subtitle = item.subtitle, !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        }
        info[MPMediaItemPropertyArtwork] = lockScreenCover.current(path: currentCoverPath, obscured: obscured) { [weak self] in
            self?.updateNowPlaying()
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
