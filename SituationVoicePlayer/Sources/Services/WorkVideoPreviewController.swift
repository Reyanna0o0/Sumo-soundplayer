import Foundation
import AVFoundation
import UIKit
import Combine

/// One attachment presentation owns one player, preparation task and playback
/// token. Full-screen transitions never end this presentation's ownership.
@MainActor
final class WorkVideoPreviewController: ObservableObject {
    enum State: Equatable { case loading, ready, failed(String) }
    typealias Prepare = (URL) async throws -> PreparedWorkVideo

    @Published private(set) var state: State = .loading
    @Published private(set) var player: AVPlayer?
    let url: URL
    private weak var playback: PlayerController?
    private var token: UUID?
    private let prepare: Prepare
    private var preparedVideo: PreparedWorkVideo?
    private var preparationTask: Task<Void, Never>?
    private var generation = UUID()
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var protectionSubscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []
    private var isClosed = false
    private var isForeground = UIApplication.shared.applicationState != .background
    private var shouldAutoplay = true

    init(url: URL, playback: PlayerController, prepare: @escaping Prepare = PreparedWorkVideo.prepare) {
        self.url = url
        self.playback = playback
        self.prepare = prepare
        protectionSubscription = SpeakerProtection.shared.$isMuted.sink { [weak self] muted in
            self?.player?.isMuted = muted
        }
        token = playback.beginVideoPreview { [weak self] in self?.close() }
        observeExternalEvents()
        load()
    }

    func retry() {
        guard !isClosed else { return }
        shouldAutoplay = isForeground
        load()
    }

    private func load() {
        preparationTask?.cancel()
        generation = UUID()
        let expected = generation
        clearPlayer()
        state = .loading
        let source = url, prepare = prepare
        preparationTask = Task { [weak self] in
            do {
                let prepared = try await prepare(source)
                try Task.checkCancellation()
                guard let self, !self.isClosed, self.generation == expected else { return }
                self.preparedVideo = prepared
                let item = AVPlayerItem(url: prepared.url)
                let movie = AVPlayer(playerItem: item)
                movie.isMuted = SpeakerProtection.shared.isMuted
                self.player = movie
                self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak movie] item, _ in
                    Task { @MainActor in
                        guard let self, let movie, !self.isClosed, self.generation == expected,
                              self.player === movie, movie.currentItem === item else { return }
                        switch item.status {
                        case .readyToPlay:
                            self.state = .ready
                            if self.shouldAutoplay, self.isForeground {
                                self.shouldAutoplay = false
                                do {
                                    guard let token = self.token, let playback = self.playback else { throw CancellationError() }
                                    try playback.activateVideoPreview(token)
                                    movie.play()
                                } catch { self.fail(error.localizedDescription) }
                            }
                        case .failed:
                            self.fail(InterfaceLocalization.text("此视频的封装或编码不受系统支持，或文件已损坏。可重试，或通过分享按钮选择其他播放器。"))
                        default: break
                        }
                    }
                }
                self.rateObservation = movie.observe(\.rate, options: [.new]) { [weak self, weak movie] _, change in
                    let requestedRate = change.newValue ?? 0
                    Task { @MainActor in
                        guard let self, let movie, !self.isClosed, self.generation == expected,
                              self.player === movie else { return }
                        if requestedRate == 0 {
                            // Capture the event, not only the final rate: rapid
                            // pause/play must still revoke the old permission.
                            SpeakerProtection.shared.endPlayback(owner: "preview")
                            if movie.rate == 0, let token = self.token {
                                self.playback?.suspendVideoPreview(token)
                            }
                            return
                        }
                        guard movie.rate > 0 else { return }
                        guard self.isForeground else { movie.pause(); return }
                        do {
                            guard let token = self.token, let playback = self.playback else { throw CancellationError() }
                            try playback.activateVideoPreview(token)
                        } catch { self.fail(error.localizedDescription) }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isClosed, self.generation == expected else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func clearPlayer() {
        statusObservation?.invalidate(); statusObservation = nil
        rateObservation?.invalidate(); rateObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        preparedVideo = nil
    }

    private func fail(_ message: String) {
        clearPlayer()
        if let token { playback?.suspendVideoPreview(token) }
        state = .failed(message)
    }

    /// Called only when the attachment sheet actually closes, not when AVKit
    /// moves its video between inline and full-screen presentation.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        generation = UUID()
        preparationTask?.cancel(); preparationTask = nil
        clearPlayer()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let token { playback?.endVideoPreview(token) }
        token = nil
    }

    private func pauseForExternalEvent(releaseSession: Bool) {
        guard !isClosed else { return }
        shouldAutoplay = false
        player?.pause()
        if releaseSession, let token { playback?.suspendVideoPreview(token) }
    }

    private func observeExternalEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isForeground = false
                self?.pauseForExternalEvent(releaseSession: true)
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isForeground = true }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pauseForExternalEvent(releaseSession: true) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            MainActor.assumeIsolated { self?.pauseForExternalEvent(releaseSession: false) }
        })
    }

    deinit {
        preparationTask?.cancel()
        statusObservation?.invalidate()
        rateObservation?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        let playback = playback, token = token
        // The retained player is released with this object; transfer ownership
        // on the main actor afterwards. Normal sheet dismissal uses close().
        Task { @MainActor in if let token { playback?.endVideoPreview(token) } }
    }
}
