import AVFoundation
import Combine
import Foundation
import ResourceAccessCore

/// AVPlayer transport only. PlayerController remains the sole owner of the
/// audio session, remote commands, queue, sleep timer, progress and statistics.
@MainActor
final class NetworkAudioPlaybackEngine {
    static var configuredForwardBufferSeconds: Double {
        #if DEBUG && targetEnvironment(simulator)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "-networkBufferSeconds"), args.indices.contains(index + 1),
           let value = Double(args[index + 1]), value.isFinite, (0...30).contains(value) { return value }
        #endif
        return 0
    }
    struct Resource {
        let adapter: any ResourceAdapter
        let path: ResourcePath
        let expectedRevision: ResourceRevision?
        let validateBinding: @MainActor () throws -> Void
    }
    struct IdentityEvidence {
        let sourceID: UUID
        let endpoint: URL
        let path: ResourcePath
        let revision: ResourceRevision
    }

    let player = AVPlayer()
    var onReady: ((Int) -> Void)?
    var onFinished: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var identityEvidence: IdentityEvidence?
    private(set) var isReady = false
    private(set) var hasFailed = false
    private var wantsPlayback = false
    private var generation = UUID()
    private var preparation: Task<Void, Never>?
    private var preparationTimeout: Task<Void, Never>?
    private var seekTimeout: Task<Void, Never>?
    private var seekQueue = NetworkSeekQueue()
    private var bridge: NetworkResourceLoader?
    private var status: NSKeyValueObservation?
    private var playbackStatus: NSKeyValueObservation?
    private var protection: AnyCancellable?
    private var notifications: [NSObjectProtocol] = []

