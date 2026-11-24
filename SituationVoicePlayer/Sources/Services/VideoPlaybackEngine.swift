import AVFoundation
import Foundation
import Combine

/// The formal playback session owns this engine, independently of any visible view.
@MainActor
final class VideoPlaybackEngine {
    let player = AVPlayer()
    var onReady: ((Int) -> Void)?
    var onFinished: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private var protectionSubscription: AnyCancellable?
    private var prepared: PreparedWorkVideo?
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var status: NSKeyValueObservation?
    private var playbackStatus: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    private var failed: NSObjectProtocol?
    private var wantsPlayback = false
    private var seeking = false
    private var ready = false
    var rate: Float = 1 {
        didSet { if wantsPlayback && ready && !seeking { player.rate = rate } }
    }
    var isSeeking: Bool { seeking }
    var isActuallyPlaying: Bool { !seeking && player.timeControlStatus == .playing && player.rate > 0 }
    var positionMS: Int {
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds >= 0 ? Int(min(seconds * 1000, Double(Int.max - 1))) : 0
    }

    init() {
        protectionSubscription = SpeakerProtection.shared.$isMuted.sink { [weak self] muted in
            self?.player.isMuted = muted
        }
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        playbackStatus = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onStateChanged?() }
        }
    }

    func load(_ url: URL) {
        stop()
        let expected = generation
        preparation = Task { [weak self] in
            do {
                let prepared = try await PreparedWorkVideo.prepare(url)
                try Task.checkCancellation()
                let asset = AVURLAsset(url: prepared.url)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0, duration * 1000 < Double(Int.max) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                guard let self, self.generation == expected else { return }
                self.prepared = prepared
                let item = AVPlayerItem(asset: asset)
                self.player.replaceCurrentItem(with: item)
                self.status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.generation == expected, self.player.currentItem === item else { return }
                        if item.status == .readyToPlay, !self.ready {
                            self.ready = true
                            self.onReady?(Int(duration * 1000))
                        } else if item.status == .failed {
                            self.onFailure?(item.error?.localizedDescription ?? InterfaceLocalization.text("无法读取此视频。"))
                        }
                    }
                }
                self.ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == expected, self.wantsPlayback else { return }
                        self.onFinished?()
                    }
                }
                self.failed = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == expected else { return }
                        self.onFailure?(InterfaceLocalization.text("视频播放中断，请确认文件仍可读取。"))
                    }
                }
            } catch is CancellationError {} catch {
                guard let self, self.generation == expected else { return }
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    func seek(to milliseconds: Int, playing: Bool) {
        wantsPlayback = playing
        seeking = true
        player.pause()
        onStateChanged?()
        seekGeneration = UUID()
        let expected = generation, seek = seekGeneration
        player.seek(to: CMTime(value: Int64(max(0, milliseconds)), timescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == expected, self.seekGeneration == seek else { return }
                self.seeking = false
                if finished, self.wantsPlayback, self.ready { self.player.playImmediately(atRate: self.rate) }
                self.onStateChanged?()
            }
        }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        onStateChanged?()
    }

    func stop() {
        generation = UUID(); seekGeneration = UUID()
        preparation?.cancel(); preparation = nil
        status?.invalidate(); status = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }
        if let failed { NotificationCenter.default.removeObserver(failed) }
        ended = nil; failed = nil
        wantsPlayback = false; ready = false; seeking = false
        player.pause(); player.replaceCurrentItem(with: nil)
        prepared = nil
    }

    deinit {
        preparation?.cancel()
        status?.invalidate(); playbackStatus?.invalidate()
        if let ended { NotificationCenter.default.removeObserver(ended) }
        if let failed { NotificationCenter.default.removeObserver(failed) }
    }
}