    var rate: Float = 1 {
        didSet { applyIntent() }
    }
    var isSeeking: Bool { seekQueue.isSeeking }
    var requestedPositionMS: Int? { seekQueue.latestTarget }
    var isActuallyPlaying: Bool {
        isReady && !hasFailed && !isSeeking && wantsPlayback && player.timeControlStatus == .playing && player.rate > 0
    }
    var isWaiting: Bool {
        isReady && !hasFailed && wantsPlayback && (isSeeking || player.timeControlStatus != .playing)
    }
    var positionMS: Int {
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds >= 0 ? Int(min(seconds * 1_000, Double(Int.max - 1))) : 0
    }
    var durationMS: Int {
        let seconds = player.currentItem?.duration.seconds ?? .nan
        return seconds.isFinite && seconds > 0 && seconds < Double(Int.max) / 1_000 ? Int(seconds * 1_000) : 0
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        protection = SpeakerProtection.shared.$isMuted.sink { [weak self] value in self?.player.isMuted = value }
        playbackStatus = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onStateChanged?() }
        }
    }

    /// Always prepares paused. Resolution is repeated for a reconnect, so changed
    /// credentials/source bindings are not hidden in a retained network session.
    func load(previous: IdentityEvidence? = nil,
              resolve: @escaping @MainActor () async throws -> Resource) {
        stop()
        let token = generation
        preparationTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token, !self.isReady else { return }
            self.fail(ResourceAccessError.timedOut)
        }
        preparation = Task { [weak self] in
            do {
                let resource = try await resolve()
                try Task.checkCancellation()
                let metadata = try await resource.adapter.metadata(at: resource.path)
                try Task.checkCancellation()
                try resource.validateBinding()
                if let expected = resource.expectedRevision, expected.match(metadata.revision) == .different {
                    throw ResourceAccessError.resourceChanged
                }
                if let previous {
                    let sameLocation = previous.sourceID == resource.adapter.connection.id
                        && previous.endpoint == resource.adapter.connection.endpoint && previous.path == resource.path
                    let match = sameLocation ? previous.revision.match(metadata.revision)
                        : previous.revision.contentMatchAcrossLocations(metadata.revision)
                    guard sameLocation ? match != .different : match == .same else {
                        throw ResourceAccessError.resourceChanged
                    }
                }
                guard let self, self.generation == token, !self.hasFailed else { return }
                self.identityEvidence = IdentityEvidence(sourceID: resource.adapter.connection.id,
                    endpoint: resource.adapter.connection.endpoint, path: resource.path, revision: metadata.revision)
                let bridge = try NetworkResourceLoader(adapter: resource.adapter, path: resource.path, metadata: metadata,
                    onBytes: { _ in }, onFailure: { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            // An invalidated or canceled individual loader request is
                            // not a transport failure for the replacement item.
                            if !(error is CancellationError) { self.fail(error) }
                        }
                    })
                self.bridge = bridge
                let asset = AVURLAsset(url: bridge.url)
                asset.resourceLoader.setDelegate(bridge, queue: bridge.queue)
                let item = AVPlayerItem(asset: asset)
                item.preferredForwardBufferDuration = Self.configuredForwardBufferSeconds
                self.status = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor in self?.itemStatusChanged(item, token: token) }
                }
                self.notifications.append(NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.wantsPlayback, !self.hasFailed else { return }
                        self.onFinished?()
                    }
                })
                self.notifications.append(NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.fail(ResourceAccessError.temporarilyUnavailable)
                    }
                })
                self.player.replaceCurrentItem(with: item)
            } catch is CancellationError {} catch {
                guard let self, self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    private func itemStatusChanged(_ item: AVPlayerItem, token: UUID) {
        guard generation == token, player.currentItem === item, !hasFailed else { return }
        if item.status == .failed { fail(item.error ?? ResourceAccessError.temporarilyUnavailable) }
        else if item.status == .readyToPlay, !isReady {
            isReady = true
            preparationTimeout?.cancel(); preparationTimeout = nil
            onReady?(durationMS)
            onStateChanged?()
        }
    }

    func seek(to milliseconds: Int, playing: Bool) {
        guard isReady, !hasFailed else { return }
        wantsPlayback = playing
        seekQueue.enqueue(milliseconds)
        player.pause()
        onStateChanged?()
        drainSeek()
    }

    private func drainSeek() {
        guard isReady, !hasFailed, let request = seekQueue.beginNext() else { return }
        let token = generation
        player.seek(to: CMTime(value: Int64(request.milliseconds), timescale: 1_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor in
                guard let self, self.generation == token, self.seekQueue.finish(request.id) else { return }
                self.seekTimeout?.cancel(); self.seekTimeout = nil
                if self.seekQueue.pending != nil { self.drainSeek(); return }
                guard completed else { self.fail(ResourceAccessError.temporarilyUnavailable); return }
                self.applyIntent()
                self.onStateChanged?()
            }
        }
        seekTimeout?.cancel()
        seekTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token,
                  self.seekQueue.active?.id == request.id else { return }
            self.fail(ResourceAccessError.timedOut)
        }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        onStateChanged?()
    }

    private func applyIntent() {
        guard isReady, !hasFailed, !isSeeking else { return }
        if wantsPlayback { player.rate = rate }
        else { player.pause() }
    }

    func stop() {
        generation = UUID()
        preparation?.cancel(); preparation = nil
        preparationTimeout?.cancel(); preparationTimeout = nil
        seekTimeout?.cancel(); seekTimeout = nil
        seekQueue.invalidate()
        wantsPlayback = false; isReady = false; hasFailed = false
        status?.invalidate(); status = nil
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        player.pause(); player.currentItem?.cancelPendingSeeks(); player.replaceCurrentItem(with: nil)
        bridge?.invalidate(); bridge = nil
        identityEvidence = nil
    }

    private func fail(_ error: Error) {
        guard !hasFailed else { return }
        hasFailed = true; wantsPlayback = false
        preparation?.cancel(); preparationTimeout?.cancel(); seekTimeout?.cancel()
        // Retain the latest requested seek until PlayerController saves the recovery
        // target; cancel callbacks may return asynchronously after this notification.
        onFailure?(Self.failureMessage(error))
        seekQueue.invalidate()
        player.pause(); player.currentItem?.cancelPendingSeeks(); bridge?.invalidate()
        onStateChanged?()
    }

    static func failureMessage(_ error: Error) -> String {
        switch error {
        case ResourceAccessError.authorizationRequired:
            return InterfaceLocalization.text("网络来源需要重新登录，请在设置中检查账号后重新连接。")
        case ResourceAccessError.permissionDenied:
            return InterfaceLocalization.text("没有读取此文件的权限，请检查共享权限。")
        case ResourceAccessError.notFound:
            return InterfaceLocalization.text("网络文件已移动或不存在，当前音轨和位置已保留。")
        case ResourceAccessError.resourceChanged, NetworkLoaderFailure.changedResource:
            return InterfaceLocalization.text("网络文件内容或来源已变化，未自动继承原播放位置。请重新选择来源。")
        case ResourceAccessError.timedOut:
            return InterfaceLocalization.text("网络读取或定位超时，当前位置已保留，可检查网络后重新连接。")
        default:
            // SDK errors can contain URLs/paths/credentials. Do not surface their raw text.
            return InterfaceLocalization.text("网络音频暂时无法播放，当前位置已保留，可检查连接后重试。")
        }
    }

    deinit {
        preparation?.cancel(); preparationTimeout?.cancel(); seekTimeout?.cancel()
        status?.invalidate(); playbackStatus?.invalidate()
        notifications.forEach(NotificationCenter.default.removeObserver)
        bridge?.invalidate()
    }
}
